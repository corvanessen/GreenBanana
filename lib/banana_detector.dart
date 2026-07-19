import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;

import 'feedback_store.dart';

const _bananaLabels = {
  'banana', 'fruit', 'yellow', 'food', 'produce',
  'plantain', 'natural foods', 'whole food',
  'plant', 'ingredient', 'vegetable', 'cuisine',
};

/// Coarse ML-Kit "classifyObjects" categories die een gedetecteerde box als
/// vermoedelijk-geen-banaan markeren (kleding/meubels/plaatsen i.p.v. eten/plant).
const _rejectedObjectCategories = {'fashion good', 'home good', 'place'};

/// Rechthoek in pixel-coördinaten van de gedecodeerde foto (niet te verwarren
/// met dart:ui's Rect, dat in logische schermpixels werkt).
class PixelBox {
  final int left;
  final int top;
  final int right;
  final int bottom;

  const PixelBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  int get width => right - left;
  int get height => bottom - top;

  bool contains(int x, int y) => x >= left && x < right && y >= top && y < bottom;

  bool isValid(int imageWidth, int imageHeight) =>
      width > 0 && height > 0 && left >= 0 && top >= 0 && right <= imageWidth && bottom <= imageHeight;

  /// Krimpt de box aan alle kanten met [fraction] (bijv. 0.08 = 8%) — gedetecteerde
  /// bounding boxes lopen vaak wat los, vooral aan de uiteinden van een langwerpig object.
  PixelBox inset(double fraction) {
    final dx = (width * fraction).round();
    final dy = (height * fraction).round();
    return PixelBox(
      left: left + dx,
      top: top + dy,
      right: right - dx,
      bottom: bottom - dy,
    );
  }

  PixelBox clampTo(int imageWidth, int imageHeight) => PixelBox(
        left: left.clamp(0, imageWidth),
        top: top.clamp(0, imageHeight),
        right: right.clamp(0, imageWidth),
        bottom: bottom.clamp(0, imageHeight),
      );
}

/// Lokale, per-toestel kalibratie van de hue→rijpheid-mapping. Wordt geladen uit
/// en weggeschreven naar een klein JSON-bestand in app-documents, zodat
/// herkalibratie geen app-rebuild nodig heeft. Blijft standaard neutraal
/// (bias 0.0) totdat er genoeg gebruikerscorrecties zijn verzameld.
class RipenessCalibration {
  final double hueBias;
  final int sampleCount;

  const RipenessCalibration({required this.hueBias, required this.sampleCount});

  factory RipenessCalibration.defaults() => const RipenessCalibration(hueBias: 0.0, sampleCount: 0);

  factory RipenessCalibration.fromJson(Map<String, dynamic> json) => RipenessCalibration(
        hueBias: (json['hueBias'] as num?)?.toDouble() ?? 0.0,
        sampleCount: (json['sampleCount'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'hueBias': hueBias, 'sampleCount': sampleCount};
}

class BananaDetector {
  ImageLabeler? _labeler;
  ObjectDetector? _objectDetector;
  List<String> _labels = [];
  bool _isProcessing = false;
  DateTime _lastProcessed = DateTime(0);

  RipenessCalibration _calibration = RipenessCalibration.defaults();
  final FeedbackStore feedbackStore = FeedbackStore();

  static const _minCalibrationSamples = 20;
  static const _maxHueBias = 20.0;

  Future<void> init() async {
    final labelData = await rootBundle.loadString('assets/labels.txt');
    _labels = labelData.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

    final modelPath = await _copyAssetToFile('assets/mobilenet_v1_1.0_224_quant.tflite');
    final options = LocalLabelerOptions(
      confidenceThreshold: 0.2,
      modelPath: modelPath,
    );
    _labeler = ImageLabeler(options: options);

    _objectDetector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      ),
    );

    await _loadCalibration();
    // Her-kalibreren op basis van eerder verzamelde feedback gebeurt hier, één
    // keer per app-start — goedkoop genoeg (grid search over ~80 kandidaten
    // maal een paar honderd datapunten) om synchroon te doen.
    await _runLocalCalibration();
  }

