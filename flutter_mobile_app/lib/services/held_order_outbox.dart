import 'dart:async';
import 'dart:convert';

import 'project_local_store.dart';

enum HeldOrderState { pending, held, needsAttention }

class HeldOrder {
  const HeldOrder({
    required this.orderId,
    required this.uid,
    required this.workSessionId,
    required this.workSessionGeneration,
    required this.sessionStartedAt,
    required this.deviceAt,
    required this.payload,
    this.state = HeldOrderState.pending,
    this.lastError = '',
    this.tracking,
    this.trackingAttempts = 0,
    this.trackingTransientFailures = 0,
    this.trackingRetryAfter,
    this.storedAs,
  });

  final String orderId;
  final String uid;
  final String workSessionId;
  final int workSessionGeneration;
  final DateTime sessionStartedAt;
  final DateTime deviceAt;
  final Map<String, dynamic> payload;
  final HeldOrderState state;
  final String lastError;
  final Map<String, dynamic>? tracking;
  final int trackingAttempts;
  final int trackingTransientFailures;
  final DateTime? trackingRetryAfter;
  final String? storedAs;

  HeldOrder copyWith({
    HeldOrderState? state,
    String? lastError,
    int? trackingAttempts,
    int? trackingTransientFailures,
    DateTime? trackingRetryAfter,
    String? storedAs,
  }) => HeldOrder(
    orderId: orderId,
    uid: uid,
    workSessionId: workSessionId,
    workSessionGeneration: workSessionGeneration,
    sessionStartedAt: sessionStartedAt,
    deviceAt: deviceAt,
    payload: payload,
    state: state ?? this.state,
    lastError: lastError ?? this.lastError,
    tracking: tracking,
    trackingAttempts: trackingAttempts ?? this.trackingAttempts,
    trackingTransientFailures:
        trackingTransientFailures ?? this.trackingTransientFailures,
    trackingRetryAfter: trackingRetryAfter ?? this.trackingRetryAfter,
    storedAs: storedAs ?? this.storedAs,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'orderId': orderId,
    'uid': uid,
    'workSessionId': workSessionId,
    'workSessionGeneration': workSessionGeneration,
    'sessionStartedAt': sessionStartedAt.toUtc().toIso8601String(),
    'deviceAt': deviceAt.toUtc().toIso8601String(),
    'payload': payload,
    'state': state.name,
    'lastError': lastError,
    if (tracking != null) 'tracking': tracking,
    'trackingAttempts': trackingAttempts,
    'trackingTransientFailures': trackingTransientFailures,
    if (trackingRetryAfter != null)
      'trackingRetryAfter': trackingRetryAfter!.toUtc().toIso8601String(),
    if (storedAs != null) 'storedAs': storedAs,
  };

  static HeldOrder? tryParse(Object? raw, String ownerUid) {
    if (raw is! Map) return null;
    final Object? payload = raw['payload'];
    final DateTime? deviceAt = DateTime.tryParse(
      (raw['deviceAt'] ?? '').toString(),
    )?.toUtc();
    final DateTime? sessionStartedAt = DateTime.tryParse(
      (raw['sessionStartedAt'] ?? '').toString(),
    )?.toUtc();
    final String orderId = (raw['orderId'] ?? '').toString();
    final String sessionId = (raw['workSessionId'] ?? '').toString();
    final Object? generation = raw['workSessionGeneration'];
    HeldOrderState? state;
    for (final HeldOrderState value in HeldOrderState.values) {
      if (value.name == raw['state']) state = value;
    }
    if (payload is! Map ||
        deviceAt == null ||
        sessionStartedAt == null ||
        orderId.isEmpty ||
        sessionId.isEmpty ||
        generation is! num ||
        state == null ||
        raw['uid'] != ownerUid) {
      return null;
    }
    return HeldOrder(
      orderId: orderId,
      uid: ownerUid,
      workSessionId: sessionId,
      workSessionGeneration: generation.toInt(),
      sessionStartedAt: sessionStartedAt,
      deviceAt: deviceAt,
      payload: Map<String, dynamic>.from(payload),
      state: state,
      lastError: (raw['lastError'] ?? '').toString(),
      tracking: raw['tracking'] is Map
          ? Map<String, dynamic>.from(raw['tracking'] as Map)
          : null,
      trackingAttempts: raw['trackingAttempts'] is num
          ? (raw['trackingAttempts'] as num).toInt()
          : 0,
      trackingTransientFailures: raw['trackingTransientFailures'] is num
          ? (raw['trackingTransientFailures'] as num).toInt()
          : 0,
      trackingRetryAfter: DateTime.tryParse(
        (raw['trackingRetryAfter'] ?? '').toString(),
      )?.toUtc(),
      storedAs:
          raw['storedAs'] is String && (raw['storedAs'] as String).isNotEmpty
          ? raw['storedAs'] as String
          : null,
    );
  }
}

