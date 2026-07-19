import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'banana_detector.dart';
import 'feedback_store.dart';
import 'dart:io';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraScreen({super.key, required this.cameras});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  BananaDetector? _detector;
  DetectionResult? _detection;

  bool _permissionGranted = false;
  bool _isInitializing = true;
  bool _isTakingPhoto = false;
  String? _errorMessage;
  String? _capturedPhotoPath;
  ColorAnalysisResult? _photoColor;
  bool _feedbackSubmitted = false;
  bool _feedbackSubmitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissionAndInit();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.stopImageStream();
    _controller?.dispose();
    _detector?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _controller?.stopImageStream();
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed && _permissionGranted) {
      _initCamera();
    }
  }

  Future<void> _requestPermissionAndInit() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      setState(() => _permissionGranted = true);
      await _initCamera();
    } else {
      setState(() {
        _isInitializing = false;
        _errorMessage = status.isPermanentlyDenied
            ? 'Camera-toegang permanent geweigerd.\nOpen instellingen om dit te wijzigen.'
            : 'Camera-toegang geweigerd.';
      });
    }
  }

  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) {
      setState(() {
        _isInitializing = false;
        _errorMessage = 'Geen camera gevonden op dit apparaat.';
      });
      return;
    }

    _detector = BananaDetector();
    await _detector!.init();

    final controller = CameraController(
      widget.cameras[0],
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    _controller = controller;

    try {
      await controller.initialize();
      if (mounted) setState(() => _isInitializing = false);
      controller.startImageStream(_onCameraImage);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Camera kon niet worden gestart: $e';
        });
      }
    }
  }

  void _onCameraImage(CameraImage image) {
    if (_capturedPhotoPath != null) return; // foto al gemaakt, stop scannen
    if (_isTakingPhoto) return;

    _detector?.processImage(image, widget.cameras[0]).then((result) {
      if (!mounted) return;
      if (result != null) setState(() => _detection = result);

      // Banaan met hoge zekerheid → foto maken
      if (result != null && result.isBanana && result.confidence >= 0.80) {
        _takePhoto();
      }
    }).catchError((e) {
      debugPrint('⚠️ Frame overgeslagen: $e');
    });
  }

 Future<void> _takePhoto() async {
  if (_isTakingPhoto || _controller == null) return;
  setState(() => _isTakingPhoto = true);

    try {
      await _controller!.stopImageStream();
      final file = await _controller!.takePicture();

      final color = await _detector!.analyzePhotoColor(file.path);

      if (mounted) {
        setState(() {
          _capturedPhotoPath = file.path;
          _photoColor = color;
          _isTakingPhoto = false;
        });
      }
    } catch (e) {
      debugPrint('⚠️ Foto maken mislukt: $e');
      if (mounted) {
        setState(() => _isTakingPhoto = false);
        _controller!.startImageStream(_onCameraImage);
      }
    }
  }

  Future<void> _resetScan() async {
    setState(() {
      _capturedPhotoPath = null;
      _photoColor = null;
      _detection = null;
      _isTakingPhoto = false;
      _feedbackSubmitted = false;
      _feedbackSubmitting = false;
    });
    await _controller!.startImageStream(_onCameraImage);
  }

  // ─── Feedback ───────────────────────────────────────────────────────────
  //
  // correctedBucket == null betekent "klopt, gebruiker bevestigt het
  // voorspelde resultaat". Anders is het de kleur-emmer ('green'/'yellow'/
  // 'black') die de gebruiker als correctie aangeeft. Alles blijft lokaal op
  // dit toestel (zie feedback_store.dart) — geen backend.
  Future<void> _submitFeedback(String? correctedBucket) async {
    if (_feedbackSubmitted || _feedbackSubmitting) return;
    if (_capturedPhotoPath == null || _photoColor == null || _detector == null) return;

    setState(() => _feedbackSubmitting = true);

    try {
      final store = _detector!.feedbackStore;
      final recordId = store.newRecordId();
      final photoRef = await store.copyPhotoForRecord(_capturedPhotoPath!, recordId);
      final deviceId = await store.deviceId();
      final photoColor = _photoColor!;

      final record = FeedbackRecord(
        recordId: recordId,
        timestamp: DateTime.now().toIso8601String(),
        deviceId: deviceId,
        appVersion: '1.0.0',
        photoRef: photoRef,
        boundingBoxSource: photoColor.boxSource,
        boxLeftFrac: photoColor.boxLeftFrac,
        boxTopFrac: photoColor.boxTopFrac,
        boxRightFrac: photoColor.boxRightFrac,
        boxBottomFrac: photoColor.boxBottomFrac,
        medianHueRaw: photoColor.medianHueRaw,
        satMedian: photoColor.satMedian,
        valMedian: photoColor.valMedian,
        darkSpotFraction: photoColor.darkSpotFraction,
        validPixelCount: photoColor.validPixelCount,
        hueHistogram: photoColor.hueHistogram,
        predictedStage: photoColor.ripenessStage,
        predictedColorBucket: _bucketName(photoColor.primary),
        userConfirmed: correctedBucket == null,
        correctedStage: correctedBucket == null ? null : _stageForBucket(correctedBucket),
        correctedColorBucket: correctedBucket,
      );

      await store.appendRecord(record);
      if (mounted) {
        setState(() {
          _feedbackSubmitted = true;
          _feedbackSubmitting = false;
        });
      }
    } catch (e) {
      debugPrint('⚠️ Feedback opslaan mislukt: $e');
      if (mounted) setState(() => _feedbackSubmitting = false);
    }
  }

  static String _bucketName(BananaColor c) {
    switch (c) {
      case BananaColor.green:   return 'green';
      case BananaColor.yellow:  return 'yellow';
      case BananaColor.black:   return 'black';
      case BananaColor.unknown: return 'unknown';
    }
  }

  static double _stageForBucket(String bucket) {
    switch (bucket) {
      case 'green':  return 1.5;
      case 'yellow': return 4.5;
      case 'black':  return 7.5;
      default:       return 4.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isInitializing) return const _LoadingView();
    if (_errorMessage != null) {
      return _ErrorView(
        message: _errorMessage!,
        onRetry: _permissionGranted ? _initCamera : _requestPermissionAndInit,
        showSettings: _errorMessage!.contains('permanent'),
      );
    }
    if (_controller == null || !_controller!.value.isInitialized) {
      return const _LoadingView();
    }

    // Foto gemaakt → toon foto fullscreen met resultaat
    if (_capturedPhotoPath != null) {
      return _PhotoResultView(
        photoPath: _capturedPhotoPath!,
        detection: _detection,
        colorResult: _photoColor ?? ColorAnalysisResult.unknown(),
        onReset: _resetScan,
        onFeedback: _submitFeedback,
        feedbackSubmitted: _feedbackSubmitted,
        feedbackSubmitting: _feedbackSubmitting,
      );
    }

    // Foto wordt gemaakt
    if (_isTakingPhoto) {
      return const _LoadingView(message: 'Foto maken…');
    }

    // Normaal scannen
    return _CameraPreviewWithOverlay(
      controller: _controller!,
      detection: _detection,
    );
  }
}

