import 'action_registry.dart';
import 'voice_binding.dart';
import 'voice_policy_gateway.dart';
import 'voice_types.dart';

class VoiceConfirmationHandle {
  VoiceConfirmationHandle._(this._commandKey, this._nonce);

  final String _commandKey;
  final Object _nonce;
}

class _PendingConfirmation {
  const _PendingConfirmation({required this.envelope, required this.handle});

  final VoiceCommandEnvelope envelope;
  final VoiceConfirmationHandle handle;
}

class VoiceActionDispatcher {
  VoiceActionDispatcher({
    required this.registry,
    required this.binding,
    VoicePolicyGateway? policy,
  }) : policy =
           policy ?? VoicePolicyGateway(registry: registry, binding: binding);

  final VoiceActionRegistry registry;
  final VoiceScreenBinding binding;
  final VoicePolicyGateway policy;
  final Set<String> _consumedCommandKeys = <String>{};
  final Set<String> _expiredCommandKeys = <String>{};
  final Set<String> _inFlightCommandKeys = <String>{};
  final Map<String, _PendingConfirmation> _pendingConfirmations =
      <String, _PendingConfirmation>{};

  Future<VoiceActionResult> dispatch(
    VoiceCommandEnvelope envelope, {
    required int currentTick,
    required bool isOnline,
    bool featureEnabled = true,
  }) async {
    _pruneExpiredPending(currentTick);
    final String commandKey = _commandKey(envelope);
    if (_consumedCommandKeys.contains(commandKey) ||
        _inFlightCommandKeys.contains(commandKey) ||
        _pendingConfirmations.containsKey(commandKey)) {
      return const VoiceActionResult.duplicate();
    }

    final VoicePolicyDecision decision = policy.evaluate(
      envelope: envelope,
      currentTick: currentTick,
      isOnline: isOnline,
      featureEnabled: featureEnabled,
    );
    if (decision.kind == VoiceDecisionKind.rejected) {
      return VoiceActionResult.rejected(
        decision.failure ?? VoicePolicyFailure.prerequisiteMissing,
      );
    }
    if (decision.kind == VoiceDecisionKind.needsConfirmation) {
      final VoiceConfirmationHandle handle = VoiceConfirmationHandle._(
        commandKey,
        Object(),
      );
      _pendingConfirmations[commandKey] = _PendingConfirmation(
        envelope: envelope,
        handle: handle,
      );
      return const VoiceActionResult.needsConfirmation();
    }

    return _invokeApproved(envelope, commandKey);
  }

  VoiceConfirmationHandle? confirmationHandleFor(
    VoiceCommandEnvelope envelope,
  ) {
    return _pendingConfirmations[_commandKey(envelope)]?.handle;
  }

  Future<VoiceActionResult> confirm(
    VoiceConfirmationHandle handle, {
    required int currentTick,
    required bool isOnline,
    bool featureEnabled = true,
  }) async {
    _pruneExpiredPending(currentTick);
    final String commandKey = handle._commandKey;
    if (_expiredCommandKeys.contains(commandKey)) {
      return const VoiceActionResult(
        code: VoiceResultCode.expired,
        failure: VoicePolicyFailure.expired,
      );
    }
    if (_consumedCommandKeys.contains(commandKey) ||
        _inFlightCommandKeys.contains(commandKey)) {
      return const VoiceActionResult.duplicate();
    }
    final _PendingConfirmation? pending = _pendingConfirmations[commandKey];
    if (pending == null || !identical(pending.handle._nonce, handle._nonce)) {
      return const VoiceActionResult.duplicate();
    }
    _pendingConfirmations.remove(commandKey);

    _consumedCommandKeys.add(commandKey);
    final VoicePolicyDecision decision = policy.evaluate(
      envelope: pending.envelope,
      currentTick: currentTick,
      isOnline: isOnline,
      featureEnabled: featureEnabled,
      confirmationProvided: true,
    );
    if (decision.kind != VoiceDecisionKind.allowed) {
      return VoiceActionResult.rejected(
        decision.failure ?? VoicePolicyFailure.prerequisiteMissing,
      );
    }

    return _invokeApproved(pending.envelope, commandKey);
  }

  VoiceActionResult cancel(VoiceConfirmationHandle handle, {int? currentTick}) {
    if (currentTick != null) _pruneExpiredPending(currentTick);
    final String commandKey = handle._commandKey;
    final _PendingConfirmation? pending = _pendingConfirmations[commandKey];
    if (pending == null || !identical(pending.handle._nonce, handle._nonce)) {
      return const VoiceActionResult.duplicate();
    }
    _pendingConfirmations.remove(commandKey);
    _consumedCommandKeys.add(commandKey);
    return const VoiceActionResult.cancelled();
  }

  Future<VoiceActionResult> _invokeApproved(
    VoiceCommandEnvelope envelope,
    String commandKey,
  ) async {
    if (!binding.isActive) {
      return const VoiceActionResult.rejected(
        VoicePolicyFailure.inactiveBinding,
      );
    }
    if (!binding.matches(envelope.context)) {
      return const VoiceActionResult.rejected(VoicePolicyFailure.staleContext);
    }

    final VoiceActionHandler? handler = binding.handlerFor(
      envelope.interpretation.action,
    );
    if (handler == null) {
      return const VoiceActionResult.handlerUnavailable();
    }

    _consumedCommandKeys.add(commandKey);
    _inFlightCommandKeys.add(commandKey);
    try {
      final VoiceActionResult result = await handler(envelope);
      return result;
    } catch (_) {
      return const VoiceActionResult.executionFailed();
    } finally {
      _inFlightCommandKeys.remove(commandKey);
    }
  }

  String _commandKey(VoiceCommandEnvelope envelope) {
    return '${envelope.sessionId}:${envelope.commandId}';
  }

  void _pruneExpiredPending(int currentTick) {
    final List<String> expiredKeys = <String>[];
    for (final MapEntry<String, _PendingConfirmation> entry
        in _pendingConfirmations.entries) {
      if (entry.value.envelope.isExpired(currentTick)) {
        expiredKeys.add(entry.key);
      }
    }
    for (final String key in expiredKeys) {
      _pendingConfirmations.remove(key);
      _consumedCommandKeys.add(key);
      _expiredCommandKeys.add(key);
    }
  }
}
