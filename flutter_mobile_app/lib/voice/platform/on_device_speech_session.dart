import 'dart:async';

import 'package:flutter/services.dart';

import '../ui/mobile_voice_speech_session.dart';

class OnDeviceVoiceSpeechSession implements MobileVoiceSpeechAdapter {
  OnDeviceVoiceSpeechSession({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? _defaultMethods,
      _events = events ?? _defaultEvents;

  static const MethodChannel _defaultMethods = MethodChannel(
    'fyp_a/voice/on_device',
  );
  static const EventChannel _defaultEvents = EventChannel(
    'fyp_a/voice/on_device/events',
  );

  static const Duration _idleTimeout = Duration(seconds: 10);
  static const Duration _maxCapture = Duration(seconds: 20);
  static const Duration _startTimeout = Duration(seconds: 45);

  final MethodChannel _methods;
  final EventChannel _events;
  StreamSubscription<dynamic>? _eventSubscription;
  Timer? _captureTimeout;
  Completer<void>? _terminalStatus;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;

  @override
  Future<bool> start({
    required MobileVoiceTextCallback onPartial,
    required MobileVoiceTextCallback onFinal,
    required MobileVoiceTextCallback onError,
    required MobileVoiceStoppedCallback onStopped,
    MobileVoiceStoppedCallback? onReady,
  }) async {
    if (_disposed) return false;
    final bool hadActiveCapture = _started;
    final int captureGeneration = ++_generation;
    final StreamSubscription<dynamic>? previousSubscription =
        _eventSubscription;
    _eventSubscription = null;
    _captureTimeout?.cancel();
    _captureTimeout = null;
    _completeTerminalStatus();
    _started = false;
    try {
      await previousSubscription?.cancel();
      if (captureGeneration != _generation || _disposed) return false;
      if (hadActiveCapture) {
        await _methods.invokeMethod<void>('cancel');
        if (captureGeneration != _generation || _disposed) return false;
      }
    } on PlatformException catch (error) {
      if (captureGeneration == _generation) {
        onError(error.message ?? error.code);
      }
      return false;
    } catch (error) {
      if (captureGeneration == _generation) onError(error.toString());
      return false;
    }

    bool finalDelivered = false;
    bool stoppedDelivered = false;
    final Completer<void> terminalStatus = Completer<void>();

    void finishCapture(MobileVoiceStoppedCallback callback) {
      if (stoppedDelivered) return;
      stoppedDelivered = true;
      if (!terminalStatus.isCompleted) terminalStatus.complete();
      if (captureGeneration != _generation) return;
      _started = false;
      _captureTimeout?.cancel();
      _captureTimeout = null;
      if (identical(_terminalStatus, terminalStatus)) {
        _terminalStatus = null;
      }
      callback();
    }

    DateTime hardLimit = DateTime.now().add(_maxCapture);
    void armCaptureTimeout() {
      if (!_started || captureGeneration != _generation || stoppedDelivered) {
        return;
      }
      final Duration left = hardLimit.difference(DateTime.now());
      final Duration wait = left < _idleTimeout ? left : _idleTimeout;
      _captureTimeout?.cancel();
      _captureTimeout = Timer(wait, () {
        if (captureGeneration != _generation || !_started) return;
        onError('Listening timed out. Please try again.');
        finishCapture(onStopped);
        unawaited(cancel());
      });
    }

    StreamSubscription<dynamic>? captureSubscription;
    try {
      final bool available =
          await _methods.invokeMethod<bool>('isAvailable') ?? false;
      if (captureGeneration != _generation || _disposed || !available) {
        if (!terminalStatus.isCompleted) terminalStatus.complete();
        return false;
      }

      captureSubscription = _events.receiveBroadcastStream().listen(
        (dynamic event) {
          if (captureGeneration != _generation ||
              stoppedDelivered ||
              event is! Map) {
            return;
          }
          final String type = event['type']?.toString() ?? '';
          final String text = event['text']?.toString().trim() ?? '';
          switch (type) {
            case 'partial':
              if (text.isNotEmpty) {
                onPartial(text);
                armCaptureTimeout();
              }
            case 'final':
              if (text.isNotEmpty && !finalDelivered) {
                finalDelivered = true;
                _captureTimeout?.cancel();
                _captureTimeout = null;
                onFinal(text);
                finishCapture(onStopped);
              }
            case 'error':
              _captureTimeout?.cancel();
              _captureTimeout = null;
              onError(
                event['message']?.toString() ?? 'Speech recognition error.',
              );
              finishCapture(onStopped);
            case 'ready':
              armCaptureTimeout();
              onReady?.call();
            case 'stopped':
              finishCapture(onStopped);
          }
        },
        onError: (Object error) {
          if (captureGeneration != _generation || stoppedDelivered) return;
          onError(error.toString());
          finishCapture(onStopped);
        },
        onDone: () {
          if (captureGeneration == _generation) finishCapture(onStopped);
        },
      );
      _eventSubscription = captureSubscription;
      _terminalStatus = terminalStatus;

      final bool started =
          await _methods
              .invokeMethod<bool>('start')
              .timeout(
                _startTimeout,
                onTimeout: () {
                  unawaited(_methods.invokeMethod<void>('cancel'));
                  return false;
                },
              ) ??
          false;
      if (captureGeneration != _generation || _disposed) {
        if (identical(_eventSubscription, captureSubscription)) {
          _eventSubscription = null;
        }
        await captureSubscription.cancel();
        if (!terminalStatus.isCompleted) terminalStatus.complete();
        if (identical(_terminalStatus, terminalStatus)) {
          _terminalStatus = null;
        }
        return false;
      }
      if (!started) {
        try {
          await terminalStatus.future.timeout(
            const Duration(milliseconds: 100),
          );
        // ignore: empty_catches
        } on TimeoutException {
        }
        if (identical(_eventSubscription, captureSubscription)) {
          _eventSubscription = null;
        }
        await captureSubscription.cancel();
        if (!terminalStatus.isCompleted) terminalStatus.complete();
        if (identical(_terminalStatus, terminalStatus)) {
          _terminalStatus = null;
        }
        return false;
      }
      hardLimit = DateTime.now().add(_maxCapture);
      _started = !stoppedDelivered;
      if (!_started) return true;
      armCaptureTimeout();
      return true;
    } on PlatformException catch (error) {
      if (captureGeneration == _generation) {
        onError(error.message ?? error.code);
      }
      if (identical(_eventSubscription, captureSubscription)) {
        _eventSubscription = null;
      }
      await captureSubscription?.cancel();
      if (!terminalStatus.isCompleted) terminalStatus.complete();
      if (identical(_terminalStatus, terminalStatus)) {
        _terminalStatus = null;
      }
      return false;
    } catch (error) {
      if (captureGeneration == _generation) onError(error.toString());
      if (identical(_eventSubscription, captureSubscription)) {
        _eventSubscription = null;
      }
      await captureSubscription?.cancel();
      if (!terminalStatus.isCompleted) terminalStatus.complete();
      if (identical(_terminalStatus, terminalStatus)) {
        _terminalStatus = null;
      }
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    final int captureGeneration = _generation;
    final Completer<void>? terminalStatus = _terminalStatus;
    try {
      await _methods.invokeMethod<void>('stop');
      if (captureGeneration != _generation || terminalStatus == null) return;
      await terminalStatus.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      if (captureGeneration == _generation) await cancel();
    } catch (_) {
      if (captureGeneration == _generation) await cancel();
      rethrow;
    }
  }

  @override
  Future<void> cancel() async {
    ++_generation;
    _started = false;
    _captureTimeout?.cancel();
    _captureTimeout = null;
    _completeTerminalStatus();
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    try {
      await _methods.invokeMethod<void>('cancel');
    // ignore: empty_catches
    } on MissingPluginException {
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    _started = false;
    _captureTimeout?.cancel();
    _captureTimeout = null;
    _completeTerminalStatus();
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    try {
      await _methods.invokeMethod<void>('dispose');
    // ignore: empty_catches
    } on MissingPluginException {
    }
  }

  void _completeTerminalStatus() {
    final Completer<void>? terminalStatus = _terminalStatus;
    _terminalStatus = null;
    if (terminalStatus != null && !terminalStatus.isCompleted) {
      terminalStatus.complete();
    }
  }
}