// ─── Foto resultaat scherm ────────────────────────────────────────────────────

class _PhotoResultView extends StatelessWidget {
  final String photoPath;
  final DetectionResult? detection;
  final ColorAnalysisResult colorResult;
  final VoidCallback onReset;
  final ValueChanged<String?> onFeedback;
  final bool feedbackSubmitted;
  final bool feedbackSubmitting;

  const _PhotoResultView({
    required this.photoPath,
    required this.detection,
    required this.colorResult,
    required this.onReset,
    required this.onFeedback,
    required this.feedbackSubmitted,
    required this.feedbackSubmitting,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Foto fullscreen
        Image.file(
          File(photoPath),
          fit: BoxFit.cover,
        ),

        // Toont waar de kleuranalyse daadwerkelijk gekeken heeft (echte
        // gedetecteerde bounding box, of het vaste terugval-vak).
        _DetectionBoxOverlay(colorResult: colorResult),

        // Donkere overlay onderin
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom + 32,
              top: 28, left: 24, right: 24,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.92),
                  Colors.transparent,
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Banaan emoji + percentage
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('🍌', style: TextStyle(fontSize: 26)),
                    const SizedBox(width: 10),
                    Text(
                      detection != null
                          ? 'Banaan — ${(detection!.confidence * 100).toStringAsFixed(0)}%'
                          : 'Banaan herkend',
                      style: const TextStyle(
                        color: Color(0xFFFFD600),
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Kleur resultaat
                _ColorResultCard(result: colorResult),

                if (colorResult.primary != BananaColor.unknown)
                  _FeedbackRow(
                    predicted: colorResult.primary,
                    submitted: feedbackSubmitted,
                    submitting: feedbackSubmitting,
                    onTap: onFeedback,
                  ),

                const SizedBox(height: 24),

                // Nieuwe scan knop
                OutlinedButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Nieuwe scan'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD4E84A),
                    side: const BorderSide(color: Color(0xFFD4E84A)),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Top bar
        Positioned(
          top: 0, left: 0, right: 0,
          child: Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              left: 20, right: 20, bottom: 12,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
              ),
            ),
            child: const Text(
              'GreenBanana',
              style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w800,
                color: Color(0xFFD4E84A), letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Gedetecteerde scan-regio (echte box of terugval-vak) ────────────────────

class _DetectionBoxOverlay extends StatelessWidget {
  final ColorAnalysisResult colorResult;
  const _DetectionBoxOverlay({required this.colorResult});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _DetectionBoxPainter(
            imageAspectRatio: colorResult.imageAspectRatio,
            leftFrac: colorResult.boxLeftFrac,
            topFrac: colorResult.boxTopFrac,
            rightFrac: colorResult.boxRightFrac,
            bottomFrac: colorResult.boxBottomFrac,
            isRealDetection: colorResult.boxSource == 'mlkit_object_detector',
          ),
        );
      },
    );
  }
}

