import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/route_stop_lifecycle_event.dart';
import '../models/offline_operation.dart';
import '../utils/assigned_route_lifecycle.dart';
import 'company_lifecycle_monitor.dart';
import 'held_order_outbox.dart';
import 'project_local_store.dart';
import 'route_stop_outbox.dart';
import 'sales_visit_copilot_service.dart';

enum StuckWorkKind { stopEvent, order, outcome, visit }

class StuckWorkItem {
  const StuckWorkItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.reason,
    required this.removeWarning,
    this.planId = '',
  });

  final StuckWorkKind kind;
  final String id;
  final String title;
  final String reason;
  final String removeWarning;
  final String planId;
}

class StuckWork {
  StuckWork({
    required String projectId,
    required SalesVisitCopilotService outcomes,
    FirebaseFirestore? firestore,
  }) : _stops = RouteStopOutbox(projectId: projectId),
       _orders = HeldOrderOutbox(projectId: projectId),
       _outcomes = outcomes,
       _firestore = firestore;

  final RouteStopOutbox _stops;
  final HeldOrderOutbox _orders;
  final SalesVisitCopilotService _outcomes;
  final FirebaseFirestore? _firestore;

  HeldVisits get _visits =>
      HeldVisits(firestore: _firestore ?? FirebaseFirestore.instance);

  Future<List<StuckWorkItem>> list(String uid) async {
    final List<RouteStopLifecycleEvent> stops = await _stops.readForUid(uid);
    final List<HeldOrder> orders = await _orders.readAll(uid);
    final List<Map<String, dynamic>> visits = await _visits.readAll(uid);
    return <StuckWorkItem>[
      for (final RouteStopLifecycleEvent event in stops)
        if (event.state == RouteStopOutboxState.needsAttention)
          StuckWorkItem(
            kind: StuckWorkKind.stopEvent,
            id: event.eventId,
            planId: event.planId,
            title: switch (event.status) {
              'arrived' => 'Arrival at a stop',
              'completed' => 'Stop completed',
              'skipped' => 'Stop skipped',
              _ => 'Stop update',
            },
            reason: _stopReason(event.lastError),
            removeWarning:
                'This update is deleted from the phone. The stop stays as it is on the server.',
          ),
      for (final HeldOrder order in orders)
        if (order.state == HeldOrderState.needsAttention)
          StuckWorkItem(
            kind: StuckWorkKind.order,
            id: order.orderId,
            title:
                'Order for ${(order.payload['retailerName'] ?? 'a retailer').toString().trim()}',
            reason: order.lastError,
            removeWarning: order.storedAs == null
                ? 'The order is deleted from the phone. Your company has not received it.'
                : 'Your company already has the order. Only its location record is deleted from the phone.',
          ),
      for (final OfflineOperation row in _outcomes.stuckOutcomes)
        StuckWorkItem(
          kind: StuckWorkKind.outcome,
          id: row.operationId,
          title:
              'Visit result for ${(row.payload['retailerName'] ?? 'a retailer').toString().trim()}',
          reason: row.lastError,
          removeWarning:
              'The visit result is deleted from the phone. Your company has not received it.',
        ),
      for (final Map<String, dynamic> row in visits)
        StuckWorkItem(
          kind: StuckWorkKind.visit,
          id: row['docId'] as String,
          title:
              'Planned visit to ${((row['fields'] as Map?)?['marketplace'] ?? 'a retailer').toString().trim()}',
          reason: (row['reason'] ?? '').toString(),
          removeWarning:
              'The planned visit is deleted from the phone. Your company has not received it.',
        ),
    ];
  }

  static String _stopReason(String lastError) {
    final String message = stopAttentionMessage(lastError);
    return message.contains('Sync needs attention') &&
            lastError.trim().isNotEmpty
        ? lastError.trim()
        : message;
  }

  Future<bool> stillHeld(String uid, StuckWorkItem item) async =>
      switch (item.kind) {
        StuckWorkKind.stopEvent => (await _stops.readForUid(
          uid,
        )).any((RouteStopLifecycleEvent event) => event.eventId == item.id),
        StuckWorkKind.order => (await _orders.readAll(
          uid,
        )).any((HeldOrder order) => order.orderId == item.id),
        StuckWorkKind.outcome => _outcomes.isHeld(item.id),
        StuckWorkKind.visit => (await _visits.readAll(
          uid,
        )).any((Map<String, dynamic> row) => row['docId'] == item.id),
      };

