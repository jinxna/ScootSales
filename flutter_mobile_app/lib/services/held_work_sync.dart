import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../models/company_lifecycle.dart';
import '../models/route_stop_lifecycle_event.dart';
import '../models/work_session.dart';
import 'company_api.dart';
import 'held_order_outbox.dart';
import 'held_work.dart';
import 'project_local_store.dart';
import 'route_stop_outbox.dart';
import 'stuck_work.dart';
import 'work_session_store.dart';

class HeldWorkCounts {
  const HeldWorkCounts({this.stops = 0, this.orders = 0, this.rejected = 0});

  final int stops;
  final int orders;
  final int rejected;

  int get total => stops + orders;
}

class _Pending {
  _Pending(
    this.item,
    this.sessionId,
    this.generation,
    this.startedAt, {
    this.stop,
    this.order,
  });

  final Map<String, Object?> item;
  final String sessionId;
  final int generation;
  final DateTime startedAt;
  final RouteStopLifecycleEvent? stop;
  final HeldOrder? order;
}

class _FlushBudget {
  static const int maxRequests = 20;
  static const int maxFailuresInARow = 3;

  int requests = 0;
  int failures = 0;
  bool stopped = false;

  bool get spent =>
      stopped || failures >= maxFailuresInARow || requests >= maxRequests;
}

class HeldWorkSync {
  HeldWorkSync({
    CompanyApi? api,
    FirebaseFirestore? firestore,
    @visibleForTesting Future<void> Function(HeldOrder order)? orderWriter,
  }) : _api = api ?? CompanyApi.instance,
       _firestore = firestore,
       _orderWriter = orderWriter;

  static const int _itemsPerRequest = 25;
  static const int _bytesPerRequest = 512 * 1024;
  static const int _reconcileBatch = 5;
  int _failedTurn = 0;
  DateTime? _pausedUntil;
  final Set<String> _notOnServer = <String>{};

  final CompanyApi _api;
  final FirebaseFirestore? _firestore;
  final Future<void> Function(HeldOrder order)? _orderWriter;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;
  static bool _signedInAs(String uid) =>
      FirebaseAuth.instance.currentUser?.uid == uid;
  String get _projectId => _db.app.options.projectId;
  RouteStopOutbox get _stops => RouteStopOutbox(projectId: _projectId);
  HeldOrderOutbox get _orders => HeldOrderOutbox(projectId: _projectId);

  Future<void> recordOrder({
    required String uid,
    required String orderId,
    required Map<String, dynamic> orderData,
    Map<String, dynamic>? trackingData,
  }) async {
    try {
      if (!_api.enabled) return;
      final WorkSession? session = await WorkSessionStore(
        projectId: _projectId,
      ).read(uid);
      if (session == null ||
          !session.isAcknowledged ||
          session.endPendingSync) {
        return;
      }
      final List<HeldOrder> existing = await _orders.readAll(uid);
      if (existing.any((HeldOrder row) => row.orderId == orderId)) return;
      final DateTime now = DateTime.now().toUtc();
      await _orders.put(
        HeldOrder(
          orderId: orderId,
          uid: uid,
          workSessionId: session.sessionId,
          workSessionGeneration: session.generation,
          sessionStartedAt: session.deviceStartedAt ?? now,
          deviceAt: now,
          payload: _plain(orderData) as Map<String, dynamic>,
          tracking: trackingData == null
              ? null
              : _plain(trackingData) as Map<String, dynamic>,
        ),
      );
    } catch (error) {
      debugPrint('Order could not be recorded for held work: $error');
    }
  }

  Future<bool> holdOrder(String uid, String orderId) async {
    final List<HeldOrder> rows = await _orders.readAll(uid);
    final int index = rows.indexWhere(
      (HeldOrder row) => row.orderId == orderId,
    );
    if (index < 0) return false;
    await _orders.update(rows[index].copyWith(state: HeldOrderState.held));
    return true;
  }

  Future<void> forgetOrder(String uid, String orderId) =>
      _orders.remove(uid, orderId);

  static const Object _omit = Object();

