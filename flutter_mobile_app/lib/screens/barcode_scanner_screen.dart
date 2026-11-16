import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:scoot_design/scoot_design.dart';
import '../widgets/app_icon_button.dart';

const String barcodeLibraryUrl = 'vendor/zxing-library-0.21.3.min.js';

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key, this.retailerName = ''});

  final String retailerName;

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController();
  bool _returnedFromBackground = false;
  late final AnimationController _animController;
  late final Animation<double> _scanAnim;
  bool _torchOn = false;
  bool _scanned = false;

  static const bool _timingLog = bool.fromEnvironment('SCAN_TIMING_LOG');
  final Stopwatch _timer = Stopwatch();
  int? _cameraRunningMs;
  int? _firstDetectMs;

  @override
  void initState() {
    super.initState();
    MobileScannerPlatform.instance.setBarcodeLibraryScriptUrl(
      barcodeLibraryUrl,
    );
    WidgetsBinding.instance.addObserver(this);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _controller.addListener(_syncScanAnimation);
    if (_timingLog) {
      _timer.start();
      _controller.addListener(_noteCameraRunning);
    }
    _scanAnim = Tween<double>(begin: 0.05, end: 0.95).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  void _syncScanAnimation() {
    if (_controller.value.error != null) {
      if (_animController.isAnimating) _animController.stop();
    } else if (!_animController.isAnimating) {
      _animController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_syncScanAnimation);
    if (_timingLog && !_scanned) _logTiming('closed_without_code');
    _animController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _returnedFromBackground = true;
      return;
    }
    if (state != AppLifecycleState.resumed || !_returnedFromBackground) return;
    _returnedFromBackground = false;
    if (_controller.value.error != null) {
      _controller.start();
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    _scanned = true;
    if (_timingLog) {
      _firstDetectMs = _timer.elapsedMilliseconds;
      _logTiming('code_read');
    }
    Navigator.of(context).pop(raw);
  }

  void _noteCameraRunning() {
    if (_cameraRunningMs == null && _controller.value.isRunning) {
      _cameraRunningMs = _timer.elapsedMilliseconds;
    }
  }

  void _logTiming(String outcome) {
    final int? ready = _cameraRunningMs;
    final int? detect = _firstDetectMs;
    final Map<String, Object?> line = <String, Object?>{
      'outcome': outcome,
      'camera_running_ms': ready,
      'first_detect_ms': detect,
      'detect_after_ready_ms': ready != null && detect != null
          ? detect - ready
          : null,
      'pop_ms': _timer.elapsedMilliseconds,
    };
    debugPrint('SCAN_TIMING ${jsonEncode(line)}');
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => BarcodeCameraErrorView(
              denied:
                  error.errorCode == MobileScannerErrorCode.permissionDenied,
              onOpenSettings: Geolocator.openAppSettings,
              onType: () => Navigator.of(context).pop(),
            ),
          ),
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, child) => state.error != null
                ? const SizedBox.shrink()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      _ScanOverlay(scanAnim: _scanAnim),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: BarcodeScanBottomPanel(
                          onType: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ],
                  ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: BarcodeScanTopBar(
              retailerName: widget.retailerName,
              torchOn: _torchOn,
              onClose: () => Navigator.of(context).pop(),
              onTorch: _toggleTorch,
            ),
          ),
        ],
      ),
    );
  }
}

class BarcodeScanTopBar extends StatelessWidget {
  const BarcodeScanTopBar({
    super.key,
    required this.retailerName,
    required this.torchOn,
    required this.onClose,
    required this.onTorch,
  });

