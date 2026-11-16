const bool kMobileVoiceCommandsEnabled = bool.fromEnvironment(
  'FYP_A_MOBILE_VOICE',
  defaultValue: true,
);

const bool kMobileVoiceEvaluationEnabled = bool.fromEnvironment(
  'FYP_A_VOICE_EVAL',
  defaultValue: false,
);
