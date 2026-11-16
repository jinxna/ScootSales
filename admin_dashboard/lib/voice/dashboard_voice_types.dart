enum DashboardVoiceActionId { openPage }

extension DashboardVoiceActionCode on DashboardVoiceActionId {
  String get code => switch (this) {
    DashboardVoiceActionId.openPage => 'open_page',
  };
}

enum DashboardVoiceAbstentionReason {
  emptyTranscript,
  unsupportedCommand,
  compoundCommand,
  ambiguousPage,
}

enum DashboardVoicePolicyFailure {
  featureDisabled,
  unauthenticated,
  inactiveAccount,
  roleNotAllowed,
  unknownAction,
  pageNotAllowed,
}

enum DashboardVoiceResultCode {
  opened,
  rejected,
  duplicate,
  abstained,
  executionFailed,
}

class DashboardVoicePage {
  const DashboardVoicePage({
    required this.key,
    required this.label,
    this.description = '',
    this.aliases = const <String>{},
  });

  final String key;
  final String label;
  final String description;
  final Set<String> aliases;

  String get searchText =>
      <String>{key, label, description, ...aliases}.join(' ').toLowerCase();
}

class DashboardVoiceInterpretation {
  DashboardVoiceInterpretation({
    required this.action,
    required this.pageKey,
    required this.normalizedTranscript,
  });

  final DashboardVoiceActionId action;
  final String pageKey;
  final String normalizedTranscript;
}

class DashboardVoiceAbstention {
  const DashboardVoiceAbstention({
    required this.reason,
    required this.normalizedTranscript,
    this.suggestedPageKeys = const <String>[],
  });

  final DashboardVoiceAbstentionReason reason;
  final String normalizedTranscript;

  final List<String> suggestedPageKeys;
}

class DashboardVoiceInterpretationResult {
  const DashboardVoiceInterpretationResult.recognized(this.interpretation)
    : abstention = null;

  const DashboardVoiceInterpretationResult.abstained(this.abstention)
    : interpretation = null;

  final DashboardVoiceInterpretation? interpretation;
  final DashboardVoiceAbstention? abstention;

  bool get isRecognized => interpretation != null;
}

class DashboardVoicePolicyDecision {
  const DashboardVoicePolicyDecision.allowed(this.page) : failure = null;

  const DashboardVoicePolicyDecision.rejected(this.failure) : page = null;

  final DashboardVoicePage? page;
  final DashboardVoicePolicyFailure? failure;

  bool get isAllowed => page != null && failure == null;
}

class DashboardVoiceEngineOutcome {
  const DashboardVoiceEngineOutcome({
    required this.code,
    this.interpretation,
    this.abstention,
    this.failure,
    this.page,
    this.viaLocalModel = false,
  });

  DashboardVoiceEngineOutcome.abstained(
    DashboardVoiceInterpretationResult result,
  ) : this(
        code: DashboardVoiceResultCode.abstained,
        interpretation: result.interpretation,
        abstention: result.abstention,
      );

  DashboardVoiceEngineOutcome.rejected(
    DashboardVoiceInterpretation interpretation,
    DashboardVoicePolicyFailure failure,
  ) : this(
        code: DashboardVoiceResultCode.rejected,
        interpretation: interpretation,
        failure: failure,
      );

  DashboardVoiceEngineOutcome.opened(
    DashboardVoiceInterpretation interpretation,
    DashboardVoicePage page,
  ) : this(
        code: DashboardVoiceResultCode.opened,
        interpretation: interpretation,
        page: page,
      );

  const DashboardVoiceEngineOutcome.duplicate()
    : this(code: DashboardVoiceResultCode.duplicate);

  DashboardVoiceEngineOutcome.executionFailed(
    DashboardVoiceInterpretation interpretation,
    DashboardVoicePage page,
  ) : this(
        code: DashboardVoiceResultCode.executionFailed,
        interpretation: interpretation,
        page: page,
      );

  final DashboardVoiceResultCode code;
  final DashboardVoiceInterpretation? interpretation;
  final DashboardVoiceAbstention? abstention;
  final DashboardVoicePolicyFailure? failure;
  final DashboardVoicePage? page;

  List<String> get suggestedPageKeys =>
      abstention?.suggestedPageKeys ?? const <String>[];

  final bool viaLocalModel;

  DashboardVoiceEngineOutcome withLocalModel(bool value) => value
      ? DashboardVoiceEngineOutcome(
          code: code,
          interpretation: interpretation,
          abstention: abstention,
          failure: failure,
          page: page,
          viaLocalModel: true,
        )
      : this;
}