  Future<void> remove(String uid, StuckWorkItem item) async {
    switch (item.kind) {
      case StuckWorkKind.stopEvent:
        for (final RouteStopLifecycleEvent event in await _stops.readForUid(
          uid,
        )) {
          if (event.eventId == item.id &&
              event.state == RouteStopOutboxState.needsAttention) {
            await _stops.remove(event);
          }
        }
      case StuckWorkKind.order:
        for (final HeldOrder order in await _orders.readAll(uid)) {
          if (order.orderId == item.id &&
              order.state == HeldOrderState.needsAttention) {
            await _orders.remove(uid, item.id);
          }
        }
      case StuckWorkKind.outcome:
        await _outcomes.discardOutcome(item.id);
      case StuckWorkKind.visit:
        await _visits.remove(uid, item.id);
    }
  }

  Future<void> sendAgain(String uid, StuckWorkItem item) async {
    switch (item.kind) {
      case StuckWorkKind.stopEvent:
        break;
      case StuckWorkKind.order:
        for (final HeldOrder order in await _orders.readAll(uid)) {
          if (order.orderId == item.id) {
            await _orders.update(
              order.copyWith(
                state: HeldOrderState.pending,
                lastError: '',
                trackingAttempts: 0,
              ),
            );
          }
        }
      case StuckWorkKind.outcome:
        await _outcomes.resendOutcome(item.id);
      case StuckWorkKind.visit:
        await _visits.sendAgain(uid, item.id);
    }
  }
}

class HeldVisits {
  HeldVisits({required FirebaseFirestore firestore})
    : _db = firestore,
      _store = ProjectLocalStore(projectId: firestore.app.options.projectId);

  final FirebaseFirestore _db;
  final ProjectLocalStore _store;
  static const String _name = 'refused_visits';
  static const String _sentName = 'sent_visits';
  static const Duration offlineWait = Duration(seconds: 5);

