import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Eén regel correctie/bevestiging van een gebruiker op een rijpheids-resultaat.
///
/// Blijft volledig lokaal op het toestel (geen backend). Het schema is bewust
/// zo opgezet dat het later, zonder migratie, geëxporteerd of naar een
/// eventuele gedeelde backend gestuurd zou kunnen worden (schemaVersion,
/// deviceId, syncStatus zijn daarop voorbereid, ook al wordt dat nu niet gebouwd).
class FeedbackRecord {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String recordId;
  final String timestamp; // ISO8601
  final String deviceId;
  final String appVersion;
  final String? photoRef; // pad naar gekopieerde foto onder app-documents

  final String boundingBoxSource; // "mlkit_object_detector" | "fixed_rect_fallback"
  final double boxLeftFrac;
  final double boxTopFrac;
  final double boxRightFrac;
  final double boxBottomFrac;

  final double medianHueRaw; // hue vóór kalibratie-bias, zodat herkalibratie altijd
                              // vanaf de ruwe meting kan starten
  final double satMedian;
  final double valMedian;
  final double darkSpotFraction;
  final int validPixelCount;
  final List<int> hueHistogram;

  final double predictedStage;
  final String predictedColorBucket;

  final bool userConfirmed;
  final double? correctedStage;
  final String? correctedColorBucket;

  bool syncStatus; // ongebruikt vandaag; hook voor eventuele toekomstige sync

  FeedbackRecord({
    this.schemaVersion = currentSchemaVersion,
    required this.recordId,
    required this.timestamp,
    required this.deviceId,
    required this.appVersion,
    this.photoRef,
    required this.boundingBoxSource,
    required this.boxLeftFrac,
    required this.boxTopFrac,
    required this.boxRightFrac,
    required this.boxBottomFrac,
    required this.medianHueRaw,
    required this.satMedian,
    required this.valMedian,
    required this.darkSpotFraction,
    required this.validPixelCount,
    required this.hueHistogram,
    required this.predictedStage,
    required this.predictedColorBucket,
    required this.userConfirmed,
    this.correctedStage,
    this.correctedColorBucket,
    this.syncStatus = false,
  });

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'recordId': recordId,
        'timestamp': timestamp,
        'deviceId': deviceId,
        'appVersion': appVersion,
        'photoRef': photoRef,
        'boundingBox': {
          'left': boxLeftFrac,
          'top': boxTopFrac,
          'right': boxRightFrac,
          'bottom': boxBottomFrac,
          'source': boundingBoxSource,
        },
        'features': {
          'medianHueRaw': medianHueRaw,
          'satMedian': satMedian,
          'valMedian': valMedian,
          'darkSpotFraction': darkSpotFraction,
          'validPixelCount': validPixelCount,
          'hueHistogram': hueHistogram,
        },
        'predictedStage': predictedStage,
        'predictedColorBucket': predictedColorBucket,
        'userConfirmed': userConfirmed,
        'correctedStage': correctedStage,
        'correctedColorBucket': correctedColorBucket,
        'syncStatus': syncStatus,
      };

  static FeedbackRecord? tryFromJson(Map<String, dynamic> json) {
    try {
      final box = json['boundingBox'] as Map<String, dynamic>;
      final features = json['features'] as Map<String, dynamic>;
      return FeedbackRecord(
        schemaVersion: json['schemaVersion'] as int? ?? 1,
        recordId: json['recordId'] as String,
        timestamp: json['timestamp'] as String,
        deviceId: json['deviceId'] as String? ?? 'unknown',
        appVersion: json['appVersion'] as String? ?? 'unknown',
        photoRef: json['photoRef'] as String?,
        boundingBoxSource: box['source'] as String? ?? 'unknown',
        boxLeftFrac: (box['left'] as num?)?.toDouble() ?? 0.0,
        boxTopFrac: (box['top'] as num?)?.toDouble() ?? 0.0,
        boxRightFrac: (box['right'] as num?)?.toDouble() ?? 1.0,
        boxBottomFrac: (box['bottom'] as num?)?.toDouble() ?? 1.0,
        medianHueRaw: (features['medianHueRaw'] as num).toDouble(),
        satMedian: (features['satMedian'] as num?)?.toDouble() ?? 0.0,
        valMedian: (features['valMedian'] as num?)?.toDouble() ?? 0.0,
        darkSpotFraction: (features['darkSpotFraction'] as num?)?.toDouble() ?? 0.0,
        validPixelCount: (features['validPixelCount'] as num?)?.toInt() ?? 0,
        hueHistogram: (features['hueHistogram'] as List?)?.map((e) => e as int).toList() ?? const [],
        predictedStage: (json['predictedStage'] as num).toDouble(),
        predictedColorBucket: json['predictedColorBucket'] as String? ?? 'unknown',
        userConfirmed: json['userConfirmed'] as bool? ?? false,
        correctedStage: (json['correctedStage'] as num?)?.toDouble(),
        correctedColorBucket: json['correctedColorBucket'] as String?,
        syncStatus: json['syncStatus'] as bool? ?? false,
      );
    } catch (_) {
      // Eén kapotte/onvolledige regel mag de rest van het logbestand niet ongeldig maken.
      return null;
    }
  }
}

/// Lokale, append-only opslag van feedback (JSON Lines) — bewust geen sqflite:
/// dit is puur een event-log, geen bevragen/joins nodig, en zo blijft de
/// dependency-voetafdruk van de app klein.
class FeedbackStore {
  static const _logFileName = 'feedback_log.jsonl';
  static const _deviceIdFileName = 'device_id.txt';
  static const _photosDirName = 'feedback_photos';

  String? _cachedDeviceId;

  Future<Directory> _documentsDir() => getApplicationDocumentsDirectory();

  Future<File> _logFile() async {
    final dir = await _documentsDir();
    return File(p.join(dir.path, _logFileName));
  }

  Future<String> deviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;
    final dir = await _documentsDir();
    final file = File(p.join(dir.path, _deviceIdFileName));
    if (await file.exists()) {
      final id = (await file.readAsString()).trim();
      if (id.isNotEmpty) {
        _cachedDeviceId = id;
        return id;
      }
    }
    final id = _randomId();
    await file.writeAsString(id);
    _cachedDeviceId = id;
    return id;
  }

  String _randomId() {
    final rnd = Random();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String newRecordId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    return '$ts-${_randomId().substring(0, 8)}';
  }

  /// Kopieert de gemaakte foto naar permanente app-opslag (de camera-plugin's
  /// takePicture() output kan in een door het OS opruimbare cache-locatie staan).
  Future<String> copyPhotoForRecord(String sourcePath, String recordId) async {
    final dir = await _documentsDir();
    final photosDir = Directory(p.join(dir.path, _photosDirName));
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    final ext = p.extension(sourcePath).isEmpty ? '.jpg' : p.extension(sourcePath);
    final destPath = p.join(photosDir.path, '$recordId$ext');
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<void> appendRecord(FeedbackRecord record) async {
    final file = await _logFile();
    final line = '${jsonEncode(record.toJson())}\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  Future<List<FeedbackRecord>> readAll() async {
    final file = await _logFile();
    if (!await file.exists()) return [];
    final lines = await file.readAsLines();
    final records = <FeedbackRecord>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final record = FeedbackRecord.tryFromJson(json);
        if (record != null) records.add(record);
      } catch (_) {
        continue; // corrupte regel overslaan, rest van de historie blijft bruikbaar
      }
    }
    return records;
  }
}
