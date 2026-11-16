import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

typedef DashboardVoiceTextCallback = void Function(String text);
typedef DashboardVoiceStoppedCallback = void Function();

class DashboardVoiceSpeechSession {
  DashboardVoiceSpeechSession({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  int _generation = 0;
  bool _initialised = false;
  bool _available = false;
  bool _starting = false;
  DashboardVoiceStoppedCallback? _activeOnStopped;
  DashboardVoiceTextCallback? _activeOnError;
  bool _disposed = false;
  Completer<void>? _terminalStatus;

  bool get isListening => _speech.isListening;
  bool get isAvailable => _available;

  Future<bool> start({
    required DashboardVoiceTextCallback onPartial,
    required DashboardVoiceTextCallback onFinal,
    required DashboardVoiceTextCallback onError,
    required DashboardVoiceStoppedCallback onStopped,
    String? localeId,
  }) async {
    if (_disposed) return false;
    final int captureGeneration = ++_generation;
    _starting = true;
    _activeOnError = onError;

    final Completer<void>? previousTerminal = _terminalStatus;
    try {
      if (previousTerminal != null) {
        await previousTerminal.future.timeout(const Duration(seconds: 3));
      }
      if (captureGeneration != _generation) return false;

      final bool ready = await _ensureInitialised();
      if (!ready || captureGeneration != _generation) return false;

      _bindListeners();
      bool finalDelivered = false;
      _activeOnStopped = () {
        if (captureGeneration != _generation) return;
        _activeOnStopped = null;
        onStopped();
      };
      _starting = false;

      try {
        await _speech.listen(
          onResult: (SpeechRecognitionResult result) {
            if (captureGeneration != _generation) return;
            final String text = result.recognizedWords.trim();
            if (text.isEmpty) return;
            if (result.finalResult) {
              if (finalDelivered) return;
              finalDelivered = true;
              onFinal(text);
            } else {
              onPartial(text);
            }
          },
          listenOptions: SpeechListenOptions(
            localeId: localeId,
            listenFor: Duration(seconds: 10),
            pauseFor: Duration(seconds: 2),
            partialResults: true,
            cancelOnError: true,
            onDevice: false,
            autoPunctuation: false,
            enableHapticFeedback: false,
            listenMode: ListenMode.confirmation,
          ),
        );
        return true;
      } catch (error) {
        if (captureGeneration == _generation) {
          _activeOnStopped = null;
          _activeOnError = null;
          onError(error.toString());
        }
        return false;
      }
    } on TimeoutException {
      if (captureGeneration == _generation) {
        ++_generation;
        _activeOnStopped = null;
        _activeOnError = null;
        _completeTerminalStatus();
        onError('Speech provider did not finish the previous capture.');
      }
      return false;
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    if (_starting) {
      ++_generation;
      _starting = false;
      _activeOnStopped = null;
      _completeTerminalStatus();
      return;
    }
    if (!_initialised || !_available) return;
    final Completer<void> terminal = _terminalStatus ??= Completer<void>();
    try {
      await _speech.stop();
      await terminal.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      return;
    } catch (_) {
      ++_generation;
      _activeOnStopped = null;
      if (!terminal.isCompleted) terminal.complete();
      rethrow;
    }
  }

  Future<void> cancel() async {
    ++_generation;
    _activeOnStopped = null;
    _completeTerminalStatus();
    await _speech.cancel();
  }

  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    _activeOnStopped = null;
    _activeOnError = null;
    if (_speech.errorListener == _handleError) {
      _speech.errorListener = null;
    }
    if (_speech.statusListener == _handleStatus) {
      _speech.statusListener = null;
    }
    _completeTerminalStatus();
    await _speech.cancel();
  }

  void _bindListeners() {
    _speech.errorListener = _handleError;
    _speech.statusListener = _handleStatus;
  }

  void _handleError(SpeechRecognitionError error) {
    if (_disposed) return;
    _activeOnError?.call(error.errorMsg);
  }

  void _handleStatus(String status) {
    if (_disposed) return;
    if (status == 'notListening' || status == 'done') {
      _completeTerminalStatus();
      _activeOnStopped?.call();
    }
  }

  Future<bool> _ensureInitialised() async {
    if (_initialised) return _available;
    _initialised = true;
    try {
      _available = await _speech.initialize(
        onError: _handleError,
        onStatus: _handleStatus,
      );
    } catch (error) {
      _available = false;
      _activeOnError?.call(error.toString());
    }
    return _available;
  }

  void _completeTerminalStatus() {
    final Completer<void>? terminal = _terminalStatus;
    if (terminal == null) return;
    if (!terminal.isCompleted) terminal.complete();
    _terminalStatus = null;
  }
}
