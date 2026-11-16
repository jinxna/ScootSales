enum RouteStopOutboxState { pending, held, needsAttention }

class RouteStopLifecycleEvent {
  const RouteStopLifecycleEvent({
    required this.uid,
    required this.planId,
    required this.stopId,
    required this.workSessionId,
    required this.workSessionGeneration,
    required this.sessionEventSequence,
    required this.eventId,
    required this.status,
    required this.deviceOccurredAt,
    required this.payload,
    required this.expectedSelectedStopId,
    required this.expectedSelectionRevision,
    this.selectionRebaseCount = 0,
    this.state = RouteStopOutboxState.pending,
    this.lastError = '',
    this.sessionDeviceStartedAt,
  });

  final String uid;
  final String planId;
  final String stopId;
  final String workSessionId;
  final int workSessionGeneration;
  final int sessionEventSequence;
  final String eventId;
  final String status;
  final DateTime deviceOccurredAt;

  final Map<String, dynamic> payload;

  final String expectedSelectedStopId;
  final int expectedSelectionRevision;
  final int selectionRebaseCount;
  final RouteStopOutboxState state;
  final String lastError;
  final DateTime? sessionDeviceStartedAt;

  DateTime get sessionStartedAtForHeldWork =>
      sessionDeviceStartedAt ?? deviceOccurredAt;

  RouteStopLifecycleEvent copyWith({
    String? expectedSelectedStopId,
    int? expectedSelectionRevision,
    int? selectionRebaseCount,
    RouteStopOutboxState? state,
    String? lastError,
  }) => RouteStopLifecycleEvent(
    uid: uid,
    planId: planId,
    stopId: stopId,
    workSessionId: workSessionId,
    workSessionGeneration: workSessionGeneration,
    sessionEventSequence: sessionEventSequence,
    eventId: eventId,
    status: status,
    deviceOccurredAt: deviceOccurredAt,
    payload: payload,
    expectedSelectedStopId:
        expectedSelectedStopId ?? this.expectedSelectedStopId,
    expectedSelectionRevision:
        expectedSelectionRevision ?? this.expectedSelectionRevision,
    selectionRebaseCount: selectionRebaseCount ?? this.selectionRebaseCount,
    state: state ?? this.state,
    lastError: lastError ?? this.lastError,
    sessionDeviceStartedAt: sessionDeviceStartedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'uid': uid,
    'planId': planId,
    'stopId': stopId,
    'workSessionId': workSessionId,
    'workSessionGeneration': workSessionGeneration,
    'sessionEventSequence': sessionEventSequence,
    'eventId': eventId,
    'status': status,
    'deviceOccurredAt': deviceOccurredAt.toUtc().toIso8601String(),
    'payload': payload,
    'expectedSelectedStopId': expectedSelectedStopId,
    'expectedSelectionRevision': expectedSelectionRevision,
    'selectionRebaseCount': selectionRebaseCount,
    'state': state.name,
    'lastError': lastError,
    'sessionDeviceStartedAt': sessionDeviceStartedAt
        ?.toUtc()
        .toIso8601String(),
  };

  static RouteStopLifecycleEvent? tryParse(Object? raw) {
    if (raw is! Map || raw.keys.any((Object? key) => key is! String)) {
      return null;
    }
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    final Object? rawPayload = data['payload'];
    final DateTime? occurredAt = DateTime.tryParse(
      (data['deviceOccurredAt'] ?? '').toString(),
    )?.toUtc();
    final String stateName = (data['state'] ?? '').toString();
    RouteStopOutboxState? state;
    for (final RouteStopOutboxState value in RouteStopOutboxState.values) {
      if (value.name == stateName) {
        state = value;
        break;
      }
    }
    if (rawPayload is! Map || occurredAt == null || state == null) return null;
    final String uid = _string(data['uid']);
    final String planId = _string(data['planId']);
    final String stopId = _string(data['stopId']);
    final String sessionId = _string(data['workSessionId']);
    final String eventId = _string(data['eventId']);
    final int? generation = _integer(data['workSessionGeneration']);
    final int? sequence = _integer(data['sessionEventSequence']);
    final int? selectionRevision = _integer(data['expectedSelectionRevision']);
    final int? rebaseCount = _integer(data['selectionRebaseCount']);
    final String status = _string(data['status']);
    if (uid.isEmpty ||
        planId.isEmpty ||
        stopId.isEmpty ||
        sessionId.isEmpty ||
        eventId.isEmpty ||
        generation == null ||
        generation <= 0 ||
        sequence == null ||
        sequence <= 0 ||
        selectionRevision == null ||
        selectionRevision < 0 ||
        rebaseCount == null ||
        rebaseCount < 0 ||
        !<String>{'arrived', 'completed', 'skipped'}.contains(status)) {
      return null;
    }
    return RouteStopLifecycleEvent(
      uid: uid,
      planId: planId,
      stopId: stopId,
      workSessionId: sessionId,
      workSessionGeneration: generation,
      sessionEventSequence: sequence,
      eventId: eventId,
      status: status,
      deviceOccurredAt: occurredAt,
      payload: Map<String, dynamic>.from(rawPayload),
      expectedSelectedStopId: _string(data['expectedSelectedStopId']),
      expectedSelectionRevision: selectionRevision,
      selectionRebaseCount: rebaseCount,
      state: state,
      lastError: _string(data['lastError']),
      sessionDeviceStartedAt: DateTime.tryParse(
        _string(data['sessionDeviceStartedAt']),
      )?.toUtc(),
    );
  }
}

String _string(Object? value) => (value ?? '').toString().trim();

int? _integer(Object? value) => value is int
    ? value
    : value is num
    ? value.toInt()
    : null;