class _DetectionBoxPainter extends CustomPainter {
  final double imageAspectRatio;
  final double leftFrac;
  final double topFrac;
  final double rightFrac;
  final double bottomFrac;
  final bool isRealDetection;

  _DetectionBoxPainter({
    required this.imageAspectRatio,
    required this.leftFrac,
    required this.topFrac,
    required this.rightFrac,
    required this.bottomFrac,
    required this.isRealDetection,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || imageAspectRatio <= 0) return;

    // Zelfde BoxFit.cover-wiskunde als Image.file(fit: BoxFit.cover) gebruikt,
    // zodat de box precies over de zichtbare (bijgesneden) foto valt.
    final containerAspectRatio = size.width / size.height;
    double scaledWidth, scaledHeight, offsetX, offsetY;
    if (imageAspectRatio > containerAspectRatio) {
      scaledHeight = size.height;
      scaledWidth = size.height * imageAspectRatio;
      offsetX = (size.width - scaledWidth) / 2;
      offsetY = 0;
    } else {
      scaledWidth = size.width;
      scaledHeight = size.width / imageAspectRatio;
      offsetX = 0;
      offsetY = (size.height - scaledHeight) / 2;
    }

    final rect = Rect.fromLTRB(
      offsetX + leftFrac * scaledWidth,
      offsetY + topFrac * scaledHeight,
      offsetX + rightFrac * scaledWidth,
      offsetY + bottomFrac * scaledHeight,
    );

    final paint = Paint()
      ..color = (isRealDetection ? const Color(0xFFD4E84A) : const Color(0xFF999999))
          .withValues(alpha: 0.9)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12)), paint);
  }

  @override
  bool shouldRepaint(covariant _DetectionBoxPainter old) =>
      old.leftFrac != leftFrac ||
      old.topFrac != topFrac ||
      old.rightFrac != rightFrac ||
      old.bottomFrac != bottomFrac ||
      old.imageAspectRatio != imageAspectRatio ||
      old.isRealDetection != isRealDetection;
}

// ─── Feedback: klopt dit resultaat? ───────────────────────────────────────────

class _FeedbackRow extends StatelessWidget {
  final BananaColor predicted;
  final bool submitted;
  final bool submitting;
  final ValueChanged<String?> onTap;

  const _FeedbackRow({
    required this.predicted,
    required this.submitted,
    required this.submitting,
    required this.onTap,
  });

  String? get _predictedBucket {
    switch (predicted) {
      case BananaColor.green:   return 'green';
      case BananaColor.yellow:  return 'yellow';
      case BananaColor.black:   return 'black';
      case BananaColor.unknown: return null;
    }
  }

