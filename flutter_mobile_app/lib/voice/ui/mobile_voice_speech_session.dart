typedef MobileVoiceTextCallback = void Function(String text);
typedef MobileVoiceStoppedCallback = void Function();

abstract interface class MobileVoiceSpeechAdapter {
  Future<bool> start({
    required MobileVoiceTextCallback onPartial,
    required MobileVoiceTextCallback onFinal,
    required MobileVoiceTextCallback onError,
    required MobileVoiceStoppedCallback onStopped,
    MobileVoiceStoppedCallback? onReady,
  });

  Future<void> stop();

  Future<void> cancel();

  Future<void> dispose();
}

typedef MobileVoiceSpeechAdapterFactory = MobileVoiceSpeechAdapter Function();
