import 'voice_types.dart';

typedef VoiceActionHandler =
    Future<VoiceActionResult> Function(VoiceCommandEnvelope envelope);

class VoiceScreenBinding {
  VoiceScreenBinding({required String surfaceId})
    : _surfaceId = surfaceId.trim().toLowerCase(),
      identity = VoiceBindingIdentity.create(surfaceId.trim().toLowerCase());

  final VoiceBindingIdentity identity;
  final String _surfaceId;
  final Map<VoiceActionId, VoiceActionHandler> _handlers =
      <VoiceActionId, VoiceActionHandler>{};

  bool _active = true;
  int _contextGeneration = 0;
  String _uid = '';
  String _role = '';
  String? _retailerId;
  String? _visitId;
  String? _routePlanId;
  String? _routeStopId;
  String? _draftId;
  int? _draftRevision;

  bool get isActive => _active;

  int get contextGeneration => _contextGeneration;

  String get surfaceId => _surfaceId;

  void updateContext({
    required String uid,
    required String role,
    String? retailerId,
    String? visitId,
    String? routePlanId,
    String? routeStopId,
    String? draftId,
    int? draftRevision,
  }) {
    _ensureActive();
    final String normalizedUid = uid.trim();
    final String normalizedRole = role.trim().toLowerCase();
    final bool changed =
        normalizedUid != _uid ||
        normalizedRole != _role ||
        retailerId != _retailerId ||
        visitId != _visitId ||
        routePlanId != _routePlanId ||
        routeStopId != _routeStopId ||
        draftId != _draftId ||
        draftRevision != _draftRevision;

    if (!changed) return;

    _uid = normalizedUid;
    _role = normalizedRole;
    _retailerId = retailerId;
    _visitId = visitId;
    _routePlanId = routePlanId;
    _routeStopId = routeStopId;
    _draftId = draftId;
    _draftRevision = draftRevision;
    _contextGeneration += 1;
  }

  void registerHandler(VoiceActionId action, VoiceActionHandler handler) {
    _ensureActive();
    _handlers[action] = handler;
  }

  void unregisterHandler(VoiceActionId action) {
    _ensureActive();
    _handlers.remove(action);
  }

  VoiceActionHandler? handlerFor(VoiceActionId action) => _handlers[action];

  VoiceCallbackIdentity callbackIdentity(VoiceActionId action) {
    return VoiceCallbackIdentity(binding: identity, action: action);
  }

  VoiceContextSnapshot snapshot() {
    return VoiceContextSnapshot(
      binding: identity,
      contextGeneration: _contextGeneration,
      uid: _uid,
      role: _role,
      surfaceId: _surfaceId,
      retailerId: _retailerId,
      visitId: _visitId,
      routePlanId: _routePlanId,
      routeStopId: _routeStopId,
      draftId: _draftId,
      draftRevision: _draftRevision,
    );
  }

  bool matches(VoiceContextSnapshot captured) {
    return _active &&
        captured.binding == identity &&
        captured.contextGeneration == _contextGeneration &&
        captured.uid == _uid &&
        captured.role == _role &&
        captured.surfaceId == _surfaceId &&
        captured.retailerId == _retailerId &&
        captured.visitId == _visitId &&
        captured.routePlanId == _routePlanId &&
        captured.routeStopId == _routeStopId &&
        captured.draftId == _draftId &&
        captured.draftRevision == _draftRevision;
  }

  void dispose() {
    if (!_active) return;
    _active = false;
    _contextGeneration += 1;
    _handlers.clear();
  }

  void _ensureActive() {
    if (!_active) {
      throw StateError('Voice screen binding is disposed');
    }
  }
}