  String _labelFor(String bucket) {
    switch (bucket) {
      case 'green':  return '🟢 G';
      case 'yellow': return '🟡 Y';
      default:       return '⚫';
    }
  }

  // Effen, herkenbare knopkleur per emmer i.p.v. de neutrale grijze outline
  // van voorheen — groen bewust donkerder dan de rest zodat de knop niet
  // wegvalt tegen een gele/groene achtergrondfoto. Voorgrondkleur per knop
  // gekozen op leesbaarheid (wit op donker, donker op het lichte geel).
  ({Color background, Color foreground}) _styleFor(String bucket) {
    switch (bucket) {
      case 'green':  return (background: const Color(0xFF1B5E20), foreground: Colors.white);
      case 'yellow': return (background: const Color(0xFFFFC400), foreground: const Color(0xFF3A2E00));
      default:       return (background: const Color(0xFF3A3A3A), foreground: Colors.white);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (submitted) {
      return const Padding(
        padding: EdgeInsets.only(top: 10),
        child: Text(
          'Bedankt voor je feedback! 🙏',
          style: TextStyle(color: Color(0xFFD4E84A), fontSize: 12),
        ),
      );
    }

    const buckets = ['green', 'yellow', 'black'];
    final predictedBucket = _predictedBucket;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Klopt dit rijpheidsniveau?',
            style: TextStyle(color: Color(0xFF999999), fontSize: 11),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _FeedbackChip(
                label: '✓ Klopt',
                background: const Color(0xFFD4E84A).withValues(alpha: 0.15),
                foreground: const Color(0xFFD4E84A),
                onTap: submitting ? null : () => onTap(null),
              ),
              for (final bucket in buckets)
                if (bucket != predictedBucket)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _FeedbackChip(
                      label: _labelFor(bucket),
                      background: _styleFor(bucket).background,
                      foreground: _styleFor(bucket).foreground,
                      onTap: submitting ? null : () => onTap(bucket),
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeedbackChip extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback? onTap;

  const _FeedbackChip({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: foreground.withValues(alpha: 0.6), width: 1.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: foreground,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ─── Preview + overlay ────────────────────────────────────────────────────────

class _CameraPreviewWithOverlay extends StatelessWidget {
  final CameraController controller;
  final DetectionResult? detection;

  const _CameraPreviewWithOverlay({
    required this.controller,
    required this.detection,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Stack(
      fit: StackFit.expand,
      children: [
        SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 1,
              height: controller.value.aspectRatio,
              child: CameraPreview(controller),
            ),
          ),
        ),
        _ScanZoneOverlay(screenSize: size, detection: detection),
        const Positioned(
          top: 0, left: 0, right: 0,
          child: _TopBar(),
        ),
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: _StatusPanel(detection: detection),
        ),
      ],
    );
  }
}

// ─── Scan zone ────────────────────────────────────────────────────────────────

class _ScanZoneOverlay extends StatelessWidget {
  final Size screenSize;
  final DetectionResult? detection;

  const _ScanZoneOverlay({
    required this.screenSize,
    required this.detection,
  });

  Color get _frameColor {
    if (detection == null) return const Color(0xFFD4E84A);
    if (detection!.isBanana) return const Color(0xFFFFD600);
    return const Color(0xFF888888);
  }

  @override
  Widget build(BuildContext context) {
    final rectW = screenSize.width * 0.82;
    final rectH = screenSize.height * 0.46;
    final rectLeft = (screenSize.width - rectW) / 2;
    final rectTop = (screenSize.height - rectH) / 2 - 30;

    return CustomPaint(
      painter: _OverlayPainter(
        scanRect: Rect.fromLTWH(rectLeft, rectTop, rectW, rectH),
        frameColor: _frameColor,
      ),
      size: screenSize,
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final Rect scanRect;
  final Color frameColor;

  _OverlayPainter({required this.scanRect, required this.frameColor});

  @override
  void paint(Canvas canvas, Size size) {
    final dimPaint = Paint()..color = Colors.black.withValues(alpha: .50);
    final cornerPaint = Paint()
      ..color = frameColor
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final borderPaint = Paint()
      ..color = frameColor.withValues(alpha: .3)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final holePath = Path()
      ..addRRect(RRect.fromRectAndRadius(scanRect, const Radius.circular(16)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, fullPath, holePath),
      dimPaint,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(scanRect, const Radius.circular(16)),
      borderPaint,
    );

    const cl = 28.0;
    final r = scanRect;
    canvas.drawLine(Offset(r.left, r.top + cl), Offset(r.left, r.top), cornerPaint);
    canvas.drawLine(Offset(r.left, r.top), Offset(r.left + cl, r.top), cornerPaint);
    canvas.drawLine(Offset(r.right - cl, r.top), Offset(r.right, r.top), cornerPaint);
    canvas.drawLine(Offset(r.right, r.top), Offset(r.right, r.top + cl), cornerPaint);
    canvas.drawLine(Offset(r.left, r.bottom - cl), Offset(r.left, r.bottom), cornerPaint);
    canvas.drawLine(Offset(r.left, r.bottom), Offset(r.left + cl, r.bottom), cornerPaint);
    canvas.drawLine(Offset(r.right - cl, r.bottom), Offset(r.right, r.bottom), cornerPaint);
    canvas.drawLine(Offset(r.right, r.bottom), Offset(r.right, r.bottom - cl), cornerPaint);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      old.frameColor != frameColor || old.scanRect != scanRect;
}

// ─── Top bar ──────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 20, right: 20, bottom: 12,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: .7), Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'GreenBanana',
            style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w800,
              color: Color(0xFFD4E84A), letterSpacing: 1.5,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFD4E84A).withValues(alpha: .4)),
            ),
            child: const Row(
              children: [
                Icon(Icons.fiber_manual_record, size: 8, color: Color(0xFFFF4444)),
                SizedBox(width: 5),
                Text('AI SCAN', style: TextStyle(
                  fontSize: 11, color: Color(0xFFD4E84A),
                  letterSpacing: 1.5, fontWeight: FontWeight.w600,
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Status panel ─────────────────────────────────────────────────────────────

class _StatusPanel extends StatelessWidget {
  final DetectionResult? detection;
  const _StatusPanel({required this.detection});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 24,
        top: 20, left: 20, right: 20,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.85), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 800),
            reverseDuration: const Duration(milliseconds: 1200),
            child: detection == null
                ? _buildScanning()
                : detection!.isBanana
                    ? _buildBananaFound(detection!)
                    : _buildNobanana(detection!),
          ),
          const SizedBox(height: 8),
          Text(
            'RICHT OP EEN BANAAN',
            style: TextStyle(
              fontSize: 10,
              color: const Color(0xFFD4E84A).withValues(alpha: .4),
              letterSpacing: 2.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanning() {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      key: ValueKey('scanning'),
      children: [
        SizedBox(
          width: 14, height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFFD4E84A),
          ),
        ),
        SizedBox(width: 10),
        Text(
          'Scannen…  Richt op een banaan',
          style: TextStyle(color: Color(0xFF888888), fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildBananaFound(DetectionResult d) {
    final pct = (d.confidence * 100).toStringAsFixed(0);
    return Column(
      key: const ValueKey('banana'),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('🍌', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Banaan herkend — $pct%',
                  style: const TextStyle(
                    color: Color(0xFFFFD600),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  d.label,
                  style: const TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          d.allLabels.take(3).join('  ·  '),
          style: const TextStyle(color: Color(0xFF555555), fontSize: 10),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildNobanana(DetectionResult d) {
    return Column(
      key: const ValueKey('nobanana'),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search, color: Color(0xFF555555), size: 18),
            const SizedBox(width: 8),
            Text(
              d.label,
              style: const TextStyle(color: Color(0xFF666666), fontSize: 14),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Geen banaan gevonden',
          style: TextStyle(color: Color(0xFF444444), fontSize: 11),
        ),
      ],
    );
  }
}

// ─── Hulpfuncties kleur ───────────────────────────────────────────────────────

String _colorLabel(BananaColor c) {
  switch (c) {
    case BananaColor.green:   return '🟢 Groen — nog niet rijp';
    case BananaColor.yellow:  return '🟡 Geel — rijp';
    case BananaColor.black:   return '⚫ Zwart — overrijp';
    case BananaColor.unknown: return '⬜ Kleur onbekend';
  }
}

Color _colorValue(BananaColor c) {
  switch (c) {
    case BananaColor.green:   return const Color(0xFF66BB6A);
    case BananaColor.yellow:  return const Color(0xFFFFD600);
    case BananaColor.black:   return const Color(0xFF888888);
    case BananaColor.unknown: return const Color(0xFF555555);
  }
}

// ─── Kleur resultaat card ────────────────────────────────────────────────────

/// Kleurverloop van de rijpheidsschaal: groen (1) -> geel (7) -> bruin (8).
const List<Color> _ripenessGradient = [
  Color(0xFF3F8F3A), // 1 - donkergroen
  Color(0xFF6BAF3C), // 2
  Color(0xFF9CC23F), // 3
  Color(0xFFC9D640), // 4
  Color(0xFFE9D93C), // 5
  Color(0xFFF5C518), // 6
  Color(0xFFE0A500), // 7 - vol geel
  Color(0xFF6B4423), // 8 - overrijp/bruin
];

Color _colorForStage(double stage) {
  final clamped = stage.clamp(1.0, 8.0);
  final idx = (clamped - 1).floor().clamp(0, _ripenessGradient.length - 2);
  final t = clamped - 1 - idx;
  return Color.lerp(_ripenessGradient[idx], _ripenessGradient[idx + 1], t)!;
}

String _stageDescription(double stage) {
  if (stage <= 1.4) return 'Groen — nog niet rijp, wacht een paar dagen';
  if (stage <= 2.4) return 'Groen-geel — bijna zo ver';
  if (stage <= 3.4) return 'Lichtgeel met groen — nog iets te vroeg';
  if (stage <= 4.4) return 'Overwegend geel — bijna perfect';
  if (stage <= 5.4) return 'Geel — mooi rijp';
  if (stage <= 6.6) return 'Volledig geel — optimaal rijp';
  if (stage <= 7.4) return 'Geel met bruine spikkels — heel rijp, lekker zoet';
  return 'Bruin/overrijp — perfect voor bananenbrood';
}

class _ColorResultCard extends StatelessWidget {
  final ColorAnalysisResult result;
  const _ColorResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final primary = result.primary;
    final stage = result.ripenessStage;
    final accentColor = primary == BananaColor.unknown
        ? _colorValue(primary)
        : _colorForStage(stage);

    if (primary == BananaColor.unknown) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accentColor.withValues(alpha: 0.6), width: 1.5),
        ),
        child: Text(
          _colorLabel(primary),
          style: TextStyle(color: accentColor, fontSize: 16, fontWeight: FontWeight.w600),
        ),
      );
    }

    final displayStage = stage.clamp(1.0, 8.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Stadium label
          Text(
            displayStage <= 7.0
                ? 'Rijpheid: stadium ${displayStage.toStringAsFixed(1)} / 7'
                : 'Overrijp',
            style: TextStyle(
              color: accentColor,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _stageDescription(displayStage),
            style: const TextStyle(
              color: Color(0xFFCCCCCC),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),

          // Gradient schaal met marker
          SizedBox(
            width: 220,
            height: 22,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Container(
                    height: 10,
                    margin: const EdgeInsets.only(top: 6),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(colors: _ripenessGradient),
                    ),
                  ),
                ),
                Positioned(
                  left: (displayStage - 1) / 7 * (220 - 14),
                  top: 0,
                  child: Container(
                    width: 14,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: accentColor, width: 2),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 3),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Loading & error views ────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  final String message;
  const _LoadingView({this.message = 'AI engine laden…'});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Color(0xFFD4E84A)),
          const SizedBox(height: 20),
          Text(message, style: const TextStyle(color: Color(0xFF888888))),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final bool showSettings;

  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.showSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                size: 56, color: Color(0xFF555555)),
            const SizedBox(height: 20),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF888888), height: 1.5)),
            const SizedBox(height: 28),
            OutlinedButton(
              onPressed: showSettings ? () => openAppSettings() : onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFD4E84A),
                side: const BorderSide(color: Color(0xFFD4E84A)),
              ),
              child: Text(showSettings ? 'Open instellingen' : 'Opnieuw proberen'),
            ),
          ],
        ),
      ),
    );
  }
}