  Future<String> _copyAssetToFile(String assetPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, p.basename(assetPath)));
    if (!await file.exists()) {
      final bytes = await rootBundle.load(assetPath);
      await file.writeAsBytes(bytes.buffer.asUint8List());
    }
    return file.path;
  }

  Future<File> _calibrationFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'ripeness_calibration.json'));
  }

  Future<void> _loadCalibration() async {
    try {
      final file = await _calibrationFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _calibration = RipenessCalibration.fromJson(json);
      }
    } catch (e) {
      debugPrint('⚠️ Kalibratie laden mislukt, val terug op standaard: $e');
      _calibration = RipenessCalibration.defaults();
    }
  }

  Future<void> _saveCalibration() async {
    try {
      final file = await _calibrationFile();
      await file.writeAsString(jsonEncode(_calibration.toJson()));
    } catch (e) {
      debugPrint('⚠️ Kalibratie opslaan mislukt: $e');
    }
  }

  /// Zoekt de globale hue-bias (−20° .. +20°) die de gemiddelde absolute fout
  /// tussen voorspeld en door de gebruiker gecorrigeerd stadium minimaliseert,
  /// over alle lokaal opgeslagen, door de gebruiker gecorrigeerde feedback.
  /// Doet niets zolang er te weinig data is (voorkomt overfitten op een
  /// handvol testcorrecties van de ontwikkelaar zelf).
  Future<void> _runLocalCalibration() async {
    try {
      final records = await feedbackStore.readAll();
      final labeled = records.where((r) => r.correctedStage != null).toList();

      if (labeled.length < _minCalibrationSamples) {
        if (_calibration.sampleCount != 0 && labeled.isEmpty) {
          // Log is leeggemaakt/gereset: val terug naar neutraal in plaats van
          // een stale bias uit een vorige installatie te blijven toepassen.
          _calibration = RipenessCalibration.defaults();
          await _saveCalibration();
        }
        return;
      }

      double bestBias = 0.0;
      double bestMae = double.infinity;
      for (double bias = -_maxHueBias; bias <= _maxHueBias; bias += 0.5) {
        double sumAbsError = 0.0;
        for (final r in labeled) {
          final predicted = _hueToRipeness(r.medianHueRaw + bias);
          sumAbsError += (predicted - r.correctedStage!).abs();
        }
        final mae = sumAbsError / labeled.length;
        if (mae < bestMae) {
          bestMae = mae;
          bestBias = bias;
        }
      }

      _calibration = RipenessCalibration(
        hueBias: bestBias.clamp(-_maxHueBias, _maxHueBias),
        sampleCount: labeled.length,
      );
      await _saveCalibration();
      debugPrint('ℹ️ Kalibratie bijgewerkt: bias=${_calibration.hueBias.toStringAsFixed(1)}° '
          'op basis van ${_calibration.sampleCount} correcties (MAE=${bestMae.toStringAsFixed(2)})');
    } catch (e) {
      debugPrint('⚠️ Lokale herkalibratie mislukt: $e');
    }
  }

  /// Huidige kalibratiestatus, puur voor eventuele debug-weergave — houdt de
  /// bias inspecteerbaar in plaats van een stille black box.
  RipenessCalibration get calibration => _calibration;

  Future<DetectionResult?> processImage(
    CameraImage image,
    CameraDescription camera,
  ) async {
    if (_labeler == null) return null;
    if (_isProcessing) return null;

    final now = DateTime.now();
    if (now.difference(_lastProcessed).inMilliseconds < 1500) return null;
    _lastProcessed = now;

    _isProcessing = true;

    try {
      final inputImage = _buildInputImage(image, camera);
      if (inputImage == null) return null;

      final rawLabels = await _labeler!.processImage(inputImage);
      if (rawLabels.isEmpty) return null;

      final namedLabels = rawLabels.map((l) {
        final name = (l.index >= 0 && l.index < _labels.length)
            ? _labels[l.index]
            : l.label;
        return _NamedLabel(name: name, confidence: l.confidence);
      }).toList();

      final bestLabel = namedLabels.first;
      final bananaLabel = _pickBestBananaLabel(rawLabels);

      if (bananaLabel != null) {
        return DetectionResult(
          label: bananaLabel.name,
          confidence: bananaLabel.confidence,
          isBanana: true,
          bananaColor: BananaColor.unknown,
          allLabels: namedLabels
              .map((l) => '${l.name} ${(l.confidence * 100).toStringAsFixed(0)}%')
              .toList(),
        );
      } else {
        return DetectionResult(
          label: bestLabel.name,
          confidence: bestLabel.confidence,
          isBanana: false,
          bananaColor: BananaColor.unknown,
          allLabels: namedLabels
              .map((l) => '${l.name} ${(l.confidence * 100).toStringAsFixed(0)}%')
              .toList(),
        );
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// Kiest, uit ruwe ML Kit image-labels, de label met de hoogste zekerheid
  /// die in de banaan-vocabulaire (_bananaLabels) voorkomt — of null als geen
  /// van de labels op een banaan lijkt.
  _NamedLabel? _pickBestBananaLabel(List<ImageLabel> rawLabels) {
    _NamedLabel? best;
    for (final l in rawLabels) {
      final name = (l.index >= 0 && l.index < _labels.length) ? _labels[l.index] : l.label;
      final lower = name.toLowerCase();
      if (_bananaLabels.any((b) => lower.contains(b))) {
        if (best == null || l.confidence > best.confidence) {
          best = _NamedLabel(name: name, confidence: l.confidence);
        }
      }
    }
    return best;
  }

  // Hue-ankerpunten gemeten op een echte rijpheidsschaal (stadium 1 = groen
  // ... stadium 7 = volledig geel). Hue daalt vrij lineair per segment naarmate
  // de banaan rijpt, dus we interpoleren tussen deze gemeten punten.
  static const List<List<double>> _ripenessAnchors = [
    [90.0, 1.0],
    [70.0, 2.0],
    [54.0, 3.0],
    [49.0, 4.0],
    [47.0, 5.0],
    [44.0, 6.0],
    [40.0, 7.0],
  ];

  double _hueToRipeness(double hue) {
    // Boven het hoogste ankerpunt (zeer groen) -> stadium 1
    if (hue >= _ripenessAnchors.first[0]) return 1.0;
    // Onder het laagste ankerpunt (diep geel/bruinverkleurend) -> stadium 7
    if (hue <= _ripenessAnchors.last[0]) return 7.0;

    for (int i = 0; i < _ripenessAnchors.length - 1; i++) {
      final h1 = _ripenessAnchors[i][0];
      final s1 = _ripenessAnchors[i][1];
      final h2 = _ripenessAnchors[i + 1][0];
      final s2 = _ripenessAnchors[i + 1][1];
      if (hue <= h1 && hue >= h2) {
        final t = (h1 - hue) / (h1 - h2);
        return s1 + t * (s2 - s1);
      }
    }
    return 4.0; // fallback, zou niet moeten gebeuren
  }

  /// Detecteert een echte bounding box rond de banaan.
  ///
  /// ML Kit's generieke Object Detector weet zelf niet wat een banaan is —
  /// het localiseert alleen "opvallende objecten" en geeft er hooguit een
  /// grove categorie bij (Fashion/Food/Home good/Place/Plant/Unknown). Simpelweg
  /// de grootste gedetecteerde box pakken laat dus net zo makkelijk een lepel
  /// of ander voorwerp op tafel winnen als er geen banaan-specifieke check op
  /// zit. Daarom knippen we elk gedetecteerd object uit de foto en laten we
  /// de al-bestaande, banaan-getrainde MobileNet-labeler (dezelfde die het
  /// live scannen gate't) er nogmaals naar kijken — alleen een object dat
  /// zelf ook als banaan wordt herkend, mag de scan-box worden.
  ///
  /// Eenmalig per foto, niet per live frame. Geeft null terug (val dan terug
  /// op het vaste centrale scan-vak) als geen enkel gedetecteerd object op
  /// een banaan lijkt.
  Future<PixelBox?> _detectBananaBox(
    String imagePath,
    int imageWidth,
    int imageHeight,
    img.Image decoded,
  ) async {
    if (_objectDetector == null || _labeler == null) return null;
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final objects = await _objectDetector!.processImage(inputImage);
      if (objects.isEmpty) return null;

      PixelBox? bestBox;
      double bestConfidence = 0.0;

      for (final obj in objects) {
        final r = obj.boundingBox;
        final box = PixelBox(
          left: r.left.round(),
          top: r.top.round(),
          right: r.right.round(),
          bottom: r.bottom.round(),
        ).clampTo(imageWidth, imageHeight);
        if (!box.isValid(imageWidth, imageHeight)) continue;

        // Goedkope voorfilter op ML Kit's grove categorie, vóórdat we de
        // duurdere crop+classificatie doen.
        if (obj.labels.isNotEmpty) {
          final rejected = obj.labels.any(
            (l) => _rejectedObjectCategories.contains(l.text.toLowerCase().trim()),
          );
          if (rejected) continue;
        }

        final match = await _classifyCropAsBanana(decoded, box);
        if (match != null && match.confidence > bestConfidence) {
          bestConfidence = match.confidence;
          bestBox = box;
        }
      }

      if (bestBox == null) return null; // geen van de gedetecteerde objecten was een banaan

      var box = bestBox.inset(0.09).clampTo(imageWidth, imageHeight);
      if (!box.isValid(imageWidth, imageHeight)) return null;
      // Te klein na inzoomen is vermoedelijk ruis, niet de banaan zelf.
      if (box.width * box.height < 0.01 * imageWidth * imageHeight) return null;

      return box;
    } catch (e) {
      debugPrint('⚠️ Object-detectie mislukt, val terug op vast scan-vak: $e');
      return null;
    }
  }

  /// Knipt [box] uit de foto en laat de banaan-labeler alleen naar dát
  /// stukje kijken. Retourneert de best passende banaan-label (of null) voor
  /// deze specifieke crop.
  Future<_NamedLabel?> _classifyCropAsBanana(img.Image decoded, PixelBox box) async {
    try {
      final cropped = img.copyCrop(
        decoded,
        x: box.left,
        y: box.top,
        width: box.width,
        height: box.height,
      );
      final jpegBytes = img.encodeJpg(cropped, quality: 85);

      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, 'gb_object_crop_check.jpg'));
      await tempFile.writeAsBytes(jpegBytes, flush: true);

      final inputImage = InputImage.fromFilePath(tempFile.path);
      final rawLabels = await _labeler!.processImage(inputImage);
      return _pickBestBananaLabel(rawLabels);
    } catch (e) {
      debugPrint('⚠️ Crop-classificatie mislukt: $e');
      return null;
    }
  }

  static PixelBox _fixedFallbackBox(int imageWidth, int imageHeight) => PixelBox(
        left: (imageWidth * 0.30).toInt(),
        top: (imageHeight * 0.30).toInt(),
        right: (imageWidth * 0.70).toInt(),
        bottom: (imageHeight * 0.70).toInt(),
      );

  /// Schat de belichtingskleur door een grove steekproef van pixels BUITEN de
  /// crop-box te nemen (dat is nu vrijwel zeker echte achtergrond, niet
  /// banaanschil) en berekent per-kanaal correctiefactoren t.o.v. een neutraal
  /// grijs — corrigeert voor kleurtemperatuur-verschuiving, waar groene tinten
  /// gevoeliger voor zijn dan gele.
  List<double> _estimateIlluminantGain(img.Image image, PixelBox box) {
    final w = image.width, h = image.height;
    final stride = math.max(1, (math.max(w, h) / 60).round());

    double sumR = 0, sumG = 0, sumB = 0;
    int count = 0;
    for (int y = 0; y < h; y += stride) {
      for (int x = 0; x < w; x += stride) {
        if (box.contains(x, y)) continue;
        final px = image.getPixel(x, y);
        sumR += px.r / 255.0;
        sumG += px.g / 255.0;
        sumB += px.b / 255.0;
        count++;
      }
    }

    if (count < 20) return const [1.0, 1.0, 1.0];

    final meanR = sumR / count, meanG = sumG / count, meanB = sumB / count;
    final gray = (meanR + meanG + meanB) / 3.0;
    if (gray < 0.02) return const [1.0, 1.0, 1.0]; // (bijna) zwarte achtergrond: onbetrouwbaar

    double gain(double mean) => (mean < 0.02) ? 1.0 : (gray / mean).clamp(0.7, 1.4);
    return [gain(meanR), gain(meanG), gain(meanB)];
  }

  Future<ColorAnalysisResult> analyzePhotoColor(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return ColorAnalysisResult.unknown();

      final detectedBox = await _detectBananaBox(imagePath, decoded.width, decoded.height, decoded);
      final box = detectedBox ?? _fixedFallbackBox(decoded.width, decoded.height);
      final boxSource = detectedBox != null ? 'mlkit_object_detector' : 'fixed_rect_fallback';

      final result = analyzeImageColor(decoded, box: box, boxSource: boxSource);
      return result;
    } catch (e) {
      debugPrint('⚠️ Kleuranalyse mislukt: $e');
      return ColorAnalysisResult.unknown();
    }
  }

  /// Kernanalyse los van bestands-I/O en ML Kit, zodat dit ook met synthetische
  /// in-memory afbeeldingen getest kan worden (unit tests kunnen ML Kit niet
  /// aanroepen — dat vereist een echt platform).
  ColorAnalysisResult analyzeImageColor(
    img.Image decoded, {
    required PixelBox box,
    required String boxSource,
  }) {
    final illuminantGain = _estimateIlluminantGain(decoded, box);
    final analysis = _sampleRegion(decoded, box, illuminantGain);

    final boxLeftFrac = box.left / decoded.width;
    final boxTopFrac = box.top / decoded.height;
    final boxRightFrac = box.right / decoded.width;
    final boxBottomFrac = box.bottom / decoded.height;
    final aspectRatio = decoded.width / decoded.height;

    if (analysis == null) {
      return ColorAnalysisResult.unknown(
        boxSource: boxSource,
        boxLeftFrac: boxLeftFrac,
        boxTopFrac: boxTopFrac,
        boxRightFrac: boxRightFrac,
        boxBottomFrac: boxBottomFrac,
        imageAspectRatio: aspectRatio,
      );
    }

    final medianHueRaw = analysis.medianHue;
    final calibratedHue = medianHueRaw + _calibration.hueBias;
    double stage = _hueToRipeness(calibratedHue);

    // Veel bruine vlekken duwt het stadium richting overrijp (8),
    // ook als de onderliggende schil-hue nog geel is.
    if (analysis.darkFraction > 0.15) {
      final pushedStage = 7.0 + (analysis.darkFraction.clamp(0.0, 0.6) / 0.6);
      stage = stage < pushedStage ? pushedStage : stage;
    }

    BananaColor primary;
    if (stage <= 2.5) {
      primary = BananaColor.green;
    } else if (stage <= 7.0) {
      primary = BananaColor.yellow;
    } else {
      primary = BananaColor.black;
    }

    return ColorAnalysisResult(
      primary: primary,
      ripenessStage: stage,
      darkSpotFraction: analysis.darkFraction,
      medianHueRaw: medianHueRaw,
      satMedian: analysis.satMedian,
      valMedian: analysis.valMedian,
      validPixelCount: analysis.validPixels,
      hueHistogram: analysis.histogram,
      boxSource: boxSource,
      boxLeftFrac: boxLeftFrac,
      boxTopFrac: boxTopFrac,
      boxRightFrac: boxRightFrac,
      boxBottomFrac: boxBottomFrac,
      imageAspectRatio: aspectRatio,
    );
  }

  _RegionAnalysis? _sampleRegion(img.Image decoded, PixelBox box, List<double> illuminantGain) {
    // Eerste poging met stride 6 (zoals voorheen); bij te weinig bruikbare
    // pixels (typisch: groene bananen verliezen meer pixels aan de filters)
    // opnieuw met een fijnere stride, in plaats van dit altijd te doen.
    for (final stride in [6, 3]) {
      final result = _sampleRegionAtStride(decoded, box, illuminantGain, stride);
      if (result != null && result.hues.length >= 300) return _finish(result);
      if (stride == 3 && result != null) return _finish(result);
      if (stride == 3 && result == null) return null;
    }
    return null;
  }

  _RawSample? _sampleRegionAtStride(
    img.Image decoded,
    PixelBox box,
    List<double> illuminantGain,
    int stride,
  ) {
    final hues = <double>[];
    final sats = <double>[];
    final vals = <double>[];
    final histogram = List<int>.filled(12, 0); // 30°-150° in 12 bins van 10°
    int darkSpotPixels = 0;
    int validPixels = 0;

    for (int y = box.top; y < box.bottom; y += stride) {
      for (int x = box.left; x < box.right; x += stride) {
        final pixel = decoded.getPixel(x, y);
        final r = ((pixel.r / 255.0) * illuminantGain[0]).clamp(0.0, 1.0);
        final g = ((pixel.g / 255.0) * illuminantGain[1]).clamp(0.0, 1.0);
        final b = ((pixel.b / 255.0) * illuminantGain[2]).clamp(0.0, 1.0);

        final maxVal = math.max(r, math.max(g, b));
        final minVal = math.min(r, math.min(g, b));
        final delta = maxVal - minVal;

        // Achtergrond (bijna wit/crème): hoge helderheid, lage saturatie.
        // Met een echte (i.p.v. vaste) box mag dit strenger/relatiever, zodat
        // glimmende highlights op groene schil niet meteen als achtergrond
        // wegvallen: drempel schuift mee met hoe helder de regio al is.
        final sat = maxVal == 0 ? 0.0 : delta / maxVal;
        if (maxVal > 0.90 && sat < 0.18) continue;

        // Bruine/zwarte vlekken (overrijp): laag-gemiddelde helderheid,
        // ongeacht hue. Telt apart mee, niet in de hue-schaal.
        if (maxVal < 0.35) {
          darkSpotPixels++;
          validPixels++;
          continue;
        }

        if (delta < 0.035) continue; // grijs/neutraal, geen bruikbare hue

        double hue;
        if (maxVal == r) {
          hue = 60 * (((g - b) / delta) % 6);
        } else if (maxVal == g) {
          hue = 60 * (((b - r) / delta) + 2);
        } else {
          hue = 60 * (((r - g) / delta) + 4);
        }
        if (hue < 0) hue += 360;

        // Alleen banaan-spectrum hues (groen t/m geel) meenemen
        if (hue >= 30 && hue <= 150) {
          hues.add(hue);
          sats.add(sat);
          vals.add(maxVal);
          final binIndex = ((hue - 30) / 10).floor().clamp(0, histogram.length - 1);
          histogram[binIndex]++;
          validPixels++;
        }
      }
    }

    if (validPixels < 15) return null;
    return _RawSample(
      hues: hues,
      sats: sats,
      vals: vals,
      histogram: histogram,
      darkSpotPixels: darkSpotPixels,
      validPixels: validPixels,
    );
  }

  _RegionAnalysis? _finish(_RawSample sample) {
    final darkFraction = sample.darkSpotPixels / sample.validPixels;

    if (sample.hues.isEmpty) {
      if (darkFraction > 0.4) {
        return _RegionAnalysis(
          medianHue: 0,
          satMedian: 0,
          valMedian: 0,
          darkFraction: darkFraction,
          validPixels: sample.validPixels,
          histogram: sample.histogram,
          allBlack: true,
        );
      }
      return null;
    }

    // Mediaan is robuuster tegen uitschieters (highlights/schaduw) dan gemiddelde.
    final sortedHues = List<double>.from(sample.hues)..sort();
    final sortedSats = List<double>.from(sample.sats)..sort();
    final sortedVals = List<double>.from(sample.vals)..sort();
    var medianHue = sortedHues[sortedHues.length ~/ 2];

    // Bimodale hue-verdeling (twee duidelijk gescheiden pieken in het
    // histogram) is een teken dat de crop nog steeds twee oppervlakken bevat
    // (bijv. een randje hand/tafel). Kies dan de mediaan binnen de grootste
    // cluster i.p.v. de mediaan over de hele, mogelijk verontreinigde set.
    final dominant = _dominantHistogramCluster(sample.histogram);
    if (dominant != null) {
      final inCluster = sample.hues.where((h) => h >= dominant.$1 && h <= dominant.$2).toList()..sort();
      if (inCluster.length >= 20) {
        medianHue = inCluster[inCluster.length ~/ 2];
      }
    }

    return _RegionAnalysis(
      medianHue: medianHue,
      satMedian: sortedSats[sortedSats.length ~/ 2],
      valMedian: sortedVals[sortedVals.length ~/ 2],
      darkFraction: darkFraction,
      validPixels: sample.validPixels,
      histogram: sample.histogram,
      allBlack: false,
    );
  }

  /// Zoekt naar twee duidelijk gescheiden pieken in het 12-bins hue-histogram
  /// (30°-150°) en geeft, als die er zijn, het hue-bereik van de grootste
  /// piek terug (min, max in graden). Puur signaal, geen harde blokkering.
  (double, double)? _dominantHistogramCluster(List<int> histogram) {
    final total = histogram.fold<int>(0, (a, b) => a + b);
    if (total < 40) return null;

    // Vind lokale maxima (bins die groter zijn dan beide buren).
    final peaks = <int>[];
    for (int i = 0; i < histogram.length; i++) {
      final left = i == 0 ? 0 : histogram[i - 1];
      final right = i == histogram.length - 1 ? 0 : histogram[i + 1];
      if (histogram[i] > left && histogram[i] >= right && histogram[i] > total * 0.08) {
        peaks.add(i);
      }
    }
    if (peaks.length < 2) return null;

    peaks.sort((a, b) => histogram[b].compareTo(histogram[a]));
    final bestBin = peaks.first;
    // Alleen ingrijpen als er ook een significante tweede piek is, ver genoeg weg.
    final secondBin = peaks.length > 1 ? peaks[1] : null;
    if (secondBin == null || (secondBin - bestBin).abs() < 3) return null;

    final binLo = 30.0 + bestBin * 10.0;
    final binHi = binLo + 10.0;
    // Geef wat marge rond de piek-bin.
    return (math.max(30.0, binLo - 10.0), math.min(150.0, binHi + 10.0));
  }

  InputImage? _buildInputImage(CameraImage image, CameraDescription camera) {
    int totalBytes = 0;
    for (final plane in image.planes) {
      totalBytes += plane.bytes.length;
    }
    final bytes = Uint8List(totalBytes);
    int offset = 0;
    for (final plane in image.planes) {
      bytes.setRange(offset, offset + plane.bytes.length, plane.bytes);
      offset += plane.bytes.length;
    }

    final imageSize = ui.Size(
      image.width.toDouble(),
      image.height.toDouble(),
    );

    final imageRotation = _rotationFromDegrees(camera.sensorOrientation);
    final inputImageFormat =
        InputImageFormatValue.fromRawValue(image.format.raw) ??
            InputImageFormat.nv21;

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  InputImageRotation _rotationFromDegrees(int degrees) {
    switch (degrees) {
      case 90:  return InputImageRotation.rotation90deg;
      case 180: return InputImageRotation.rotation180deg;
      case 270: return InputImageRotation.rotation270deg;
      default:  return InputImageRotation.rotation0deg;
    }
  }

  Future<void> dispose() async {
    await _labeler?.close();
    await _objectDetector?.close();
  }
}

