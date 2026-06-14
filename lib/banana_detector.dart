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

  Future<ColorAnalysisResult> analyzePhotoColor(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return ColorAnalysisResult.unknown();

      // Scan the central 40% of the image to avoid background
      final startX = (decoded.width * 0.30).toInt();
      final endX   = (decoded.width * 0.70).toInt();
      final startY = (decoded.height * 0.30).toInt();
      final endY   = (decoded.height * 0.70).toInt();

      int greenPixels  = 0;
      int yellowPixels = 0;
      int blackPixels  = 0;
      int validPixels  = 0;

      for (int y = startY; y < endY; y += 6) {
        for (int x = startX; x < endX; x += 6) {
          final pixel = decoded.getPixel(x, y);
          final r = pixel.r / 255.0;
          final g = pixel.g / 255.0;
          final b = pixel.b / 255.0;

          final maxVal = [r, g, b].reduce((a, c) => a > c ? a : c);
          final minVal = [r, g, b].reduce((a, c) => a < c ? a : c);
          final delta  = maxVal - minVal;

          // Skip near-black, near-white, and near-grey pixels
          if (maxVal < 0.12 || delta < 0.06) continue;

          // Compute HSV hue
          double hue = 0;
          if (delta > 0) {
            if (maxVal == r) {
              hue = 60 * (((g - b) / delta) % 6);
            } else if (maxVal == g) {
              hue = 60 * (((b - r) / delta) + 2);
            } else {
              hue = 60 * (((r - g) / delta) + 4);
            }
            if (hue < 0) hue += 360;
          }

          final sat = maxVal == 0 ? 0.0 : delta / maxVal;

          // Only keep banana-spectrum hues (yellow-green range) and dark pixels
          // Dark/brown pixels (overripe): low brightness regardless of hue
          if (maxVal < 0.35 && sat < 0.5) {
            blackPixels++;
            validPixels++;
            continue;
          }

          // Green banana: hue 70–150°, saturation can be modest (0.15+)
          // Yellow banana: hue 30–70°, typically higher saturation
          // We deliberately lower the saturation threshold for green
          // because unripe bananas are often more muted in colour.
          if (hue >= 15 && hue < 150 && sat >= 0.15) {
            validPixels++;
            if (hue >= 72) {
              greenPixels++;
            } else {
              yellowPixels++;
            }
          }
        }
      }

      if (validPixels < 15) return ColorAnalysisResult.unknown();

      // Pixel fractions
      final totalColored = greenPixels + yellowPixels + blackPixels;
      if (totalColored == 0) return ColorAnalysisResult.unknown();

      final greenFrac  = greenPixels  / totalColored;
      final yellowFrac = yellowPixels / totalColored;
      final blackFrac  = blackPixels  / totalColored;

      // Derive primary colour
      BananaColor primary;
      if (blackFrac > 0.45) {
        primary = BananaColor.black;
      } else if (greenFrac > 0.35) {
        primary = BananaColor.green;
      } else {
        primary = BananaColor.yellow;
      }

      return ColorAnalysisResult(
        primary: primary,
        greenFraction:  greenFrac,
        yellowFraction: yellowFrac,
        blackFraction:  blackFrac,
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

/// Holds the per-pixel colour breakdown of a banana photo.
class ColorAnalysisResult {
  final BananaColor primary;
  final double greenFraction;
  final double yellowFraction;
  final double blackFraction;

  const ColorAnalysisResult({
    required this.primary,
    required this.greenFraction,
    required this.yellowFraction,
    required this.blackFraction,
  });

  factory ColorAnalysisResult.unknown() => const ColorAnalysisResult(
        primary: BananaColor.unknown,
        greenFraction: 0,
        yellowFraction: 0,
        blackFraction: 0,
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