  Future<bool> save(
    String uid, {
    required String docId,
    required Map<String, Object?> fields,
    required bool update,
    Duration wait = offlineWait,
  }) async {
    final DocumentReference<Map<String, dynamic>> doc = _db
        .collection('visits')
        .doc(docId);
    await _change(
      uid,
      (List<Map<String, dynamic>> rows) =>
          _merge(rows, docId, fields, update, const <String, dynamic>{}),
      name: _sentName,
    );
    final Future<void> sent = update
        ? doc.update(<String, Object?>{
            ...fields,
            'updatedAt': FieldValue.serverTimestamp(),
          })
        : doc.set(<String, Object?>{
            ...fields,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
    try {
      await sent.timeout(wait);
      await remove(uid, docId);
      return false;
    } on TimeoutException {
      unawaited(
        sent.then(
          (_) => remove(uid, docId),
          onError: (Object error) =>
              _keep(uid, docId, fields, update, _reason(error)),
        ),
      );
      return true;
    } catch (_) {
      await _forgetSent(uid, docId);
      rethrow;
    }
  }

  Future<void> settle(String uid) async {
    final List<Map<String, dynamic>> sent = await _read(uid, _sentName);
    if (sent.isEmpty) return;
    try {
      await _db.waitForPendingWrites().timeout(offlineWait);
    } catch (_) {
      return;
    }
    for (final Map<String, dynamic> row in sent) {
      final String docId = row['docId'] as String;
      final Map<String, Object?> fields = Map<String, Object?>.from(
        row['fields'] as Map? ?? const <String, Object?>{},
      );
      Map<String, dynamic>? stored;
      try {
        stored = (await _db
                .collection('visits')
                .doc(docId)
                .get(const GetOptions(source: Source.server)))
            .data();
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied' && error.code != 'not-found') {
          continue;
        }
      } catch (_) {
        continue;
      }
      final Map<String, dynamic>? server = stored;
      final bool landed =
          server != null &&
          fields.entries.every(
            (MapEntry<String, Object?> field) =>
                jsonEncode(server[field.key]) == jsonEncode(field.value),
          );
      if (landed) {
        await _forgetSent(uid, docId);
      } else {
        await _keep(
          uid,
          docId,
          fields,
          row['update'] == true,
          _refusedReason(),
          refresh: false,
        );
      }
    }
  }

  Future<void> sendAgain(String uid, String docId) async {
    final Map<String, dynamic>? row = (await readAll(
      uid,
    )).where((Map<String, dynamic> row) => row['docId'] == docId).firstOrNull;
    if (row == null) return;
    final Map<String, Object?> fields = Map<String, Object?>.from(
      row['fields'] as Map? ?? const <String, Object?>{},
    );
    final bool update = row['update'] == true;
    try {
      await save(uid, docId: docId, fields: fields, update: update);
    } catch (error) {
      await _keep(uid, docId, fields, update, _reason(error));
      rethrow;
    }
  }

  static String _reason(Object error) {
    if (error is FirebaseException && error.code == 'permission-denied') {
      return _refusedReason();
    }
    return 'This visit could not be sent. It is kept on this phone. Tap Send again.';
  }

  static String _refusedReason() =>
      CompanyLifecycleMonitor.instance.lifecycle?.isOpen == false
      ? 'The company was paused before this visit reached the server, so it was not saved. It is kept on this phone. When the company is active again, tap Send again.'
      : 'The server did not accept this visit. It is kept on this phone. Tap Send again. If it is refused again, ask your manager to check your account.';

  Future<List<Map<String, dynamic>>> readAll(String uid) => _read(uid, _name);

  Future<List<Map<String, dynamic>>> _read(String uid, String name) async {
    try {
      final String? encoded = await _store.read(uid, name);
      if (encoded == null || encoded.isEmpty) return <Map<String, dynamic>>[];
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return <Map<String, dynamic>>[
        for (final Object? row in decoded)
          if (row is Map && row['docId'] is String)
            Map<String, dynamic>.from(row),
      ];
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> remove(String uid, String docId) async {
    await _forgetSent(uid, docId);
    await _change(
      uid,
      (List<Map<String, dynamic>> rows) =>
          rows.removeWhere((Map<String, dynamic> row) => row['docId'] == docId),
    );
  }

  Future<void> _forgetSent(String uid, String docId) => _change(
    uid,
    (List<Map<String, dynamic>> rows) =>
        rows.removeWhere((Map<String, dynamic> row) => row['docId'] == docId),
    name: _sentName,
  );

  Future<void> _keep(
    String uid,
    String docId,
    Map<String, Object?> fields,
    bool update,
    String reason, {
    bool refresh = true,
  }) async {
    await _change(
      uid,
      (List<Map<String, dynamic>> rows) => _merge(
        rows,
        docId,
        fields,
        update,
        <String, dynamic>{'reason': reason},
      ),
    );
    await _forgetSent(uid, docId);
    if (refresh) unawaited(CompanyLifecycleMonitor.instance.refresh());
  }

  static void _merge(
    List<Map<String, dynamic>> rows,
    String docId,
    Map<String, Object?> fields,
    bool update,
    Map<String, dynamic> extra,
  ) {
    final Map<String, dynamic>? held = rows
        .where((Map<String, dynamic> row) => row['docId'] == docId)
        .firstOrNull;
    final Map<String, Object?> heldFields = Map<String, Object?>.from(
      held?['fields'] as Map? ?? const <String, Object?>{},
    );
    final bool heldIsEdit = held == null || held['update'] == true;
    rows.removeWhere((Map<String, dynamic> row) => row['docId'] == docId);
    rows.add(<String, dynamic>{
      'docId': docId,
      'fields': update || !heldIsEdit
          ? <String, Object?>{...heldFields, ...fields}
          : <String, Object?>{...fields, ...heldFields},
      'update': update && heldIsEdit,
      ...extra,
    });
  }

  Future<void> _change(
    String uid,
    void Function(List<Map<String, dynamic>> rows) change, {
    String name = _name,
  }) => ProjectLocalStore.locked(
    'held_visits:${_store.key(uid, name)}',
    () async {
      final List<Map<String, dynamic>> rows = await _read(uid, name);
      final int before = rows.length;
      change(rows);
      if (rows.length == before && before == 0) return;
      await _store.write(uid, name, jsonEncode(rows));
    },
  );
}