class _NamedLabel {
  final String name;
  final double confidence;
  _NamedLabel({required this.name, required this.confidence});
}

class _RawSample {
  final List<double> hues;
  final List<double> sats;
  final List<double> vals;
  final List<int> histogram;
  final int darkSpotPixels;
  final int validPixels;

  _RawSample({
    required this.hues,
    required this.sats,
    required this.vals,
    required this.histogram,
    required this.darkSpotPixels,
    required this.validPixels,
  });
}

class _RegionAnalysis {
  final double medianHue;
  final double satMedian;
  final double valMedian;
  final double darkFraction;
  final int validPixels;
  final List<int> histogram;
  final bool allBlack;

  _RegionAnalysis({
    required this.medianHue,
    required this.satMedian,
    required this.valMedian,
    required this.darkFraction,
    required this.validPixels,
    required this.histogram,
    required this.allBlack,
  });
}

enum BananaColor { green, yellow, black, unknown }

/// Resultaat van de rijpheidsanalyse van een banaanfoto.
///
/// [ripenessStage] loopt van 1.0 (volledig groen) tot 7.0 (volledig geel),
/// gekalibreerd op een echte rijpheidsschaal. Waarden boven 7.0 (tot ~8.0)
/// geven overrijpe/bruin-vlekkige bananen aan.
class ColorAnalysisResult {
  final BananaColor primary;
  final double ripenessStage;
  final double darkSpotFraction;

