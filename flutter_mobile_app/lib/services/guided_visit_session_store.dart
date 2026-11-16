import 'dart:convert';

import 'project_local_store.dart';

class GuidedVisitSessionState {
  const GuidedVisitSessionState({
    this.orderSubmitted = false,
    this.orderPending = false,
    this.orderRecoveryBlocked = false,
    this.duplicateOrderCount = 0,
    this.orderAbsenceVerified = false,
    this.completionPending = false,
    this.outcomeRecorded = false,
  });

  final bool orderSubmitted;
  final bool orderPending;
  final bool orderRecoveryBlocked;
  final int duplicateOrderCount;
  final bool orderAbsenceVerified;
  final bool completionPending;
  final bool outcomeRecorded;

  bool get closeReady => orderSubmitted || orderPending || outcomeRecorded;

  GuidedVisitSessionState copyWith({
    bool? orderSubmitted,
    bool? orderPending,
    bool? orderRecoveryBlocked,
    int? duplicateOrderCount,
    bool? orderAbsenceVerified,
    bool? completionPending,
    bool? outcomeRecorded,
  }) => GuidedVisitSessionState(
    orderSubmitted: orderSubmitted ?? this.orderSubmitted,
    orderPending: orderPending ?? this.orderPending,
    orderRecoveryBlocked: orderRecoveryBlocked ?? this.orderRecoveryBlocked,
    duplicateOrderCount: duplicateOrderCount ?? this.duplicateOrderCount,
    orderAbsenceVerified: orderAbsenceVerified ?? this.orderAbsenceVerified,
    completionPending: completionPending ?? this.completionPending,
    outcomeRecorded: outcomeRecorded ?? this.outcomeRecorded,
  );
}

class GuidedVisitSessionStore {
  GuidedVisitSessionStore._();

  static final Set<String> _submittedOrders = <String>{};
  static final Set<String> _verifiedOrderAbsence = <String>{};
  static final Set<String> _recordedOutcomes = <String>{};

  static String _scopeKey({
    required String salesmanUid,
    required String routePlanId,
    required String routeStopId,
  }) {
    final List<String> parts = <String>[
      ProjectLocalStore().projectId,
      salesmanUid.trim(),
      routePlanId.trim(),
      routeStopId.trim(),
    ];
    if (parts.any((String value) => value.isEmpty)) {
      throw ArgumentError('Guided visit session identity cannot be empty.');
    }
    String encode(String value) =>
        base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    return 'v2.${parts.map(encode).join('.')}';
  }

  static String _legacyScope(String scoped) {
    final parts = scoped.split('.');
    return 'v2.${parts.skip(2).join('.')}';
  }

  static void resetRuntime() {
    _submittedOrders.clear();
    _verifiedOrderAbsence.clear();
    _recordedOutcomes.clear();
  }

  static String _orderKey(String scopeKey) =>
      'guided_visit.$scopeKey.order_submitted';
  static String _orderAbsenceKey(String scopeKey) =>
      'guided_visit.$scopeKey.order_absence_verified';
  static String _completionPendingKey(String scopeKey) =>
      'guided_visit.$scopeKey.completion_pending';
  static String _outcomeKey(String scopeKey) =>
      'guided_visit.$scopeKey.outcome_recorded';

  static Future<GuidedVisitSessionState> read({
    required String salesmanUid,
    required String routePlanId,
    required String routeStopId,
  }) async {
    final revision = ProjectLocalStore.runtimeRevision;
    final String scopeKey = _scopeKey(
      salesmanUid: salesmanUid,
      routePlanId: routePlanId,
      routeStopId: routeStopId,
    );
    final store = ProjectLocalStore();
    final uid = salesmanUid.trim();
    final state = GuidedVisitSessionState(
      orderSubmitted:
          _submittedOrders.contains(scopeKey) ||
          (await store.read(
                uid,
                _orderKey(scopeKey),
                legacyKey: _orderKey(_legacyScope(scopeKey)),
              ) ==
              'true'),
      orderAbsenceVerified:
          _verifiedOrderAbsence.contains(scopeKey) ||
          (await store.read(
                uid,
                _orderAbsenceKey(scopeKey),
                legacyKey: _orderAbsenceKey(_legacyScope(scopeKey)),
              ) ==
              'true'),
      completionPending:
          await store.read(
            uid,
            _completionPendingKey(scopeKey),
            legacyKey: _completionPendingKey(_legacyScope(scopeKey)),
          ) ==
          'true',
      outcomeRecorded:
          _recordedOutcomes.contains(scopeKey) ||
          (await store.read(
                uid,
                _outcomeKey(scopeKey),
                legacyKey: _outcomeKey(_legacyScope(scopeKey)),
              ) ==
              'true'),
    );
    return revision == ProjectLocalStore.runtimeRevision &&
            store.isActive(salesmanUid)
        ? state
        : const GuidedVisitSessionState();
  }

