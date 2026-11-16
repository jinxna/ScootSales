enum VoiceActionId {
  openAssignedRoute,
  openCurrentVisit,
  openCart,
  openOrderHistory,
  searchProducts,
  clearProductSearch,
  showVisitBrief,
  setDraftOrderQuantity,
  submitOrder,
  completeVisit,
  changeRouteState,
  recordOutcome,
  changeLocationState,
  changePermissions,
}

extension VoiceActionIdCode on VoiceActionId {
  String get code => switch (this) {
    VoiceActionId.openAssignedRoute => 'open_assigned_route',
    VoiceActionId.openCurrentVisit => 'open_current_visit',
    VoiceActionId.openCart => 'open_cart',
    VoiceActionId.openOrderHistory => 'open_order_history',
    VoiceActionId.searchProducts => 'search_products',
    VoiceActionId.clearProductSearch => 'clear_product_search',
    VoiceActionId.showVisitBrief => 'show_visit_brief',
    VoiceActionId.setDraftOrderQuantity => 'set_draft_order_quantity',
    VoiceActionId.submitOrder => 'submit_order',
    VoiceActionId.completeVisit => 'complete_visit',
    VoiceActionId.changeRouteState => 'change_route_state',
    VoiceActionId.recordOutcome => 'record_outcome',
    VoiceActionId.changeLocationState => 'change_location_state',
    VoiceActionId.changePermissions => 'change_permissions',
  };
}

enum VoiceAbstentionReason {
  emptyTranscript,
  unsupportedCommand,
  compoundCommand,
  malformedParameters,
  ambiguousNumericPhrase,
}

enum VoicePolicyFailure {
  unknownAction,
  unsupportedSchema,
  invalidParameters,
  riskDenied,
  unauthenticated,
  roleNotAllowed,
  surfaceNotAllowed,
  featureDisabled,
  prerequisiteMissing,
  unavailableOffline,
  expired,
  staleBinding,
  staleContext,
  inactiveBinding,
  handlerUnavailable,
  duplicateCommand,
}

enum VoiceDecisionKind { allowed, needsConfirmation, rejected }

enum VoiceResultCode {
  applied,
  opened,
  needsConfirmation,
  unavailable,
  executionFailed,
  cancelled,
  conflict,
  invalidParameters,
  ambiguousEntity,
  persistenceFailed,
  expired,
  rejected,
}

class VoiceInterpretation {
  VoiceInterpretation({
    required this.action,
    required Map<String, Object?> parameters,
    required this.normalizedTranscript,
    this.schemaVersion = 1,
  }) : parameters = Map<String, Object?>.unmodifiable(parameters);

  final VoiceActionId action;
  final Map<String, Object?> parameters;
  final String normalizedTranscript;
  final int schemaVersion;
}

class VoiceAbstention {
  const VoiceAbstention({
    required this.reason,
    required this.normalizedTranscript,
  });

  final VoiceAbstentionReason reason;
  final String normalizedTranscript;
}

class VoiceInterpretationResult {
  const VoiceInterpretationResult.recognized(this.interpretation)
    : abstention = null;

  const VoiceInterpretationResult.abstained(this.abstention)
    : interpretation = null;

  final VoiceInterpretation? interpretation;
  final VoiceAbstention? abstention;

  bool get isRecognized => interpretation != null;
}

class VoiceBindingIdentity {
  VoiceBindingIdentity.create(String surfaceId)
    : this(surfaceId: surfaceId, instanceId: _nextInstanceId());

  const VoiceBindingIdentity({
    required this.surfaceId,
    required this.instanceId,
  });

  final String surfaceId;
  final int instanceId;

  static int _instanceSequence = 0;

  static int _nextInstanceId() {
    _instanceSequence += 1;
    return _instanceSequence;
  }

  String get key => '$surfaceId#$instanceId';

  @override
  bool operator ==(Object other) {
    return other is VoiceBindingIdentity &&
        other.surfaceId == surfaceId &&
        other.instanceId == instanceId;
  }

  @override
  int get hashCode => Object.hash(surfaceId, instanceId);
}

class VoiceCallbackIdentity {
  const VoiceCallbackIdentity({required this.binding, required this.action});

  final VoiceBindingIdentity binding;
  final VoiceActionId action;

  @override
  bool operator ==(Object other) {
    return other is VoiceCallbackIdentity &&
        other.binding == binding &&
        other.action == action;
  }

  @override
  int get hashCode => Object.hash(binding, action);
}

class VoiceContextSnapshot {
  const VoiceContextSnapshot({
    required this.binding,
    required this.contextGeneration,
    required this.uid,
    required this.role,
    required this.surfaceId,
    this.retailerId,
    this.visitId,
    this.routePlanId,
    this.routeStopId,
    this.draftId,
    this.draftRevision,
  });

  final VoiceBindingIdentity binding;
  final int contextGeneration;
  final String uid;
  final String role;
  final String surfaceId;
  final String? retailerId;
  final String? visitId;
  final String? routePlanId;
  final String? routeStopId;
  final String? draftId;
  final int? draftRevision;
}

class VoiceCommandEnvelope {
  const VoiceCommandEnvelope({
    required this.sessionId,
    required this.commandId,
    required this.interpretation,
    required this.context,
    required this.createdTick,
    required this.expiresAtTick,
  });

  final String sessionId;
  final String commandId;
  final VoiceInterpretation interpretation;
  final VoiceContextSnapshot context;
  final int createdTick;
  final int expiresAtTick;

  bool isExpired(int currentTick) => currentTick >= expiresAtTick;
}

class VoiceActionResult {
  const VoiceActionResult({required this.code, this.failure});

  const VoiceActionResult.opened() : this(code: VoiceResultCode.opened);

  const VoiceActionResult.applied() : this(code: VoiceResultCode.applied);

  const VoiceActionResult.needsConfirmation()
    : this(code: VoiceResultCode.needsConfirmation);

  const VoiceActionResult.cancelled() : this(code: VoiceResultCode.cancelled);

  const VoiceActionResult.handlerUnavailable()
    : this(
        code: VoiceResultCode.unavailable,
        failure: VoicePolicyFailure.handlerUnavailable,
      );

  const VoiceActionResult.executionFailed()
    : this(code: VoiceResultCode.executionFailed);

  const VoiceActionResult.duplicate()
    : this(
        code: VoiceResultCode.conflict,
        failure: VoicePolicyFailure.duplicateCommand,
      );

  const VoiceActionResult.rejected(VoicePolicyFailure failure)
    : this(code: VoiceResultCode.rejected, failure: failure);

  final VoiceResultCode code;
  final VoicePolicyFailure? failure;
}
