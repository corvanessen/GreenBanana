import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;

const _bananaLabels = {
  'banana', 'fruit', 'yellow', 'food', 'produce',
  'plantain', 'natural foods', 'whole food',
  'plant', 'ingredient', 'vegetable', 'cuisine',
};

class BananaDetector {
  ImageLabeler? _labeler;
  List<String> _labels = [];
  bool _isProcessing = false;
  DateTime _lastProcessed = DateTime(0);

  Future<void> init() async {
    final labelData = await rootBundle.loadString('assets/labels.txt');
    _labels = labelData.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

    final modelPath = await _copyAssetToFile('assets/mobilenet_v1_1.0_224_quant.tflite');
    final options = LocalLabelerOptions(
      confidenceThreshold: 0.2,
      modelPath: modelPath,
    );
    _labeler = ImageLabeler(options: options);
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

      _NamedLabel? bananaLabel;
      final bestLabel = namedLabels.first;

      for (final label in namedLabels) {
        final lower = label.name.toLowerCase();
        if (_bananaLabels.any((b) => lower.contains(b))) {
          if (bananaLabel == null || label.confidence > bananaLabel.confidence) {
            bananaLabel = label;
          }
        }
      }

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

  Future<ColorAnalysisResult> analyzePhotoColor(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return ColorAnalysisResult.unknown();

      // Scan de centrale 40% van de foto om achtergrond te vermijden
      final startX = (decoded.width * 0.30).toInt();
      final endX   = (decoded.width * 0.70).toInt();
      final startY = (decoded.height * 0.30).toInt();
      final endY   = (decoded.height * 0.70).toInt();

      final List<double> hues = [];
      int darkSpotPixels = 0; // bruine/zwarte vlekken (overrijp)
      int validPixels = 0;

      for (int y = startY; y < endY; y += 6) {
        for (int x = startX; x < endX; x += 6) {
          final pixel = decoded.getPixel(x, y);
          final r = pixel.r / 255.0;
          final g = pixel.g / 255.0;
          final b = pixel.b / 255.0;

          final maxVal = [r, g, b].reduce((a, c) => a > c ? a : c);
          final minVal = [r, g, b].reduce((a, c) => a < c ? a : c);
          final delta  = maxVal - minVal;

          // Achtergrond (bijna wit/crème): hoge helderheid, lage saturatie
          final sat = maxVal == 0 ? 0.0 : delta / maxVal;
          if (maxVal > 0.85 && sat < 0.25) continue;

          // Bruine/zwarte vlekken (overrijp): laag-gemiddelde helderheid,
          // ongeacht hue. Telt apart mee, niet in de hue-schaal.
          if (maxVal < 0.35) {
            darkSpotPixels++;
            validPixels++;
            continue;
          }

          if (delta < 0.04) continue; // grijs/neutraal, geen bruikbare hue

          // HSV hue berekenen
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
            validPixels++;
          }
        }
      }

      if (validPixels < 15) return ColorAnalysisResult.unknown();

      final darkFraction = darkSpotPixels / validPixels;

      // Geen kleurpixels gevonden (bijv. volledig overrijp/zwart)
      if (hues.isEmpty) {
        if (darkFraction > 0.4) {
          return ColorAnalysisResult(
            primary: BananaColor.black,
            ripenessStage: 8.0,
            darkSpotFraction: darkFraction,
          );
        }
        return ColorAnalysisResult.unknown();
      }

      // Mediaan is robuuster tegen uitschieters (highlights/schaduw) dan gemiddelde
      hues.sort();
      final medianHue = hues[hues.length ~/ 2];

      double stage = _hueToRipeness(medianHue);

      // Veel bruine vlekken duwt het stadium richting overrijp (8),
      // ook als de onderliggende schil-hue nog geel is.
      if (darkFraction > 0.15) {
        final pushedStage = 7.0 + (darkFraction.clamp(0.0, 0.6) / 0.6);
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
        darkSpotFraction: darkFraction,
      );

    } catch (e) {
      debugPrint('⚠️ Kleuranalyse mislukt: $e');
      return ColorAnalysisResult.unknown();
    }
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
  }
}

class _NamedLabel {
  final String name;
  final double confidence;
  _NamedLabel({required this.name, required this.confidence});
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

  const ColorAnalysisResult({
    required this.primary,
    required this.ripenessStage,
    required this.darkSpotFraction,
  });

  factory ColorAnalysisResult.unknown() => const ColorAnalysisResult(
        primary: BananaColor.unknown,
        ripenessStage: 0,
        darkSpotFraction: 0,
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