  // Extra features, vooral bedoeld om als feedback-record opgeslagen te
  // worden (zie feedback_store.dart) en voor eventuele toekomstige kalibratie.
  final double medianHueRaw;
  final double satMedian;
  final double valMedian;
  final int validPixelCount;
  final List<int> hueHistogram;

  // Waar is er precies gekeken? Nodig om de gedetecteerde box te kunnen tonen.
  final String boxSource;
  final double boxLeftFrac;
  final double boxTopFrac;
  final double boxRightFrac;
  final double boxBottomFrac;
  final double imageAspectRatio;

  const ColorAnalysisResult({
    required this.primary,
    required this.ripenessStage,
    required this.darkSpotFraction,
    this.medianHueRaw = 0,
    this.satMedian = 0,
    this.valMedian = 0,
    this.validPixelCount = 0,
    this.hueHistogram = const [],
    this.boxSource = 'unknown',
    this.boxLeftFrac = 0.30,
    this.boxTopFrac = 0.30,
    this.boxRightFrac = 0.70,
    this.boxBottomFrac = 0.70,
    this.imageAspectRatio = 1.0,
  });

  factory ColorAnalysisResult.unknown({
    String boxSource = 'unknown',
    double boxLeftFrac = 0.30,
    double boxTopFrac = 0.30,
    double boxRightFrac = 0.70,
    double boxBottomFrac = 0.70,
    double imageAspectRatio = 1.0,
  }) =>
      ColorAnalysisResult(
        primary: BananaColor.unknown,
        ripenessStage: 0,
        darkSpotFraction: 0,
        boxSource: boxSource,
        boxLeftFrac: boxLeftFrac,
        boxTopFrac: boxTopFrac,
        boxRightFrac: boxRightFrac,
        boxBottomFrac: boxBottomFrac,
        imageAspectRatio: imageAspectRatio,
      );
}

class DetectionResult {
  final String label;
  final double confidence;
  final bool isBanana;
  final List<String> allLabels;
  final BananaColor bananaColor;

  const DetectionResult({
    required this.label,
    required this.confidence,
    required this.isBanana,
    required this.allLabels,
    this.bananaColor = BananaColor.unknown,
  });
}
