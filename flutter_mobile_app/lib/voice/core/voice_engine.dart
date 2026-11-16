import 'deterministic_command_parser.dart';
import 'voice_binding.dart';
import 'voice_dispatcher.dart';
import 'voice_types.dart';

typedef VoiceTickProvider = int Function();

class VoiceEngineOutcome {
  const VoiceEngineOutcome({
    required this.interpretation,
    this.actionResult,
    this.confirmationHandle,
  });

  final VoiceInterpretationResult interpretation;
  final VoiceActionResult? actionResult;
  final VoiceConfirmationHandle? confirmationHandle;

  bool get wasProcessed => actionResult != null;
}

class VoiceCommandEngine {
  VoiceCommandEngine({
    required this.sessionId,
    required this.binding,
    required this.dispatcher,
    VoiceTickProvider? tickProvider,
    this.parser = const DeterministicCommandParser(),
    this.expiryTicks = 30000,
  }) : tickProvider = tickProvider ?? _newMonotonicTickProvider();

  final String sessionId;
  final VoiceScreenBinding binding;
  final VoiceActionDispatcher dispatcher;
  final VoiceTickProvider tickProvider;
  final DeterministicCommandParser parser;
  final int expiryTicks;
  final Set<String> _seenCaptureIds = <String>{};

  VoiceInterpretationResult interpret(String finalTranscript) {
    return parser.parse(finalTranscript);
  }

  Future<VoiceEngineOutcome> submitFinalTranscript(
    String finalTranscript, {
    required String captureId,
    bool isOnline = true,
    bool featureEnabled = true,
  }) async {
    final String normalizedCaptureId = captureId.trim();
    if (normalizedCaptureId.isEmpty) {
      throw ArgumentError.value(captureId, 'captureId', 'must not be empty');
    }
    final bool isFirstFinalForCapture = _seenCaptureIds.add(
      normalizedCaptureId,
    );
    final VoiceInterpretationResult interpretation = interpret(finalTranscript);
    if (!isFirstFinalForCapture) {
      return VoiceEngineOutcome(
        interpretation: interpretation,
        actionResult: const VoiceActionResult.duplicate(),
      );
    }
    final VoiceInterpretation? recognized = interpretation.interpretation;
    if (recognized == null) {
      return VoiceEngineOutcome(interpretation: interpretation);
    }

    final int createdTick = tickProvider();
    final VoiceCommandEnvelope envelope = VoiceCommandEnvelope(
      sessionId: sessionId,
      commandId: '$sessionId:capture:$normalizedCaptureId',
      interpretation: recognized,
      context: binding.snapshot(),
      createdTick: createdTick,
      expiresAtTick: createdTick + expiryTicks,
    );
    final VoiceActionResult actionResult = await dispatcher.dispatch(
      envelope,
      currentTick: tickProvider(),
      isOnline: isOnline,
      featureEnabled: featureEnabled,
    );
    final VoiceConfirmationHandle? confirmationHandle =
        actionResult.code == VoiceResultCode.needsConfirmation
        ? dispatcher.confirmationHandleFor(envelope)
        : null;
    return VoiceEngineOutcome(
      interpretation: interpretation,
      actionResult: actionResult,
      confirmationHandle: confirmationHandle,
    );
  }

  Future<VoiceActionResult> confirm(
    VoiceConfirmationHandle handle, {
    bool isOnline = true,
    bool featureEnabled = true,
  }) {
    return dispatcher.confirm(
      handle,
      currentTick: tickProvider(),
      isOnline: isOnline,
      featureEnabled: featureEnabled,
    );
  }

  VoiceActionResult cancel(VoiceConfirmationHandle handle) {
    return dispatcher.cancel(handle, currentTick: tickProvider());
  }

  static VoiceTickProvider _newMonotonicTickProvider() {
    final Stopwatch stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMilliseconds;
  }
}
