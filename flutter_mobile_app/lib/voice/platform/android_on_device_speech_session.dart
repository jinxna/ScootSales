import '../ui/mobile_voice_speech_session.dart';
import 'on_device_speech_session.dart';

class AndroidOnDeviceVoiceSpeechSession extends OnDeviceVoiceSpeechSession {
  AndroidOnDeviceVoiceSpeechSession({super.methods, super.events});
}

class UnavailableMobileVoiceSpeechAdapter implements MobileVoiceSpeechAdapter {
  const UnavailableMobileVoiceSpeechAdapter();

  @override
  Future<bool> start({
    required MobileVoiceTextCallback onPartial,
    required MobileVoiceTextCallback onFinal,
    required MobileVoiceTextCallback onError,
    required MobileVoiceStoppedCallback onStopped,
    MobileVoiceStoppedCallback? onReady,
  }) async => false;

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}
