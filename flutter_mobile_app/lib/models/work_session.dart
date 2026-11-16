import 'dart:math';

import 'tracking_control.dart';

enum WorkSessionLocalStatus { starting, active, ended, superseded }

class WorkSession {
  const WorkSession({
    required this.uid,
    required this.sessionId,
    required this.generation,
    required this.lastFixSequence,
    this.lastRouteStopEventSequence = 0,
    required this.status,
    this.userDocumentId = '',
    this.previousSessionId = '',
    this.previousGeneration = 0,
    this.endPendingSync = false,
    this.trackingMode = TrackingMode.batterySaver,
    this.controlRevision = 0,
    this.appliedControlRevision = 0,
    this.lastBreadcrumbCapturedAt,
    this.deviceStartedAt,
  });

  final String uid;
  final String sessionId;
  final int generation;
  final int lastFixSequence;
  final int lastRouteStopEventSequence;
  final WorkSessionLocalStatus status;
  final String userDocumentId;
  final String previousSessionId;
  final int previousGeneration;
  final bool endPendingSync;
  final TrackingMode trackingMode;
  final int controlRevision;
  final int appliedControlRevision;
  final DateTime? lastBreadcrumbCapturedAt;
  final DateTime? deviceStartedAt;

  bool get isAcknowledged =>
      status == WorkSessionLocalStatus.active && generation > 0;

  WorkSession copyWith({
    String? sessionId,
    int? generation,
    int? lastFixSequence,
    int? lastRouteStopEventSequence,
    WorkSessionLocalStatus? status,
    String? userDocumentId,
    String? previousSessionId,
    int? previousGeneration,
    bool? endPendingSync,
    TrackingMode? trackingMode,
    int? controlRevision,
    int? appliedControlRevision,
    DateTime? lastBreadcrumbCapturedAt,
    bool clearLastBreadcrumbCapturedAt = false,
    DateTime? deviceStartedAt,
  }) => WorkSession(
    uid: uid,
    sessionId: sessionId ?? this.sessionId,
    generation: generation ?? this.generation,
    lastFixSequence: lastFixSequence ?? this.lastFixSequence,
    lastRouteStopEventSequence:
        lastRouteStopEventSequence ?? this.lastRouteStopEventSequence,
    status: status ?? this.status,
    userDocumentId: userDocumentId ?? this.userDocumentId,
    previousSessionId: previousSessionId ?? this.previousSessionId,
    previousGeneration: previousGeneration ?? this.previousGeneration,
    endPendingSync: endPendingSync ?? this.endPendingSync,
    trackingMode: trackingMode ?? this.trackingMode,
    controlRevision: controlRevision ?? this.controlRevision,
    appliedControlRevision:
        appliedControlRevision ?? this.appliedControlRevision,
    lastBreadcrumbCapturedAt: clearLastBreadcrumbCapturedAt
        ? null
        : lastBreadcrumbCapturedAt ?? this.lastBreadcrumbCapturedAt,
    deviceStartedAt: deviceStartedAt ?? this.deviceStartedAt,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'uid': uid,
    'sessionId': sessionId,
    'generation': generation,
    'lastFixSequence': lastFixSequence,
    'lastRouteStopEventSequence': lastRouteStopEventSequence,
    'status': status.name,
    'userDocumentId': userDocumentId,
    'previousSessionId': previousSessionId,
    'previousGeneration': previousGeneration,
    'endPendingSync': endPendingSync,
    'trackingMode': trackingMode.wireValue,
    'controlRevision': controlRevision,
    'appliedControlRevision': appliedControlRevision,
    'lastBreadcrumbCapturedAt': lastBreadcrumbCapturedAt
        ?.toUtc()
        .toIso8601String(),
    'deviceStartedAt': deviceStartedAt?.toUtc().toIso8601String(),
  };

  static WorkSession? tryParse(Map<String, dynamic> data, String uid) {
    if (data['uid'] != uid ||
        data['sessionId'] is! String ||
        data['generation'] is! num ||
        data['lastFixSequence'] is! num ||
        data['status'] is! String) {
      return null;
    }
    WorkSessionLocalStatus? status;
    for (final WorkSessionLocalStatus value in WorkSessionLocalStatus.values) {
      if (value.name == data['status']) {
        status = value;
        break;
      }
    }
    if (status == null) return null;
    final int generation = (data['generation'] as num).toInt();
    final int lastFixSequence = (data['lastFixSequence'] as num).toInt();
    final int lastRouteStopEventSequence =
        data['lastRouteStopEventSequence'] is num
        ? (data['lastRouteStopEventSequence'] as num).toInt()
        : 0;
    final int previousGeneration = data['previousGeneration'] is num
        ? (data['previousGeneration'] as num).toInt()
        : 0;
    final TrackingMode? parsedMode = TrackingMode.tryParse(
      data['trackingMode'],
    );
    final int controlRevision = data['controlRevision'] is num
        ? (data['controlRevision'] as num).toInt()
        : 0;
    final int appliedControlRevision = data['appliedControlRevision'] is num
        ? (data['appliedControlRevision'] as num).toInt()
        : 0;
    DateTime? lastBreadcrumbCapturedAt;
    if (data['lastBreadcrumbCapturedAt'] is String) {
      lastBreadcrumbCapturedAt = DateTime.tryParse(
        data['lastBreadcrumbCapturedAt'] as String,
      )?.toUtc();
    }
    final DateTime? deviceStartedAt = data['deviceStartedAt'] is String
        ? DateTime.tryParse(data['deviceStartedAt'] as String)?.toUtc()
        : null;
    if (generation < 0 ||
        lastFixSequence < 0 ||
        lastRouteStopEventSequence < 0 ||
        previousGeneration < 0 ||
        controlRevision < 0 ||
        appliedControlRevision < 0 ||
        appliedControlRevision > controlRevision) {
      return null;
    }
    return WorkSession(
      uid: uid,
      sessionId: (data['sessionId'] as String).trim(),
      generation: generation,
      lastFixSequence: lastFixSequence,
      lastRouteStopEventSequence: lastRouteStopEventSequence,
      status: status,
      userDocumentId: (data['userDocumentId'] as String? ?? '').trim(),
      previousSessionId: (data['previousSessionId'] as String? ?? '').trim(),
      previousGeneration: previousGeneration,
      endPendingSync: data['endPendingSync'] == true,
      trackingMode: parsedMode ?? TrackingMode.batterySaver,
      controlRevision: controlRevision,
      appliedControlRevision: appliedControlRevision,
      lastBreadcrumbCapturedAt: lastBreadcrumbCapturedAt,
      deviceStartedAt: deviceStartedAt,
    );
  }
}

String createWorkSessionId() {
  final Random random = Random.secure();
  return List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    growable: false,
  ).join();
}
