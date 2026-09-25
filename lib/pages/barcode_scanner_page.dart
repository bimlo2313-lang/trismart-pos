import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeScannerPage extends StatefulWidget {
  const BarcodeScannerPage({
    super.key,
    required this.onScan,
    required this.cartSummary,
  });

  final Future<({bool added, String message})> Function(String code) onScan;
  final String Function() cartSummary;

  @override
  State<BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends State<BarcodeScannerPage>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.unrestricted,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.code93,
      BarcodeFormat.codabar,
      BarcodeFormat.itf14,
    ],
  );
  Future<void> _cameraOperations = Future<void>.value();
  bool _closing = false;
  bool _canPop = false;
  bool _foreground = true;
  String? _error;
  final _clock = Stopwatch()..start();
  final _lastScanned = <String, int>{};
  Future<void> _scanOperations = Future<void>.value();
  String? _feedback;
  Timer? _feedbackTimer;
  late final Future<AudioPool?> _successAudio;
  late final Future<AudioPool?> _errorAudio;
  Future<void> _audioOperations = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _successAudio = _preloadAudio('audio/scan_success.wav');
    _errorAudio = _preloadAudio('audio/scan_error.wav');
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncCamera();
    });
  }

  Future<AudioPool?> _preloadAudio(String path) async {
    try {
      return await AudioPool.create(
        source: AssetSource(path),
        minPlayers: 2,
        maxPlayers: 4,
        audioContext: AudioContext(
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
    } catch (error) {
      debugPrint('Audio scanner tidak tersedia: $error');
      return null;
    }
  }

  void _playFeedback(bool added) {
    // Menunggu persiapan/start saja, bukan durasi suara; tidak memblokir lookup.
    _audioOperations = _audioOperations.then((_) async {
      try {
        final pool = await (added ? _successAudio : _errorAudio);
        if (!mounted || _closing || !_foreground) return;
        await pool?.start();
      } catch (error) {
        debugPrint('Gagal memutar audio scanner: $error');
      }
    });
    unawaited(_hapticFeedback(added));
  }

  Future<void> _hapticFeedback(bool added) async {
    try {
      if (!mounted || _closing || !_foreground) return;
      await HapticFeedback.lightImpact();
      if (!added) {
        await Future<void>.delayed(const Duration(milliseconds: 90));
        if (mounted && !_closing && _foreground) {
          await HapticFeedback.mediumImpact();
        }
      }
    } catch (_) {
      // Haptic tidak tersedia di semua perangkat/platform.
    }
  }

  Future<void> _disposeAudio() async {
    await _audioOperations;
    for (final pendingPool in [_successAudio, _errorAudio]) {
      try {
        await (await pendingPool)?.dispose();
      } catch (error) {
        debugPrint('Gagal melepas audio scanner: $error');
      }
    }
  }

  // Serialisasi start/stop juga menangani perubahan lifecycle saat izin muncul.
  Future<void> _syncCamera() {
    _cameraOperations = _cameraOperations.then((_) async {
      try {
        if (!mounted || _closing || !_foreground) {
          await _controller.stop();
          return;
        }
        if (_error != null ||
            _controller.value.error != null ||
            _controller.value.isRunning) {
          return;
        }
        await _controller.start();
        if (!mounted || _closing || !_foreground) await _controller.stop();
      } catch (_) {
        if (mounted && !_closing) {
          setState(
            () => _error = 'Kamera tidak tersedia. Gunakan input manual.',
          );
        }
      }
    });
    return _cameraOperations;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_closing) unawaited(_syncCamera());
  }

  void _onDetect(BarcodeCapture capture) {
    if (_closing || !_foreground) return;
    final now = _clock.elapsedMilliseconds;
    _lastScanned.removeWhere((_, time) => now - time >= 1500);
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue?.trim();
      if (code == null || code.isEmpty || _lastScanned.containsKey(code)) {
        continue;
      }
      _lastScanned[code] = now;
      _scanOperations = _scanOperations.then((_) async {
        if (!mounted) return;
        String message;
        try {
          final result = await widget.onScan(code);
          message = result.message;
          if (mounted && !_closing && _foreground) {
            _playFeedback(result.added);
          }
        } catch (_) {
          message = 'Gagal mencari barang. Silakan scan ulang.';
        }
        if (!mounted) return;
        _feedbackTimer?.cancel();
        setState(() => _feedback = message);
        _feedbackTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _feedback = null);
        });
      });
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true; // Kunci sebelum await agar hasil tidak masuk dua kali.
    await _syncCamera();
    await _scanOperations;
    if (!mounted) return;
    setState(() => _canPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closing = true;
    _feedbackTimer?.cancel();
    _clock.stop();
    unawaited(_disposeAudio());
    unawaited(_cameraOperations.then((_) => _controller.dispose()));
    super.dispose();
  }

  Widget _cameraError(MobileScannerException error) {
    final message = error.errorCode == MobileScannerErrorCode.permissionDenied
        ? 'Izin kamera ditolak. Anda tetap bisa memakai input manual. '
              'Untuk scan kamera, izinkan Kamera melalui Pengaturan aplikasi.'
        : 'Kamera tidak tersedia. Anda tetap bisa memakai input manual.';
    return _errorPanel(message);
  }

  Widget _errorPanel(String message) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _close(),
              child: const Text('Kembali ke input manual'),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _canPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_close());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Scan Barcode'),
        actions: [TextButton(onPressed: _close, child: const Text('Selesai'))],
        leading: IconButton(
          tooltip: 'Kembali',
          onPressed: () => _close(),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Arahkan kamera ke satu barcode barang.'),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (_, error) => _cameraError(error),
                ),
                if (_error != null) _errorPanel(_error!),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    _feedback ?? 'Siap scan berikutnya',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(widget.cartSummary(), textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
