import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'banana_detector.dart';
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
  BananaColor? _photoColor;

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
    });
    await _controller!.startImageStream(_onCameraImage);
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
        color: _photoColor ?? BananaColor.unknown,
        onReset: _resetScan,
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
  final BananaColor color;
  final VoidCallback onReset;

  const _PhotoResultView({
    required this.photoPath,
    required this.detection,
    required this.color,
    required this.onReset,
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
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _colorValue(color).withValues(alpha: 0.6),
                      width: 1.5,
                    ),
                  ),
                  child: Text(
                    _colorLabel(color),
                    style: TextStyle(
                      color: _colorValue(color),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
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