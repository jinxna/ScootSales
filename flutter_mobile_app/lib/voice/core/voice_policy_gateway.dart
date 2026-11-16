import 'action_registry.dart';
import 'voice_binding.dart';
import 'voice_types.dart';

class VoicePolicyDecision {
  const VoicePolicyDecision({
    required this.kind,
    this.failure,
    this.definition,
  });

  final VoiceDecisionKind kind;
  final VoicePolicyFailure? failure;
  final VoiceActionDefinition? definition;

  bool get isAllowed => kind == VoiceDecisionKind.allowed;

  bool get needsConfirmation => kind == VoiceDecisionKind.needsConfirmation;
}

class VoicePolicyGateway {
  VoicePolicyGateway({required this.registry, required this.binding});

  final VoiceActionRegistry registry;
  final VoiceScreenBinding binding;

  VoicePolicyDecision evaluate({
    required VoiceCommandEnvelope envelope,
    required int currentTick,
    required bool isOnline,
    bool featureEnabled = true,
    bool confirmationProvided = false,
  }) {
    final VoiceInterpretation interpretation = envelope.interpretation;
    final VoiceActionDefinition? definition = registry.definitionFor(
      interpretation.action,
    );
    if (definition == null) {
      return _rejected(VoicePolicyFailure.unknownAction);
    }

    if (interpretation.schemaVersion != definition.schemaVersion) {
      return _rejected(
        VoicePolicyFailure.unsupportedSchema,
        definition: definition,
      );
    }

    if (envelope.isExpired(currentTick)) {
      return _rejected(VoicePolicyFailure.expired, definition: definition);
    }

    if (!binding.isActive) {
      return _rejected(
        VoicePolicyFailure.inactiveBinding,
        definition: definition,
      );
    }

    if (envelope.context.binding != binding.identity) {
      return _rejected(VoicePolicyFailure.staleBinding, definition: definition);
    }

    if (!binding.matches(envelope.context)) {
      return _rejected(VoicePolicyFailure.staleContext, definition: definition);
    }

    if (definition.risk == VoiceRisk.red ||
        definition.risk == VoiceRisk.blocked) {
      return _rejected(VoicePolicyFailure.riskDenied, definition: definition);
    }

    if (definition.requiresAuthenticatedUser &&
        envelope.context.uid.trim().isEmpty) {
      return _rejected(
        VoicePolicyFailure.unauthenticated,
        definition: definition,
      );
    }

    if (!definition.allowsRole(envelope.context.role)) {
      return _rejected(
        VoicePolicyFailure.roleNotAllowed,
        definition: definition,
      );
    }

    if (!definition.allowsSurface(envelope.context.surfaceId)) {
      return _rejected(
        VoicePolicyFailure.surfaceNotAllowed,
        definition: definition,
      );
    }

    final VoicePolicyFailure? parameterFailure = definition.validateParameters(
      interpretation.parameters,
    );
    if (parameterFailure != null) {
      return _rejected(parameterFailure, definition: definition);
    }

    if (!featureEnabled) {
      return _rejected(
        VoicePolicyFailure.featureDisabled,
        definition: definition,
      );
    }

    if (!definition.enabled) {
      return _rejected(
        VoicePolicyFailure.prerequisiteMissing,
        definition: definition,
      );
    }

    if (!isOnline && !definition.allowOffline) {
      return _rejected(
        VoicePolicyFailure.unavailableOffline,
        definition: definition,
      );
    }

    if (definition.requiresConfirmation && !confirmationProvided) {
      return VoicePolicyDecision(
        kind: VoiceDecisionKind.needsConfirmation,
        definition: definition,
      );
    }

    return VoicePolicyDecision(
      kind: VoiceDecisionKind.allowed,
      definition: definition,
    );
  }

  VoicePolicyDecision _rejected(
    VoicePolicyFailure failure, {
    VoiceActionDefinition? definition,
  }) {
    return VoicePolicyDecision(
      kind: VoiceDecisionKind.rejected,
      failure: failure,
      definition: definition,
    );
  }
}