  static Future<void> markOrderSubmitted({
    required String salesmanUid,
    required String routePlanId,
    required String routeStopId,
  }) async {
    final String scopeKey = _scopeKey(
      salesmanUid: salesmanUid,
      routePlanId: routePlanId,
      routeStopId: routeStopId,
    );
    _submittedOrders.add(scopeKey);
    _verifiedOrderAbsence.remove(scopeKey);
    final store = ProjectLocalStore();
    final uid = salesmanUid.trim();
    await store.write(uid, _orderKey(scopeKey), 'true');
    await store.remove(uid, _orderAbsenceKey(scopeKey));
  }

  static Future<void> markOrderAbsenceVerified({
    required String salesmanUid,
    required String routePlanId,
    required String routeStopId,
  }) async {
    final String scopeKey = _scopeKey(
      salesmanUid: salesmanUid,
      routePlanId: routePlanId,
      routeStopId: routeStopId,
    );
    _verifiedOrderAbsence.add(scopeKey);
    final store = ProjectLocalStore();
    final uid = salesmanUid.trim();
    await store.write(uid, _orderAbsenceKey(scopeKey), 'true');
  }

  static Future<void> markOutcomeRecorded({
    required String salesmanUid,
    required String routePlanId,
    required String routeStopId,
  }) async {
    final String scopeKey = _scopeKey(
      salesmanUid: salesmanUid,
      routePlanId: routePlanId,
      routeStopId: routeStopId,
    );
    _recordedOutcomes.add(scopeKey);
    final store = ProjectLocalStore();
    final uid = salesmanUid.trim();
    await store.write(uid, _outcomeKey(scopeKey), 'true');
  }

  static Future<void> markCompletionPending({
    required String salesmanUid,
    required String routePlanId,
    required String routeStopId,
  }) async {
    final String scopeKey = _scopeKey(
      salesmanUid: salesmanUid,
      routePlanId: routePlanId,
      routeStopId: routeStopId,
    );
    final store = ProjectLocalStore();
    final uid = salesmanUid.trim();
    await store.write(uid, _completionPendingKey(scopeKey), 'true');
  }

  static Future<void> clearCompletionPending({
    required String salesmanUid,
    required String routePlanId,
    required String routeStopId,
  }) async {
    final String scopeKey = _scopeKey(
      salesmanUid: salesmanUid,
      routePlanId: routePlanId,
      routeStopId: routeStopId,
    );
    final store = ProjectLocalStore();
    final uid = salesmanUid.trim();
    await store.remove(uid, _completionPendingKey(scopeKey));
  }

  static Future<void> clear({
    required String salesmanUid,
    required String routePlanId,
    required String routeStopId,
  }) async {
    final String scopeKey = _scopeKey(
      salesmanUid: salesmanUid,
      routePlanId: routePlanId,
      routeStopId: routeStopId,
    );
    _submittedOrders.remove(scopeKey);
    _verifiedOrderAbsence.remove(scopeKey);
    _recordedOutcomes.remove(scopeKey);
    final store = ProjectLocalStore();
    final uid = salesmanUid.trim();
    await store.remove(uid, _orderKey(scopeKey));
    await store.remove(uid, _orderAbsenceKey(scopeKey));
    await store.remove(uid, _completionPendingKey(scopeKey));
    await store.remove(uid, _outcomeKey(scopeKey));
  }
}