  final String retailerName;
  final bool torchOn;
  final VoidCallback onClose;
  final VoidCallback onTorch;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.dark;
    final Color lightInk = torchOn ? Colors.black : Colors.white;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            AppIconButton(
              tooltip: 'Close',
              onPressed: onClose,
              icon: ScootIcons.close,
              color: Colors.white,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Scan product',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.phoneSubpageTitle.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  if (retailerName.isNotEmpty)
                    Text(
                      retailerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ScootType.small.copyWith(color: c.text2),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              toggled: torchOn,
              label: torchOn ? 'Turn light off' : 'Turn light on',
              excludeSemantics: true,
              child: Material(
                color: torchOn ? Colors.white : Colors.black54,
                borderRadius: ScootRadius.controlAll,
                child: InkWell(
                  borderRadius: ScootRadius.controlAll,
                  onTap: onTorch,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: kMinTapTarget,
                      minHeight: kMinTapTarget,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            torchOn ? Icons.flash_on : Icons.flash_off,
                            size: 20,
                            color: lightInk,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Light',
                            style: ScootType.smallStrong.copyWith(
                              color: lightInk,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BarcodeScanBottomPanel extends StatelessWidget {
  const BarcodeScanBottomPanel({super.key, required this.onType});

  final VoidCallback onType;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.dark;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(ScootSpace.phoneGutter),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(ScootRadius.card),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Hold the barcode inside the frame',
              textAlign: TextAlign.center,
              style: ScootType.bodyStrong.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(
              'No product scanned yet. Works with the saved catalogue offline.',
              textAlign: TextAlign.center,
              style: ScootType.small.copyWith(color: c.text2),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
                minimumSize: const Size.fromHeight(ScootSize.primaryButton),
              ),
              onPressed: onType,
              child: const Text('Type the barcode'),
            ),
          ],
        ),
      ),
    );
  }
}

class BarcodeCameraErrorView extends StatelessWidget {
  const BarcodeCameraErrorView({
    super.key,
    required this.denied,
    required this.onOpenSettings,
    required this.onType,
  });

  final bool denied;
  final VoidCallback onOpenSettings;
  final VoidCallback onType;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.dark;
    const Size tall = Size.fromHeight(ScootSize.primaryButton);
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.no_photography_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  denied ? 'Camera is off' : 'Camera is not available',
                  textAlign: TextAlign.center,
                  style: ScootType.h2.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  denied
                      ? 'Allow camera access for this app to scan barcodes, or type the code.'
                      : 'This device cannot scan barcodes now. Type the code instead.',
                  textAlign: TextAlign.center,
                  style: ScootType.body.copyWith(color: c.text2),
                ),
                const SizedBox(height: 24),
                if (denied) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: tall),
                      onPressed: onOpenSettings,
                      child: const Text('Open Settings'),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      minimumSize: tall,
                    ),
                    onPressed: onType,
                    child: const Text('Type the code'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanOverlay extends StatelessWidget {
  final Animation<double> scanAnim;
  const _ScanOverlay({required this.scanAnim});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final cutW = size.width * 0.75;
    final cutH = cutW * 0.46;
    final cutRect = Rect.fromLTWH(
      (size.width - cutW) / 2,
      (size.height - cutH) / 2,
      cutW,
      cutH,
    );
    return AnimatedBuilder(
      animation: scanAnim,
      builder: (context, _) => CustomPaint(
        size: size,
        painter: _OverlayPainter(cutRect: cutRect, scanPos: scanAnim.value),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final Rect cutRect;
  final double scanPos;
  const _OverlayPainter({required this.cutRect, required this.scanPos});

  static const _green = Color(0xFF00A651);
  static const _cornerLen = 22.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRRect(RRect.fromRectAndRadius(cutRect, const Radius.circular(10)))
        ..fillType = PathFillType.evenOdd,
      Paint()..color = Colors.black54,
    );

    final corner = Paint()
      ..color = _green
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    _corner(canvas, corner, cutRect.topLeft, 1, 1);
    _corner(canvas, corner, cutRect.topRight, -1, 1);
    _corner(canvas, corner, cutRect.bottomLeft, 1, -1);
    _corner(canvas, corner, cutRect.bottomRight, -1, -1);

    final lineY = cutRect.top + cutRect.height * scanPos;
    canvas.drawLine(
      Offset(cutRect.left + 6, lineY),
      Offset(cutRect.right - 6, lineY),
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            _green.withAlpha(230),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(cutRect.left, lineY, cutRect.width, 1))
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  void _corner(Canvas c, Paint p, Offset o, double dx, double dy) {
    c.drawLine(o, o.translate(_cornerLen * dx, 0), p);
    c.drawLine(o, o.translate(0, _cornerLen * dy), p);
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => old.scanPos != scanPos;
}