  static Object? _plain(Object? value) {
    if (value is FieldValue) return _omit;
    if (value is Timestamp) return value.toDate().toUtc().toIso8601String();
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is GeoPoint) {
      return <String, double>{
        'latitude': value.latitude,
        'longitude': value.longitude,
      };
    }
    if (value is Map) {
      final Map<String, dynamic> out = <String, dynamic>{};
      value.forEach((Object? key, Object? item) {
        final Object? plain = _plain(item);
        if (!identical(plain, _omit)) out[key.toString()] = plain;
      });
      return out;
    }
    if (value is Iterable) {
      return value
          .map(_plain)
          .where((Object? item) => !identical(item, _omit))
          .toList();
    }
    return value;
  }

  Future<HeldWorkCounts> counts(String uid, CompanyLifecycle? lifecycle) async {
    await HeldVisits(firestore: _db).settle(uid);
    final bool closed = lifecycle != null && !lifecycle.isOpen;
    final List<RouteStopLifecycleEvent> stopRows = await _stops.readForUid(uid);
    final List<HeldOrder> orderRows = await _orders.readAll(uid);
    final int stops = stopRows
        .where(
          (RouteStopLifecycleEvent event) =>
              event.state == RouteStopOutboxState.held ||
              (closed && event.state == RouteStopOutboxState.pending),
        )
        .length;
    final int orders = orderRows
        .where(
          (HeldOrder order) =>
              order.state == HeldOrderState.held ||
              (closed && order.state == HeldOrderState.pending),
        )
        .length;
    final int rejected =
        stopRows
            .where(
              (RouteStopLifecycleEvent event) =>
                  event.state == RouteStopOutboxState.needsAttention,
            )
            .length +
        orderRows
            .where(
              (HeldOrder order) => order.state == HeldOrderState.needsAttention,
            )
            .length;
    return HeldWorkCounts(
      stops: stops,
      orders: orders,
      rejected:
          rejected +
          await _stuckOutcomes(uid) +
          (await HeldVisits(firestore: _db).readAll(uid)).length,
    );
  }

  Future<bool> hasWorkToUpload(
    String uid, {
    bool includeNotAccepted = true,
  }) async {
    if (await _outboxHoldsWork(uid, includeNotAccepted)) return true;
    try {
      await _db.waitForPendingWrites().timeout(HeldVisits.offlineWait);
    } on TimeoutException {
      return true;
    } catch (_) {}
    return _outboxHoldsWork(uid, includeNotAccepted);
  }

  Future<bool> _outboxHoldsWork(String uid, bool includeNotAccepted) async {
    final bool stopsLeft = (await _stops.readForUid(uid)).any(
      (RouteStopLifecycleEvent event) =>
          includeNotAccepted ||
          event.state != RouteStopOutboxState.needsAttention,
    );
    final bool ordersLeft = (await _orders.readAll(uid)).any(
      (HeldOrder order) =>
          includeNotAccepted || order.state != HeldOrderState.needsAttention,
    );
    if (stopsLeft ||
        ordersLeft ||
        (includeNotAccepted &&
            (await HeldVisits(firestore: _db).readAll(uid)).isNotEmpty)) {
      return true;
    }
    try {
      final String? encoded = await ProjectLocalStore(
        projectId: _projectId,
      ).read(uid, 'outcomes');
      final Object? decoded = encoded == null || encoded.isEmpty
          ? null
          : jsonDecode(encoded);
      return decoded is List &&
          decoded.any(
            (Object? row) =>
                includeNotAccepted ||
                !(row is Map && row['targetStatus'] == 'needs_attention'),
          );
    } catch (_) {
      return false;
    }
  }

  Future<int> _stuckOutcomes(String uid) async {
    try {
      final String? encoded = await ProjectLocalStore(
        projectId: _projectId,
      ).read(uid, 'outcomes');
      if (encoded == null || encoded.isEmpty) return 0;
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! List) return 0;
      return decoded
          .where(
            (Object? row) =>
                row is Map && row['targetStatus'] == 'needs_attention',
          )
          .length;
    } catch (_) {
      return 0;
    }
  }

  Future<int> flush(String uid, CompanyLifecycle lifecycle) async {
    if (!_signedInAs(uid)) return 0;
    int removed = 0;
    final DateTime now = DateTime.now().toUtc();
    final List<_Pending> queue = <_Pending>[];

    for (final RouteStopLifecycleEvent event in await _stops.readForUid(uid)) {
      if (event.state == RouteStopOutboxState.needsAttention) continue;
      final HeldRoute route = HeldWorkPolicy.routeForStopEvent(
        lifecycle,
        sessionStartedAt: event.sessionStartedAtForHeldWork,
        now: now,
      );
      if (route != HeldRoute.endpoint) continue;
      final _Pending entry = _Pending(
        <String, Object?>{
          'kind': 'stop_event',
          'id': event.eventId,
          'workSessionId': event.workSessionId,
          'workSessionGeneration': event.workSessionGeneration,
          'deviceAt': event.deviceOccurredAt.toUtc().toIso8601String(),
          'planId': event.planId,
          'stopId': event.stopId,
          'status': event.status,
          'sessionEventSequence': event.sessionEventSequence,
          'payload': event.payload,
        },
        event.workSessionId,
        event.workSessionGeneration,
        event.sessionStartedAtForHeldWork,
        stop: event,
      );
      queue.add(entry);
    }

    final List<HeldOrder> storedOrders = await _orders.readAll(uid);
    final List<HeldOrder> toReconcile = storedOrders
        .where(
          (HeldOrder order) =>
              order.state == HeldOrderState.pending && order.storedAs == null,
        )
        .toList(growable: false);
    final Map<String, HeldOrder?> settledById = <String, HeldOrder?>{};
    for (int start = 0; start < toReconcile.length; start += _reconcileBatch) {
      final List<HeldOrder> batch = toReconcile.sublist(
        start,
        start + _reconcileBatch > toReconcile.length
            ? toReconcile.length
            : start + _reconcileBatch,
      );
      final List<(HeldOrder?, bool)> settled = await Future.wait(
        batch.map((HeldOrder order) => _reconcile(order, lifecycle)),
      );
      for (int index = 0; index < batch.length; index++) {
        settledById[batch[index].orderId] = settled[index].$1;
        if (settled[index].$2) removed++;
      }
    }

    for (HeldOrder order in storedOrders) {
      if (order.state == HeldOrderState.needsAttention) continue;
      if (order.storedAs != null) {
        if (await _settleTracking(order, lifecycle)) {
          await _orders.remove(order.uid, order.orderId);
          removed++;
        }
        continue;
      }
      if (order.state == HeldOrderState.pending) {
        final HeldOrder? settled = settledById[order.orderId];
        if (settled == null) continue;
        order = settled;
      }
      final HeldRoute route = HeldWorkPolicy.routeForOrder(
        lifecycle,
        sessionStartedAt: order.sessionStartedAt,
        deviceAt: order.deviceAt,
        now: now,
      );
      if (route == HeldRoute.direct) {
        if (await _writeOrderDirectly(order, lifecycle)) removed++;
        continue;
      }
      if (route != HeldRoute.endpoint) continue;
      final HeldOrder current = order;
      final _Pending entry = _Pending(
        <String, Object?>{
          'kind': 'order',
          'id': current.orderId,
          'workSessionId': current.workSessionId,
          'workSessionGeneration': current.workSessionGeneration,
          'deviceAt': current.deviceAt.toUtc().toIso8601String(),
          'payload': current.payload,
        },
        current.workSessionId,
        current.workSessionGeneration,
        current.sessionStartedAt,
        order: current,
      );
      queue.add(entry);
    }

    final DateTime? pausedUntil = _pausedUntil;
    if (pausedUntil != null && now.isBefore(pausedUntil)) {
      return removed + await _clearDelivered(storedOrders, lifecycle);
    }
    final List<_Pending> failedBefore = queue
        .where(_hadServerError)
        .toList(growable: false);
    final _FlushBudget budget = _FlushBudget();
    for (final List<_Pending> chunk in _chunks(
      queue.where((_Pending e) => !_hadServerError(e)).toList(),
    )) {
      if (budget.spent) break;
      removed += await _send(uid, chunk, lifecycle, budget);
    }
    final int turn = failedBefore.isEmpty
        ? 0
        : _failedTurn % failedBefore.length;
    int tried = 0;
    for (final _Pending entry in <_Pending>[
      ...failedBefore.sublist(turn),
      ...failedBefore.sublist(0, turn),
    ]) {
      if (budget.spent) break;
      tried++;
      removed += await _send(uid, <_Pending>[entry], lifecycle, budget);
    }
    _failedTurn = turn + tried;
    return removed + await _clearDelivered(storedOrders, lifecycle);
  }

  static bool _hadServerError(_Pending entry) =>
      entry.order?.lastError == _serverErrorMessage;

  static List<List<_Pending>> _chunks(List<_Pending> queue) {
    final List<List<_Pending>> chunks = <List<_Pending>>[];
    List<_Pending> current = <_Pending>[];
    int bytes = 0;
    for (final _Pending entry in queue) {
      final int size = utf8.encode(jsonEncode(entry.item)).length;
      if (current.isNotEmpty &&
          (current.length >= _itemsPerRequest ||
              bytes + size > _bytesPerRequest)) {
        chunks.add(current);
        current = <_Pending>[];
        bytes = 0;
      }
      current.add(entry);
      bytes += size;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  Future<int> _isolateServerError(
    String uid,
    List<_Pending> chunk,
    CompanyLifecycle lifecycle,
    _FlushBudget budget,
  ) async {
    if (chunk.length == 1) {
      return _noteItem(uid, chunk.single, _serverErrorMessage);
    }
    if (budget.spent) return 0;
    int sent = await _send(uid, chunk.sublist(0, 1), lifecycle, budget);
    final List<_Pending> rest = chunk.sublist(1);
    if (budget.spent) return sent;
    if (budget.failures > 0) {
      return sent + await _send(uid, rest, lifecycle, budget);
    }
    final int middle = (rest.length + 1) ~/ 2;
    for (final List<_Pending> half in <List<_Pending>>[
      rest.sublist(0, middle),
      rest.sublist(middle),
    ]) {
      if (half.isEmpty || budget.spent) continue;
      sent += await _send(uid, half, lifecycle, budget);
    }
    return sent;
  }

  Future<int> _send(
    String uid,
    List<_Pending> chunk,
    CompanyLifecycle lifecycle,
    _FlushBudget budget,
  ) async {
    final Map<String, _Pending> byId = <String, _Pending>{
      for (final _Pending entry in chunk) entry.item['id']! as String: entry,
    };
    final Map<String, Map<String, Object?>> sessions =
        <String, Map<String, Object?>>{};
    for (final _Pending entry in chunk) {
      sessions.putIfAbsent(
        entry.sessionId,
        () => <String, Object?>{
          'kind': 'session_start',
          'id': entry.sessionId,
          'workSessionId': entry.sessionId,
          'workSessionGeneration': entry.generation,
          'deviceAt': entry.startedAt.toUtc().toIso8601String(),
        },
      );
    }
    if (!_signedInAs(uid)) {
      budget.stopped = true;
      return 0;
    }
    final List<HeldWorkResult>? results;
    budget.requests++;
    try {
      results = await _api.submitHeldWork(<Map<String, Object?>>[
        ...sessions.values,
        for (final _Pending entry in chunk) entry.item,
      ]);
    } on HeldWorkRefusal catch (refusal) {
      if (refusal.serverError) {
        budget.failures++;
        return _isolateServerError(uid, chunk, lifecycle, budget);
      }
      if (refusal.timedOut) {
        return chunk.length == 1
            ? _noteItem(uid, chunk.single, _slowMessage)
            : _sendSmaller(uid, chunk, lifecycle, budget);
      }
      if (!refusal.tooLarge) {
        _pausedUntil = DateTime.now().toUtc().add(refusal.retryAfter!);
        budget.stopped = true;
        return 0;
      }
      return _sendSmaller(uid, chunk, lifecycle, budget);
    }
    if (results == null) {
      budget.stopped = true;
      return 0;
    }
    budget.failures = 0;
    final List<RouteStopLifecycleEvent> stopRemovals =
        <RouteStopLifecycleEvent>[];
    final List<RouteStopLifecycleEvent> stopUpdates =
        <RouteStopLifecycleEvent>[];
    final List<String> orderRemovals = <String>[];
    final Map<String, String> storedAs = <String, String>{};
    final List<HeldOrder> orderUpdates = <HeldOrder>[];
    final List<HeldOrder> directWrites = <HeldOrder>[];
    for (final HeldWorkResult result in results) {
      final _Pending? entry = byId[result.id];
      if (entry == null) continue;
      final RouteStopLifecycleEvent? stop = entry.stop;
      final HeldOrder? order = entry.order;
      switch (result.outcome) {
        case 'accepted' || 'duplicate':
          if (stop != null) stopRemovals.add(stop);
          if (order != null) {
            orderRemovals.add(order.orderId);
            storedAs[order.orderId] = result.storedAs ?? order.orderId;
          }
        case 'rejected' when result.reason == 'not_paused':
          if (stop != null) {
            stopUpdates.add(
              stop.copyWith(state: RouteStopOutboxState.pending, lastError: ''),
            );
          }
          if (order != null) directWrites.add(order);
        case 'rejected':
          final String message = HeldWorkPolicy.rejectionText(
            result.reason ?? 'invalid',
            companyOpen: lifecycle.isOpen,
          );
          if (stop != null) {
            stopUpdates.add(
              stop.copyWith(
                state: RouteStopOutboxState.needsAttention,
                lastError: message,
              ),
            );
          }
          if (order != null) {
            orderUpdates.add(
              order.copyWith(
                state: HeldOrderState.needsAttention,
                lastError: message,
              ),
            );
          }
      }
    }
    int removed = 0;
    if (stopRemovals.isNotEmpty) {
      await _stops.removeAll(stopRemovals);
      removed += stopRemovals.length;
    }
    final List<String> settledOrders = <String>[];
    for (final String orderId in orderRemovals) {
      final HeldOrder? held = byId[orderId]?.order;
      if (held == null) {
        settledOrders.add(orderId);
        continue;
      }
      final HeldOrder sent = held.copyWith(storedAs: storedAs[orderId]);
      if (sent.tracking != null) await _orders.update(sent);
      if (await _settleTracking(sent, lifecycle)) settledOrders.add(orderId);
    }
    if (settledOrders.isNotEmpty) {
      await _orders.removeAll(uid, settledOrders);
      removed += settledOrders.length;
    }
    if (stopUpdates.isNotEmpty) await _stops.updateAll(stopUpdates);
    if (orderUpdates.isNotEmpty) await _orders.updateAll(uid, orderUpdates);
    for (final HeldOrder order in directWrites) {
      if (await _writeOrderDirectly(order, lifecycle)) removed++;
    }
    return removed;
  }

  static const String _slowMessage =
      'The connection was too slow to send this item. It will be sent again.';
  static const String _serverErrorMessage =
      'The server could not save this item just now. Nothing was lost. It will be sent again.';

  Future<int> _noteItem(String uid, _Pending entry, String message) async {
    final RouteStopLifecycleEvent? stop = entry.stop;
    final HeldOrder? order = entry.order;
    if (stop != null) {
      await _stops.updateAll(<RouteStopLifecycleEvent>[
        stop.copyWith(lastError: message),
      ]);
    }
    if (order != null) {
      await _orders.updateAll(uid, <HeldOrder>[
        order.copyWith(lastError: message),
      ]);
    }
    return 0;
  }

  Future<int> _sendSmaller(
    String uid,
    List<_Pending> chunk,
    CompanyLifecycle lifecycle,
    _FlushBudget budget,
  ) async {
    if (chunk.length == 1) {
      final _Pending entry = chunk.single;
      final String message = HeldWorkPolicy.rejectionText(
        'too_large',
        companyOpen: lifecycle.isOpen,
      );
      final RouteStopLifecycleEvent? stop = entry.stop;
      final HeldOrder? order = entry.order;
      if (stop != null) {
        await _stops.updateAll(<RouteStopLifecycleEvent>[
          stop.copyWith(
            state: RouteStopOutboxState.needsAttention,
            lastError: message,
          ),
        ]);
      }
      if (order != null) {
        await _orders.updateAll(uid, <HeldOrder>[
          order.copyWith(
            state: HeldOrderState.needsAttention,
            lastError: message,
          ),
        ]);
      }
      return 0;
    }
    final int middle = chunk.length ~/ 2;
    final int first = await _send(
      uid,
      chunk.sublist(0, middle),
      lifecycle,
      budget,
    );
    if (budget.stopped) return first;
    return first + await _send(uid, chunk.sublist(middle), lifecycle, budget);
  }

  Future<(HeldOrder?, bool)> _reconcile(
    HeldOrder order,
    CompanyLifecycle lifecycle,
  ) async {
    final bool? stored = await _alreadyStored(order);
    if (stored == null) return (null, false);
    if (stored) return (null, await _settleStored(order, lifecycle));
    if ((await _cachedOrder(order))?.metadata.hasPendingWrites ?? false) {
      return (null, false);
    }
    final HeldOrder held = order.copyWith(state: HeldOrderState.held);
    await _orders.update(held);
    return (held, false);
  }

  Future<bool?> _alreadyStored(HeldOrder order) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> server = await _db
          .collection('orders')
          .doc(order.orderId)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      return server.exists && server.data()?['salesmanUid'] == order.uid;
    } on FirebaseException catch (error) {
      return error.code == 'permission-denied' ? false : null;
    } catch (_) {
      return null;
    }
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _cachedOrder(
    HeldOrder order,
  ) async {
    try {
      return await _db
          .collection('orders')
          .doc(order.orderId)
          .get(const GetOptions(source: Source.cache));
    } catch (_) {
      return null;
    }
  }

  Future<bool> _settleStored(
    HeldOrder order,
    CompanyLifecycle lifecycle,
  ) async {
    if (!await _settleTracking(order, lifecycle)) return false;
    await _orders.remove(order.uid, order.orderId);
    return true;
  }

  Future<int> _clearDelivered(
    List<HeldOrder> rows,
    CompanyLifecycle lifecycle,
  ) async {
    int removed = 0;
    for (final HeldOrder order in rows) {
      if (order.state != HeldOrderState.needsAttention ||
          order.storedAs != null ||
          order.trackingAttempts >= _maxTrackingAttempts) {
        continue;
      }
      final String key = '${order.uid}|${order.orderId}';
      if (_notOnServer.contains(key)) continue;
      if (!_signedInAs(order.uid)) break;
      final bool? stored = await _alreadyStored(order);
      if (stored == null) break;
      if (!stored) {
        _notOnServer.add(key);
        continue;
      }
      final HeldOrder delivered = order.copyWith(
        state: HeldOrderState.pending,
        lastError: '',
      );
      if (delivered.tracking != null) await _orders.update(delivered);
      if (await _settleStored(delivered, lifecycle)) removed++;
    }
    return removed;
  }

  Future<void> forgetStoredOrders(
    String uid,
    CompanyLifecycle lifecycle,
  ) async {
    if (!_signedInAs(uid)) return;
    final List<HeldOrder> rows = await _orders.readAll(uid);
    for (final HeldOrder order in rows) {
      if (order.state != HeldOrderState.pending || order.storedAs != null) {
        continue;
      }
      final DocumentSnapshot<Map<String, dynamic>>? cached = await _cachedOrder(
        order,
      );
      if (cached == null ||
          !cached.exists ||
          cached.metadata.hasPendingWrites) {
        continue;
      }
      if (await _alreadyStored(order) ?? false) {
        await _settleStored(order, lifecycle);
      }
    }
    await _clearDelivered(rows, lifecycle);
  }

  Future<bool> _writeOrderDirectly(
    HeldOrder order,
    CompanyLifecycle lifecycle,
  ) async {
    if (!_signedInAs(order.uid)) return false;
    if (await _alreadyStored(order) ?? false) {
      return _settleStored(order, lifecycle);
    }
    if ((await _cachedOrder(order))?.metadata.hasPendingWrites ?? false) {
      return false;
    }
    try {
      final Future<void> Function(HeldOrder order)? writer = _orderWriter;
      if (writer != null) {
        await writer(order);
      } else {
        await _db
            .collection('orders')
            .doc(order.orderId)
            .set(<String, dynamic>{
              ..._restoredOrderPayload(order.payload),
              'submittedAt': FieldValue.serverTimestamp(),
              'createdAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            })
            .timeout(const Duration(seconds: 10));
      }
      if (await _settleTracking(order, lifecycle)) {
        await _orders.remove(order.uid, order.orderId);
        return true;
      } else {
        final List<HeldOrder> rows = await _orders.readAll(order.uid);
        for (final HeldOrder row in rows) {
          if (row.orderId == order.orderId &&
              row.state == HeldOrderState.held) {
            await _orders.update(row.copyWith(state: HeldOrderState.pending));
          }
        }
        return false;
      }
    } on FirebaseException catch (error) {
      if (error.code == 'unavailable' || error.code == 'deadline-exceeded') {
        return false;
      }
      if (HeldWorkPolicy.classify(error, lifecycle.access) ==
          WriteFailure.held) {
        return false;
      }
      final bool? stored = error.code == 'permission-denied'
          ? await _alreadyStored(order)
          : false;
      if (stored == null) return false;
      if (stored) return _settleStored(order, lifecycle);
      await _orders.update(
        order.copyWith(
          state: HeldOrderState.needsAttention,
          lastError:
              'The server refused this order. Sending it again will not help. Record the order again, then remove this one.',
        ),
      );
      return false;
    } on TimeoutException {
      return false;
    }
  }

  static Map<String, dynamic> _restoredOrderPayload(
    Map<String, dynamic> payload,
  ) {
    final Map<String, dynamic> data = _restoredLocation(payload);
    if (data['location'] is GeoPoint) {
      data['locationCapturedAt'] = FieldValue.serverTimestamp();
    }
    return data;
  }

  static Map<String, dynamic> _restoredLocation(Map<String, dynamic> source) {
    final Map<String, dynamic> data = Map<String, dynamic>.from(source);
    final Object? location = data['location'];
    if (location is Map) {
      data['location'] = GeoPoint(
        (location['latitude'] as num).toDouble(),
        (location['longitude'] as num).toDouble(),
      );
    }
    _restoreTimestamp(data, 'deviceCapturedAt');
    final Object? evidence = data['locationEvidence'];
    if (evidence is Map) {
      final Map<String, dynamic> restored = Map<String, dynamic>.from(evidence);
      _restoreTimestamp(restored, 'deviceCapturedAt');
      data['locationEvidence'] = restored;
    }
    return data;
  }

  static const int _maxTrackingAttempts = 5;

  Future<bool> _settleTracking(
    HeldOrder order,
    CompanyLifecycle lifecycle,
  ) async {
    final Map<String, dynamic>? tracking = order.tracking;
    if (tracking == null) return true;
    final DateTime? retryAfter = order.trackingRetryAfter;
    if (retryAfter != null && DateTime.now().toUtc().isBefore(retryAfter)) {
      return false;
    }
    final String trackedId = order.storedAs ?? order.orderId;
    final DocumentReference<Map<String, dynamic>> reference = _db
        .collection('gps_tracking')
        .doc('order_$trackedId');
    try {
      final DocumentSnapshot<Map<String, dynamic>> existing = await reference
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      if (existing.exists) return true;
    } catch (_) {}
    final Map<String, dynamic> record = _restoredLocation(tracking);
    for (final String key in const <String>['lastOrderId', 'orderId']) {
      if (record.containsKey(key)) record[key] = trackedId;
    }
    try {
      await reference
          .set(<String, dynamic>{
            ...record,
            'locationCapturedAt': FieldValue.serverTimestamp(),
            'timestamp': FieldValue.serverTimestamp(),
            'lastSeen': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .timeout(const Duration(seconds: 10));
      return true;
    } on TimeoutException {
      await _backOffTracking(order);
      return false;
    } on FirebaseException catch (error) {
      if (error.code == 'unavailable' || error.code == 'deadline-exceeded') {
        await _backOffTracking(order);
        return false;
      }
      if (HeldWorkPolicy.classify(error, lifecycle.access) ==
          WriteFailure.held) {
        await _orders.update(
          order.copyWith(
            lastError:
                'The order was sent. Its location record will be sent when the company is open again.',
          ),
        );
        return false;
      }
      final int attempts = order.trackingAttempts + 1;
      final bool exhausted = attempts >= _maxTrackingAttempts;
      await _orders.update(
        order.copyWith(
          trackingAttempts: attempts,
          state: exhausted ? HeldOrderState.needsAttention : null,
          lastError: exhausted
              ? 'The order was sent, but the server refused its location record (${error.code}). Ask your manager to review it.'
              : 'The order was sent, but its location record was refused (${error.code}). It will be tried again.',
        ),
      );
      return false;
    }
  }

  static const Duration _firstTrackingBackoff = Duration(minutes: 1);
  static const Duration _longestTrackingBackoff = Duration(minutes: 30);

  Future<void> _backOffTracking(HeldOrder order) {
    final int failures = order.trackingTransientFailures + 1;
    final int minutes =
        _firstTrackingBackoff.inMinutes << (failures - 1).clamp(0, 10);
    final Duration wait = minutes >= _longestTrackingBackoff.inMinutes
        ? _longestTrackingBackoff
        : Duration(minutes: minutes);
    return _orders.update(
      order.copyWith(
        trackingTransientFailures: failures,
        trackingRetryAfter: DateTime.now().toUtc().add(wait),
      ),
    );
  }

  static void _restoreTimestamp(Map<String, dynamic> data, String key) {
    final Object? raw = data[key];
    if (raw is String) {
      final DateTime? parsed = DateTime.tryParse(raw);
      if (parsed != null) data[key] = Timestamp.fromDate(parsed);
    }
  }
}