class HeldOrderOutbox {
  HeldOrderOutbox({String? projectId})
    : _store = ProjectLocalStore(projectId: projectId);

  static const String storeName = 'held_orders_v1';
  static Future<void> _tail = Future<void>.value();

  final ProjectLocalStore _store;

  Future<T> _locked<T>(Future<T> Function() action) {
    final Future<T> result = _tail.then<T>((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<HeldOrder>> readAll(String uid) =>
      _locked<List<HeldOrder>>(() => _read(uid));

  Future<void> put(HeldOrder order) => _locked<void>(() async {
    final List<HeldOrder> rows = await _read(order.uid);
    rows.removeWhere((HeldOrder row) => row.orderId == order.orderId);
    rows.add(order);
    await _write(order.uid, rows);
  });

  Future<void> update(HeldOrder order) => _locked<void>(() async {
    final List<HeldOrder> rows = await _read(order.uid);
    final int index = rows.indexWhere(
      (HeldOrder row) => row.orderId == order.orderId,
    );
    if (index < 0) return;
    rows[index] = order;
    await _write(order.uid, rows);
  });

  Future<void> remove(String uid, String orderId) => _locked<void>(() async {
    final List<HeldOrder> rows = await _read(uid);
    final int before = rows.length;
    rows.removeWhere((HeldOrder row) => row.orderId == orderId);
    if (rows.length != before) await _write(uid, rows);
  });

  Future<void> removeAll(String uid, Iterable<String> orderIds) =>
      _locked<void>(() async {
        final Set<String> ids = orderIds.toSet();
        final List<HeldOrder> rows = await _read(uid);
        final int before = rows.length;
        rows.removeWhere((HeldOrder row) => ids.contains(row.orderId));
        if (rows.length != before) await _write(uid, rows);
      });

  Future<void> updateAll(String uid, Iterable<HeldOrder> orders) =>
      _locked<void>(() async {
        final List<HeldOrder> rows = await _read(uid);
        bool changed = false;
        for (final HeldOrder order in orders) {
          final int index = rows.indexWhere(
            (HeldOrder row) => row.orderId == order.orderId,
          );
          if (index < 0) continue;
          rows[index] = order;
          changed = true;
        }
        if (changed) await _write(uid, rows);
      });

  Future<List<HeldOrder>> _read(String uid) async {
    final String? encoded = await _store.read(uid, storeName);
    if (encoded == null) return <HeldOrder>[];
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! List) return <HeldOrder>[];
    return decoded
        .map((Object? row) => HeldOrder.tryParse(row, uid))
        .whereType<HeldOrder>()
        .toList();
  }

  Future<void> _write(String uid, List<HeldOrder> rows) async {
    if (rows.isEmpty) {
      await _store.remove(uid, storeName);
      return;
    }
    await _store.write(
      uid,
      storeName,
      jsonEncode(rows.map((HeldOrder row) => row.toJson()).toList()),
    );
  }
}
