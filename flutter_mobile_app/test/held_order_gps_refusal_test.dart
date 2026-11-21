// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/screens/profile_screen.dart' show confirmSignOut;
import 'package:fmcg_sales/models/company_lifecycle.dart';
import 'package:fmcg_sales/models/offline_operation.dart';
import 'package:fmcg_sales/models/route_stop_lifecycle_event.dart';
import 'package:fmcg_sales/services/company_api.dart';
import 'package:fmcg_sales/services/company_lifecycle_monitor.dart';
import 'package:fmcg_sales/services/held_order_outbox.dart';
import 'package:fmcg_sales/services/held_work.dart';
import 'package:fmcg_sales/services/held_work_sync.dart';
import 'package:fmcg_sales/services/project_local_store.dart';
import 'package:fmcg_sales/services/route_stop_outbox.dart';
import 'package:fmcg_sales/services/sales_visit_copilot_service.dart';
import 'package:fmcg_sales/services/stuck_work.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

class FakeDb implements FirebaseFirestore {
  final Map<String, Map<String, dynamic>> docs =
      <String, Map<String, dynamic>>{};
  final List<String> sets = <String>[];
  final List<String> serverGets = <String>[];
  final Set<String> queued = <String>{};
  String? Function(String path) setError = (_) => null;
  String? Function(String path) serverGetError = (_) => null;
  Future<void>? offline;
  Future<void> Function()? pendingWrites;
  @override
  FirebaseApp get app => Firebase.app();
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      FakeCol(this, path);
  @override
  Future<void> waitForPendingWrites() =>
      pendingWrites?.call() ?? Future<void>.value();
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('db ${i.memberName}');
}

class FakeCol implements CollectionReference<Map<String, dynamic>> {
  FakeCol(this.db, this.path);
  final FakeDb db;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      FakeDoc(db, '$path/$id');
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('col ${i.memberName}');
}

class FakeDoc implements DocumentReference<Map<String, dynamic>> {
  FakeDoc(this.db, this.path);
  final FakeDb db;
  @override
  final String path;
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    if (options?.source == Source.server) {
      db.serverGets.add(path);
      final String? code = db.serverGetError(path);
      if (code != null) {
        throw FirebaseException(plugin: 'cloud_firestore', code: code);
      }
    }
    return FakeSnap(
      db.docs.containsKey(path),
      db.docs[path],
      db.queued.contains(path),
    );
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    db.sets.add(path);
    await db.offline;
    final String? code = db.setError(path);
    if (code != null) {
      throw FirebaseException(plugin: 'cloud_firestore', code: code);
    }
    db.docs[path] = data;
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    await db.offline;
    final String? code = db.setError(path);
    if (code != null) {
      throw FirebaseException(plugin: 'cloud_firestore', code: code);
    }
    final Map<String, dynamic>? stored = db.docs[path];
    if (stored == null) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'not-found');
    }
    stored.addAll(<String, dynamic>{
      for (final MapEntry<Object, Object?> entry in data.entries)
        entry.key.toString(): entry.value,
    });
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('doc ${i.memberName}');
}

class FakeMeta implements SnapshotMetadata {
  FakeMeta(this.hasPendingWrites);
  @override
  final bool hasPendingWrites;
  @override
  bool get isFromCache => true;
}

class FakeSnap implements DocumentSnapshot<Map<String, dynamic>> {
  FakeSnap(this.exists, [this.stored, this.queued = false]);
  final Map<String, dynamic>? stored;
  final bool queued;
  @override
  final bool exists;
  @override
  Map<String, dynamic>? data() => stored;
  @override
  SnapshotMetadata get metadata => FakeMeta(queued);
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('snap ${i.memberName}');
}

HeldOrder heldOrder(String id, {bool withTracking = true}) => HeldOrder(
  orderId: id,
  uid: 'u1',
  workSessionId: 'w',
  workSessionGeneration: 1,
  sessionStartedAt: DateTime.utc(2026, 1, 1),
  deviceAt: DateTime.utc(2026, 1, 1),
  payload: <String, dynamic>{
    'orderId': id,
    'salesmanUid': 'u1',
    'locationEvidence': <String, dynamic>{
      'mode': 'device_captured',
      'deviceCapturedAt': '2026-01-01T00:00:00.000Z',
    },
  },
  state: HeldOrderState.held,
  tracking: withTracking
      ? <String, dynamic>{
          'lastOrderId': id,
          'location': <String, double>{'latitude': 1.55, 'longitude': 110.35},
          'latitude': 1.55,
          'longitude': 110.35,
          'deviceCapturedAt': '2026-01-01T00:00:00.000Z',
        }
      : null,
);

class FakeApi extends CompanyApi {
  final Set<String> seen = <String>{};
  int calls = 0;
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    calls++;
    return <HeldWorkResult>[
      for (final Map<String, Object?> item in items)
        if (item['kind'] == 'order')
          HeldWorkResult(
            id: item['id']! as String,
            outcome: seen.add(item['id']! as String) ? 'accepted' : 'duplicate',
          ),
    ];
  }
}

class SizeLimitedApi extends CompanyApi {
  SizeLimitedApi(this.maxOrders, {this.neverFits = const <String>{}});
  final int maxOrders;
  final Set<String> neverFits;
  final List<int> requestSizes = <int>[];
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    final List<Map<String, Object?>> orders = items
        .where((Map<String, Object?> item) => item['kind'] == 'order')
        .toList();
    requestSizes.add(orders.length);
    if (orders.length > maxOrders ||
        orders.any(
          (Map<String, Object?> item) => neverFits.contains(item['id']),
        )) {
      throw const HeldWorkRefusal.tooLarge();
    }
    return <HeldWorkResult>[
      for (final Map<String, Object?> item in orders)
        HeldWorkResult(id: item['id']! as String, outcome: 'accepted'),
    ];
  }
}

class StoredAsApi extends CompanyApi {
  StoredAsApi(this.storedAs);
  final String Function(String id) storedAs;
  final List<String> sent = <String>[];
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    final List<Map<String, Object?>> orders = items
        .where((Map<String, Object?> item) => item['kind'] == 'order')
        .toList();
    sent.addAll(
      orders.map((Map<String, Object?> item) => item['id']! as String),
    );
    return <HeldWorkResult>[
      for (final Map<String, Object?> item in orders)
        HeldWorkResult(
          id: item['id']! as String,
          outcome: 'accepted',
          storedAs: storedAs(item['id']! as String),
        ),
    ];
  }
}

class SlowLinkApi extends CompanyApi {
  SlowLinkApi(this.maxOrders);
  final int maxOrders;
  final List<int> requestSizes = <int>[];
  final List<int> requestBytes = <int>[];
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    final List<Map<String, Object?>> orders = items
        .where((Map<String, Object?> item) => item['kind'] == 'order')
        .toList();
    requestSizes.add(orders.length);
    requestBytes.add(utf8.encode(jsonEncode(items)).length);
    if (orders.length > maxOrders) throw const HeldWorkRefusal.timedOut();
    return <HeldWorkResult>[
      for (final Map<String, Object?> item in orders)
        HeldWorkResult(id: item['id']! as String, outcome: 'accepted'),
    ];
  }
}

class TimesOutForApi extends CompanyApi {
  TimesOutForApi(this.stuck);
  final String stuck;
  final List<String> sent = <String>[];
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    final List<Map<String, Object?>> orders = items
        .where((Map<String, Object?> item) => item['kind'] == 'order')
        .toList();
    if (orders.any((Map<String, Object?> item) => item['id'] == stuck)) {
      throw const HeldWorkRefusal.timedOut();
    }
    sent.addAll(
      orders.map((Map<String, Object?> item) => item['id']! as String),
    );
    return <HeldWorkResult>[
      for (final Map<String, Object?> item in orders)
        HeldWorkResult(id: item['id']! as String, outcome: 'accepted'),
    ];
  }
}

class SignedInUidApi extends CompanyApi {
  final List<String?> signedInUids = <String?>[];
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    signedInUids.add(FirebaseAuth.instance.currentUser?.uid);
    return <HeldWorkResult>[
      for (final Map<String, Object?> item in items)
        if (item['kind'] == 'order')
          HeldWorkResult(id: item['id']! as String, outcome: 'accepted'),
    ];
  }
}

class NeverPausedApi extends CompanyApi {
  @override
  bool get enabled => true;
  @override
  Future<CompanyLifecycle?> readLifecycle() async => open;
}

class BusyApi extends CompanyApi {
  int calls = 0;
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    calls++;
    throw const HeldWorkRefusal.tooMany(Duration(minutes: 5));
  }
}

const CompanyLifecycle open = CompanyLifecycle(state: 'active', access: 'open');

HeldOrder bigOrder(String id, int bytes) {
  final HeldOrder base = heldOrder(id, withTracking: false);
  return HeldOrder(
    orderId: id,
    uid: base.uid,
    workSessionId: base.workSessionId,
    workSessionGeneration: base.workSessionGeneration,
    sessionStartedAt: base.sessionStartedAt,
    deviceAt: base.deviceAt,
    payload: <String, dynamic>{...base.payload, 'remarks': 'r' * bytes},
    state: HeldOrderState.held,
  );
}

void main() {
  late FakeDb db;
  late HeldOrderOutbox outbox;

  setUpAll(installTestFirebase);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signInTestUser('u1');
    db = FakeDb();
    outbox = HeldOrderOutbox(projectId: testProjectId);
  });

  int gpsSets(String id) =>
      db.sets.where((p) => p == 'gps_tracking/order_$id').length;

  test(
    'a refusal while paused does not exhaust attempts; recovers after reactivation',
    () async {
      final FakeApi api = FakeApi();
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      final DateTime cut = DateTime.utc(2026, 1, 2);
      final CompanyLifecycle paused = CompanyLifecycle(
        state: 'suspended',
        access: 'read_only',
        cutAt: cut,
        drainUntil: DateTime.now().toUtc().add(const Duration(days: 7)),
      );
      await outbox.put(heldOrder('d1'));
      db.setError = (p) =>
          p.startsWith('gps_tracking') ? 'permission-denied' : null;
      for (int i = 1; i <= 7; i++) {
        await sync.flush('u1', paused);
      }
      final HeldOrder row = (await outbox.readAll('u1')).single;
      final HeldWorkCounts counts = await sync.counts('u1', paused);
      expect(row.state, isNot(HeldOrderState.needsAttention));
      expect(counts.rejected, 0);

      final CompanyLifecycle reopened = CompanyLifecycle(
        state: 'active',
        access: 'open',
        cutAt: cut,
        reactivatedAt: DateTime.now().toUtc(),
      );
      db.setError = (_) => null;
      await sync.flush('u1', reopened);
      expect(await outbox.readAll('u1'), isEmpty);
      expect(db.docs.containsKey('gps_tracking/order_d1'), isTrue);
    },
  );

  CompanyLifecycle reactivated() => CompanyLifecycle(
    state: 'active',
    access: 'open',
    cutAt: DateTime.utc(2026, 1, 2),
    reactivatedAt: DateTime.now().toUtc(),
  );

  CompanyLifecycle pausedWithDrain() => CompanyLifecycle(
    state: 'suspended',
    access: 'read_only',
    cutAt: DateTime.utc(2026, 1, 2),
    drainUntil: DateTime.now().toUtc().add(const Duration(days: 7)),
  );

  test('a request the server calls too large is split until it fits', () async {
    final SizeLimitedApi api = SizeLimitedApi(2);
    final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
    for (int i = 1; i <= 7; i++) {
      await outbox.put(heldOrder('s$i', withTracking: false));
    }
    final int removed = await sync.flush('u1', pausedWithDrain());
    expect(removed, 7);
    expect(await outbox.readAll('u1'), isEmpty);
    expect(api.requestSizes.first, 7);
    expect(
      api.requestSizes.where((int size) => size <= 2).length,
      greaterThan(3),
    );
  });

  test(
    'one item that never fits is reported and does not block the others',
    () async {
      final SizeLimitedApi api = SizeLimitedApi(3, neverFits: <String>{'big'});
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      for (final String id in <String>['a', 'big', 'b', 'c', 'd']) {
        await outbox.put(heldOrder(id, withTracking: false));
      }
      final int removed = await sync.flush('u1', pausedWithDrain());
      final List<HeldOrder> left = await outbox.readAll('u1');
      expect(removed, 4);
      expect(left.single.orderId, 'big');
      expect(left.single.state, HeldOrderState.needsAttention);
      expect(left.single.lastError, contains('too large'));
      expect((await sync.counts('u1', pausedWithDrain())).rejected, 1);
    },
  );

  test(
    'a busy answer pauses uploads until the time the server gives',
    () async {
      final BusyApi api = BusyApi();
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      await outbox.put(heldOrder('p1', withTracking: false));
      await sync.flush('u1', pausedWithDrain());
      await sync.flush('u1', pausedWithDrain());
      await sync.flush('u1', pausedWithDrain());
      expect(api.calls, 1);
      final HeldOrder row = (await outbox.readAll('u1')).single;
      expect(row.state, isNot(HeldOrderState.needsAttention));
    },
  );

  test(
    'FIX-290 a queued order is never sent while another person is signed in',
    () async {
      final SignedInUidApi api = SignedInUidApi();
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      await outbox.put(heldOrder('o1', withTracking: false));
      final Future<int> upload = sync.flush('u1', pausedWithDrain());
      signInTestUser('u2');
      expect(await upload, 0);
      expect(api.signedInUids, isEmpty);
      expect((await outbox.readAll('u1')).single.orderId, 'o1');
      signInTestUser('u1');
      expect(await sync.flush('u1', pausedWithDrain()), 1);
      expect(api.signedInUids, <String?>['u1']);
      expect(await outbox.readAll('u1'), isEmpty);
    },
  );

  test('a refusal while open still stops after 5 attempts', () async {
    final HeldWorkSync sync = HeldWorkSync(firestore: db);
    const CompanyLifecycle open = CompanyLifecycle(
      state: 'active',
      access: 'open',
    );
    await outbox.put(heldOrder('o1'));
    db.setError = (p) =>
        p.startsWith('gps_tracking') ? 'permission-denied' : null;
    for (int i = 1; i <= 8; i++) {
      await sync.flush('u1', open);
    }
    final HeldOrder row = (await outbox.readAll('u1')).single;
    expect(row.state, HeldOrderState.needsAttention);
    expect(gpsSets('o1'), 5);
  });

  test('a transient GPS failures back off and still retry later', () async {
    final HeldWorkSync sync = HeldWorkSync(firestore: db);
    const CompanyLifecycle open = CompanyLifecycle(
      state: 'active',
      access: 'open',
    );
    await outbox.put(heldOrder('o1'));
    db.setError = (p) => p.startsWith('gps_tracking') ? 'unavailable' : null;
    for (int i = 1; i <= 8; i++) {
      await sync.flush('u1', open);
    }
    final HeldOrder row = (await outbox.readAll('u1')).single;
    expect(gpsSets('o1'), 1);
    expect(row.state, isNot(HeldOrderState.needsAttention));
    final String stored = (await outbox.readAll(
      'u1',
    )).single.toJson().toString();
    expect(stored, contains('trackingRetryAfter'));
    await outbox.update(
      row.copyWith(
        trackingRetryAfter: DateTime.now().toUtc().subtract(
          const Duration(seconds: 1),
        ),
      ),
    );
    db.setError = (_) => null;
    await sync.flush('u1', open);
    expect(await outbox.readAll('u1'), isEmpty);
    expect(gpsSets('o1'), 2);
    expect(db.sets.where((String p) => p == 'orders/o1').length, 1);
  });

  test(
    'an order stored under the salesperson id gets its location record under that id',
    () async {
      final StoredAsApi api = StoredAsApi((String id) => 'u1~$id');
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      await outbox.put(heldOrder('c1'));
      final int removed = await sync.flush('u1', pausedWithDrain());
      expect(removed, 1);
      expect(await outbox.readAll('u1'), isEmpty);
      expect(db.docs.containsKey('gps_tracking/order_c1'), isFalse);
      expect(db.docs['gps_tracking/order_u1~c1']?['lastOrderId'], 'u1~c1');
    },
  );

  test('a refused location record never sends the order again', () async {
    final StoredAsApi api = StoredAsApi((String id) => id);
    final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
    await outbox.put(heldOrder('r1'));
    db.setError = (p) =>
        p.startsWith('gps_tracking') ? 'permission-denied' : null;
    for (int i = 1; i <= 8; i++) {
      await sync.flush('u1', reactivated());
    }
    final HeldOrder row = (await outbox.readAll('u1')).single;
    expect(api.sent, <String>['r1']);
    expect(row.storedAs, 'r1');
    expect(gpsSets('r1'), 5);
    expect(row.state, HeldOrderState.needsAttention);
    expect(row.lastError, contains('refused its location record'));
  });

  test(
    'a location record that fails once is sent later without sending the order again',
    () async {
      final StoredAsApi api = StoredAsApi((String id) => 'u1~$id');
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      await outbox.put(heldOrder('r2'));
      db.setError = (p) =>
          p.startsWith('gps_tracking') ? 'permission-denied' : null;
      await sync.flush('u1', pausedWithDrain());
      await sync.flush('u1', pausedWithDrain());
      db.setError = (_) => null;
      await sync.flush('u1', pausedWithDrain());
      expect(api.sent, <String>['r2']);
      expect(await outbox.readAll('u1'), isEmpty);
      expect(db.docs['gps_tracking/order_u1~r2']?['lastOrderId'], 'u1~r2');
    },
  );

  test(
    'a request that times out is split like one that is too large',
    () async {
      final SlowLinkApi api = SlowLinkApi(3);
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      for (int i = 1; i <= 7; i++) {
        await outbox.put(heldOrder('t$i', withTracking: false));
      }
      final int removed = await sync.flush('u1', pausedWithDrain());
      expect(removed, 7);
      expect(await outbox.readAll('u1'), isEmpty);
      expect(api.requestSizes.first, 7);
      expect(api.requestSizes.where((int size) => size <= 3).length, 3);
    },
  );

  test(
    'one item that times out alone stays queued and is not called too large',
    () async {
      final SlowLinkApi api = SlowLinkApi(0);
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      await outbox.put(heldOrder('t1', withTracking: false));
      await outbox.put(heldOrder('t2', withTracking: false));
      expect(await sync.flush('u1', pausedWithDrain()), 0);
      final List<HeldOrder> left = await outbox.readAll('u1');
      expect(left.length, 2);
      expect(
        left.every(
          (HeldOrder row) => row.state != HeldOrderState.needsAttention,
        ),
        isTrue,
      );
    },
  );

  test('a request is built to at most 512 KB as well as 25 items', () async {
    final SlowLinkApi api = SlowLinkApi(1000);
    final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
    for (int i = 1; i <= 4; i++) {
      await outbox.put(bigOrder('b$i', 300 * 1024));
    }
    for (int i = 1; i <= 30; i++) {
      await outbox.put(heldOrder('s$i', withTracking: false));
    }
    final int removed = await sync.flush('u1', pausedWithDrain());
    expect(removed, 34);
    expect(api.requestSizes.every((int size) => size <= 25), isTrue);
    expect(api.requestBytes.every((int bytes) => bytes <= 520 * 1024), isTrue);
    expect(api.requestSizes.length, greaterThanOrEqualTo(5));
    expect(api.requestSizes.reduce((int a, int b) => a + b), 34);
  });

  test(
    'one item that keeps timing out stays held and does not block the items behind it',
    () async {
      final TimesOutForApi api = TimesOutForApi('b1');
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      for (final String id in <String>['b1', 'b2', 'b3']) {
        await outbox.put(bigOrder(id, 300 * 1024));
      }
      final int removed = await sync.flush('u1', pausedWithDrain());
      expect(removed, 2);
      expect(api.sent, <String>['b2', 'b3']);
      final HeldOrder left = (await outbox.readAll('u1')).single;
      expect(left.orderId, 'b1');
      expect(left.state, isNot(HeldOrderState.needsAttention));
    },
  );

  test(
    'a refused order, stop update and visit result are listed, can be sent again or removed, and one refused result does not block the next',
    () async {
      final RouteStopOutbox stops = RouteStopOutbox(projectId: testProjectId);
      await stops.put(
        RouteStopLifecycleEvent(
          uid: 'u1',
          planId: 'p',
          stopId: 's1',
          workSessionId: 'w',
          workSessionGeneration: 1,
          sessionEventSequence: 1,
          eventId: 'e1',
          status: 'completed',
          deviceOccurredAt: DateTime.utc(2026, 1, 1),
          payload: const <String, dynamic>{},
          expectedSelectedStopId: 's1',
          expectedSelectionRevision: 0,
          state: RouteStopOutboxState.needsAttention,
          lastError: 'The stop already has a terminal state.',
        ),
      );
      await outbox.put(
        heldOrder('r1', withTracking: false).copyWith(
          state: HeldOrderState.needsAttention,
          lastError: 'The server refused this order.',
        ),
      );
      final String firstId = 'u1_1_a';
      final String secondId = 'u1_2_b';
      OfflineOperation outcome(String id, DateTime at) => OfflineOperation(
        operationId: id,
        type: 'conversation_outcome',
        documentId: id,
        payload: <String, dynamic>{
          'salesmanUid': 'u1',
          'retailerName': 'Shop',
          'clientCreatedAt': '2026-01-01T00:00:00.000Z',
        },
        createdAt: at,
      );
      await ProjectLocalStore(projectId: testProjectId).write(
        'u1',
        'outcomes',
        jsonEncode(<Map<String, dynamic>>[
          outcome(firstId, DateTime.utc(2026, 1, 1)).toJson(),
          outcome(secondId, DateTime.utc(2026, 1, 2)).toJson(),
        ]),
      );
      db.setError = (String path) =>
          path == 'conversation_outcomes/$firstId' ? 'invalid-argument' : null;
      final SalesVisitCopilotService outcomes = SalesVisitCopilotService(
        firestore: db,
      );
      await outcomes.initialiseForUser('u1');
      await outcomes.flushPending(isOnline: true, force: true);
      expect(db.docs.containsKey('conversation_outcomes/$secondId'), isTrue);
      expect(outcomes.stuckOutcomes.single.operationId, firstId);

      final StuckWork work = StuckWork(
        projectId: testProjectId,
        outcomes: outcomes,
      );
      final List<StuckWorkItem> listed = await work.list('u1');
      expect(
        listed.map((StuckWorkItem item) => item.kind).toSet(),
        <StuckWorkKind>{
          StuckWorkKind.stopEvent,
          StuckWorkKind.order,
          StuckWorkKind.outcome,
        },
      );
      expect(
        listed.firstWhere((i) => i.kind == StuckWorkKind.stopEvent).reason,
        contains('already closed'),
      );

      db.setError = (_) => null;
      await work.sendAgain(
        'u1',
        listed.firstWhere((i) => i.kind == StuckWorkKind.outcome),
      );
      expect(db.docs.containsKey('conversation_outcomes/$firstId'), isTrue);
      expect(outcomes.stuckOutcomes, isEmpty);

      db.docs['orders/r1'] = <String, dynamic>{'salesmanUid': 'u1'};
      await work.sendAgain(
        'u1',
        listed.firstWhere((i) => i.kind == StuckWorkKind.order),
      );
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: FakeApi());
      await sync.flush('u1', pausedWithDrain());
      expect(await outbox.readAll('u1'), isEmpty);

      await work.remove(
        'u1',
        listed.firstWhere((i) => i.kind == StuckWorkKind.stopEvent),
      );
      expect(await stops.readForUid('u1'), isEmpty);
      expect(await work.list('u1'), isEmpty);
    },
  );

  test(
    'two service instances never bring back a removed visit result or drop a newer one',
    () async {
      OfflineOperation outcome(String id, DateTime at) => OfflineOperation(
        operationId: id,
        type: 'conversation_outcome',
        documentId: id,
        payload: <String, dynamic>{
          'salesmanUid': 'u1',
          'retailerName': 'Shop',
          'clientCreatedAt': '2026-01-01T00:00:00.000Z',
        },
        createdAt: at,
      );
      await ProjectLocalStore(projectId: testProjectId).write(
        'u1',
        'outcomes',
        jsonEncode(<Map<String, dynamic>>[
          outcome('u1_1_a', DateTime.utc(2026, 1, 1)).toJson(),
          outcome('u1_2_b', DateTime.utc(2026, 1, 2)).toJson(),
        ]),
      );
      db.setError = (String path) => path == 'conversation_outcomes/u1_1_a'
          ? 'invalid-argument'
          : path == 'conversation_outcomes/u1_2_b'
          ? 'unavailable'
          : null;
      final SalesVisitCopilotService overview = SalesVisitCopilotService(
        firestore: db,
      );
      await overview.initialiseForUser('u1');
      await overview.flushPending(isOnline: true, force: true);
      final SalesVisitCopilotService screen = SalesVisitCopilotService(
        firestore: db,
      );
      await screen.initialiseForUser('u1');
      await screen.discardOutcome('u1_1_a');
      await overview.flushPending(isOnline: true, force: true);
      final SalesVisitCopilotService reopened = SalesVisitCopilotService(
        firestore: db,
      );
      await reopened.initialiseForUser('u1');
      expect(reopened.stuckOutcomes, isEmpty);
      expect(reopened.pendingCount, 1);

      db.setError = (String path) =>
          path == 'conversation_outcomes/u1_2_b' ? 'invalid-argument' : null;
      final SalesVisitCopilotService stale = SalesVisitCopilotService(
        firestore: db,
      );
      await stale.initialiseForUser('u1');
      await stale.flushPending(isOnline: true, force: true);
      expect(stale.stuckOutcomes.single.operationId, 'u1_2_b');
      await ProjectLocalStore(projectId: testProjectId).write(
        'u1',
        'outcomes',
        jsonEncode(<Map<String, dynamic>>[
          stale.stuckOutcomes.single.toJson(),
          outcome('u1_3_new', DateTime.utc(2026, 1, 3)).toJson(),
        ]),
      );
      await stale.discardOutcome('u1_2_b');
      final SalesVisitCopilotService last = SalesVisitCopilotService(
        firestore: db,
      );
      await last.initialiseForUser('u1');
      expect(last.stuckOutcomes, isEmpty);
      expect(last.pendingCount, 1);
    },
  );

  test(
    'a screen that loaded a visit result as pending neither sends nor brings back the one the person removed, and sends the one the person asked to send again',
    () async {
      OfflineOperation outcome(String id, DateTime at) => OfflineOperation(
        operationId: id,
        type: 'conversation_outcome',
        documentId: id,
        payload: <String, dynamic>{
          'salesmanUid': 'u1',
          'retailerName': 'Shop',
          'clientCreatedAt': '2026-01-01T00:00:00.000Z',
        },
        createdAt: at,
      );
      Future<List<String>> storedIds() async {
        final String? raw = await ProjectLocalStore(
          projectId: testProjectId,
        ).read('u1', 'outcomes');
        if (raw == null || raw.isEmpty) return const <String>[];
        return (jsonDecode(raw) as List)
            .map((Object? row) => (row as Map)['operationId'].toString())
            .toList();
      }

      await ProjectLocalStore(projectId: testProjectId).write(
        'u1',
        'outcomes',
        jsonEncode(<Map<String, dynamic>>[
          outcome('u1_1_x', DateTime.utc(2026, 1, 1)).toJson(),
          outcome('u1_2_y', DateTime.utc(2026, 1, 2)).toJson(),
        ]),
      );
      final SalesVisitCopilotService overview = SalesVisitCopilotService(
        firestore: db,
      );
      final SalesVisitCopilotService route = SalesVisitCopilotService(
        firestore: db,
      );
      await overview.initialiseForUser('u1');
      await route.initialiseForUser('u1');
      db.setError = (_) => 'invalid-argument';
      await route.flushPending(isOnline: true, force: true);
      expect(route.stuckOutcomes.length, 2);

      final SalesVisitCopilotService screen = SalesVisitCopilotService(
        firestore: db,
      );
      await screen.initialiseForUser('u1');
      await screen.discardOutcome('u1_1_x');
      expect(await storedIds(), <String>['u1_2_y']);

      db.setError = (_) => null;
      await overview.flushPending(isOnline: true, force: true);
      expect(
        db.docs.containsKey('conversation_outcomes/u1_1_x'),
        isFalse,
        reason: 'a removed visit result must not reach the server',
      );
      expect(await storedIds(), <String>[
        'u1_2_y',
      ], reason: 'removed item came back');
      expect(
        db.docs.containsKey('conversation_outcomes/u1_2_y'),
        isFalse,
        reason: 'a refused result is not sent until the person asks',
      );

      db.setError = (_) => 'unavailable';
      await screen.resendOutcome('u1_2_y');
      expect(db.docs.containsKey('conversation_outcomes/u1_2_y'), isFalse);
      expect(screen.stuckOutcomes, isEmpty);
      expect(screen.pendingCount, 1);

      db.setError = (_) => null;
      await overview.flushPending(isOnline: true, force: true);
      expect(
        db.docs.containsKey('conversation_outcomes/u1_2_y'),
        isTrue,
        reason:
            'a result the person asked to send again must go on the next flush from any screen',
      );
      expect(await storedIds(), isEmpty);
      expect(overview.stuckOutcomes, isEmpty);
      expect(overview.pendingCount, 0);
    },
  );

  test(
    'Send again on one screen for a visit result removed on another screen neither sends it nor shows it as waiting',
    () async {
      OfflineOperation outcome(String id, DateTime at) => OfflineOperation(
        operationId: id,
        type: 'conversation_outcome',
        documentId: id,
        payload: <String, dynamic>{
          'salesmanUid': 'u1',
          'retailerName': 'Shop',
          'clientCreatedAt': '2026-01-01T00:00:00.000Z',
        },
        createdAt: at,
      );
      Future<List<String>> storedIds() async {
        final String? raw = await ProjectLocalStore(
          projectId: testProjectId,
        ).read('u1', 'outcomes');
        if (raw == null || raw.isEmpty) return const <String>[];
        return (jsonDecode(raw) as List)
            .map((Object? row) => (row as Map)['operationId'].toString())
            .toList();
      }

      await ProjectLocalStore(projectId: testProjectId).write(
        'u1',
        'outcomes',
        jsonEncode(<Map<String, dynamic>>[
          outcome('u1_1_x', DateTime.utc(2026, 1, 1)).toJson(),
        ]),
      );
      final SalesVisitCopilotService route = SalesVisitCopilotService(
        firestore: db,
      );
      await route.initialiseForUser('u1');
      db.setError = (_) => 'invalid-argument';
      await route.flushPending(isOnline: true, force: true);
      expect(route.stuckOutcomes.single.operationId, 'u1_1_x');
      db.setError = (_) => null;

      final SalesVisitCopilotService stale = SalesVisitCopilotService(
        firestore: db,
      );
      final SalesVisitCopilotService other = SalesVisitCopilotService(
        firestore: db,
      );
      await stale.initialiseForUser('u1');
      await other.initialiseForUser('u1');
      await other.discardOutcome('u1_1_x');
      expect(await storedIds(), isEmpty);
      expect(
        stale.isHeld('u1_1_x'),
        isFalse,
        reason: 'a removed visit result is not shown as waiting anywhere',
      );

      await stale.resendOutcome('u1_1_x');
      expect(
        db.docs.containsKey('conversation_outcomes/u1_1_x'),
        isFalse,
        reason: 'a removed visit result must not be sent',
      );
      expect(await storedIds(), isEmpty, reason: 'removed item came back');
      expect(route.stuckOutcomes, isEmpty);
    },
  );

  test(
    'A screen left over from before sign-out neither sends again nor sends a removed visit result',
    () async {
      OfflineOperation outcome(String id, {String status = 'pending'}) =>
          OfflineOperation(
            operationId: id,
            type: 'conversation_outcome',
            documentId: id,
            payload: <String, dynamic>{
              'salesmanUid': 'u1',
              'retailerName': 'Shop',
              'clientCreatedAt': '2026-01-01T00:00:00.000Z',
            },
            createdAt: DateTime.utc(2026, 1, 1),
            targetStatus: status,
          );
      final ProjectLocalStore store = ProjectLocalStore(
        projectId: testProjectId,
      );
      await store.write(
        'u1',
        'outcomes',
        jsonEncode(<Map<String, dynamic>>[
          outcome('u1_1_a').toJson(),
          outcome('u1_1_b').toJson(),
          outcome(
            'u1_1_c',
            status: SalesVisitCopilotService.needsAttentionStatus,
          ).toJson(),
        ]),
      );
      final SalesVisitCopilotService old = SalesVisitCopilotService(
        firestore: db,
      );
      await old.initialiseForUser('u1');
      expect(old.pendingCount, 2);
      expect(old.stuckOutcomes.single.operationId, 'u1_1_c');

      ProjectLocalStore.invalidateIdentity();
      signInTestUser('u1');
      final SalesVisitCopilotService fresh = SalesVisitCopilotService(
        firestore: db,
      );
      await fresh.initialiseForUser('u1');
      await fresh.discardOutcome('u1_1_c');
      await fresh.flushPending(isOnline: true, force: true);
      expect(db.sets, <String>[
        'conversation_outcomes/u1_1_a',
        'conversation_outcomes/u1_1_b',
      ]);
      expect(await store.read('u1', 'outcomes'), anyOf(isNull, '[]'));

      await old.flushPending(isOnline: true, force: true);
      expect(db.sets.length, 2, reason: 'old screen sent again');
      expect(db.docs.containsKey('conversation_outcomes/u1_1_c'), isFalse);
      expect(old.isHeld('u1_1_c'), isFalse);
      expect(old.pendingCount, 0);
      expect(fresh.pendingCount, 0);
    },
  );

  test(
    'a server error on one held item does not stop the others, and a whole-company error stops after three requests',
    () async {
      final ServerErrorApi poisoned = ServerErrorApi(<String>{'p'});
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: poisoned);
      for (final String id in <String>['p', 'a', 'b', 'c']) {
        await outbox.put(heldOrder(id, withTracking: false));
      }
      expect(await sync.flush('u1', pausedWithDrain()), 3);
      final HeldOrder left = (await outbox.readAll('u1')).single;
      expect(left.orderId, 'p');
      expect(left.state, isNot(HeldOrderState.needsAttention));
      expect(left.lastError, contains('sent again'));
      expect(poisoned.sent, unorderedEquals(<String>['a', 'b', 'c']));

      await outbox.remove('u1', 'p');
      final ServerErrorApi down = ServerErrorApi(null);
      final HeldWorkSync downSync = HeldWorkSync(firestore: db, api: down);
      for (int i = 1; i <= 6; i++) {
        await outbox.put(heldOrder('d$i', withTracking: false));
      }
      expect(await downSync.flush('u1', pausedWithDrain()), 0);
      expect(down.calls, lessThanOrEqualTo(3));
      final List<HeldOrder> waiting = await outbox.readAll('u1');
      expect(waiting.length, 6);
      expect(
        waiting.every(
          (HeldOrder row) => row.state != HeldOrderState.needsAttention,
        ),
        isTrue,
      );
    },
  );

  test(
    'during a pause a refused held item never tells the salesperson to record it again or remove it',
    () async {
      for (final String reason in <String>[
        'save_failed',
        'before_session',
        'too_large',
        'invalid',
      ]) {
        final String paused = HeldWorkPolicy.rejectionText(
          reason,
          companyOpen: false,
        );
        expect(paused, isNot(contains('Record')), reason: reason);
        expect(paused, isNot(contains('remove this one')), reason: reason);
        expect(paused, contains('Keep this item'), reason: reason);
      }
      final RejectingApi api = RejectingApi('save_failed');
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      await outbox.put(heldOrder('x1', withTracking: false));
      await sync.flush('u1', pausedWithDrain());
      final HeldOrder row = (await outbox.readAll('u1')).single;
      expect(row.state, HeldOrderState.needsAttention);
      expect(row.lastError, isNot(contains('Record it again')));
      expect(row.lastError, contains('Keep this item'));
      expect(
        HeldWorkPolicy.rejectionText('save_failed', companyOpen: true),
        contains('Record it again'),
      );
    },
  );

  test(
    'held items behind items with server errors are still sent, and one bad item costs a bounded number of requests',
    () async {
      final ServerErrorApi front = ServerErrorApi(<String>{'p', 'q'});
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: front);
      for (final String id in <String>['p', 'q', 'a', 'b', 'c']) {
        await outbox.put(heldOrder(id, withTracking: false));
      }
      final List<int> removedPerFlush = <int>[
        for (int i = 0; i < 3; i++) await sync.flush('u1', pausedWithDrain()),
      ];
      expect(front.sent, unorderedEquals(<String>['a', 'b', 'c']));
      expect(removedPerFlush.reduce((int x, int y) => x + y), 3);
      final List<HeldOrder> left = await outbox.readAll('u1');
      expect(
        left.map((HeldOrder row) => row.orderId),
        unorderedEquals(<String>['p', 'q']),
      );
      expect(
        left.every(
          (HeldOrder row) => row.state != HeldOrderState.needsAttention,
        ),
        isTrue,
      );

      for (final HeldOrder row in left) {
        await outbox.remove('u1', row.orderId);
      }
      final List<String> ids = <String>[for (int i = 1; i <= 30; i++) 'n$i'];
      final ServerErrorApi late = ServerErrorApi(<String>{'n25'});
      final HeldWorkSync lateSync = HeldWorkSync(firestore: db, api: late);
      for (final String id in ids) {
        await outbox.put(heldOrder(id, withTracking: false));
      }
      expect(await lateSync.flush('u1', pausedWithDrain()), 29);
      expect(late.calls, lessThanOrEqualTo(20));
      expect((await outbox.readAll('u1')).single.orderId, 'n25');
    },
  );

  test(
    'a planner visit saved offline and refused after a pause stays on the phone under Needs attention, and Send again saves it',
    () async {
      final Completer<void> online = Completer<void>();
      db.offline = online.future;
      db.setError = (String path) =>
          path == 'visits/v1' ? 'permission-denied' : null;
      final bool kept = await HeldVisits(firestore: db).save(
        'u1',
        docId: 'v1',
        fields: <String, Object?>{
          'ownerUid': 'u1',
          'marketplace': 'Kedai Ah Seng',
          'date': '2026-11-09',
        },
        update: false,
        wait: const Duration(milliseconds: 20),
      );
      expect(kept, isTrue);
      expect(
        await HeldVisits(firestore: db).save(
          'u1',
          docId: 'v1',
          fields: <String, Object?>{'notes': 'Bring the new price list'},
          update: true,
          wait: const Duration(milliseconds: 20),
        ),
        isTrue,
      );
      online.complete();
      db.offline = null;
      await pumpEventQueue();

      final StuckWork work = StuckWork(
        projectId: testProjectId,
        outcomes: SalesVisitCopilotService(firestore: db),
        firestore: db,
      );
      final StuckWorkItem item = (await work.list('u1')).single;
      expect(item.kind, StuckWorkKind.visit);
      expect(item.title, contains('Kedai Ah Seng'));
      expect(item.reason, contains('Send again'));
      final HeldWorkCounts counts = await HeldWorkSync(
        firestore: db,
        api: FakeApi(),
      ).counts('u1', open);
      expect(counts.rejected, 1);

      db.setError = (_) => null;
      await work.sendAgain('u1', item);
      expect(db.docs['visits/v1']?['marketplace'], 'Kedai Ah Seng');
      expect(db.docs['visits/v1']?['notes'], 'Bring the new price list');
      expect(await work.list('u1'), isEmpty);
    },
  );

  testWidgets(
    'sign-out first warns when a sale is still waiting to upload, offers Upload now and Sign out anyway, and keeps the sale',
    (WidgetTester tester) async {
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: FakeApi());
      await tester.runAsync(() => outbox.put(heldOrder('s1')));
      final List<bool> answers = <bool>[
        (await tester.runAsync(() => sync.hasWorkToUpload('u1')))!,
        true,
      ];
      int uploads = 0;
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await confirmSignOut(
                  context,
                  hasWork: () async => answers.removeAt(0),
                  upload: () async => uploads++,
                );
              },
              child: const Text('Sign Out'),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Sign Out'));
      await settle();
      expect(find.text('Work is still waiting to upload'), findsOneWidget);
      await tester.tap(find.text('Upload now'));
      await settle();
      expect(uploads, 1);
      expect(
        find.textContaining('Not everything is uploaded yet'),
        findsOneWidget,
      );
      await tester.tap(find.text('Sign out anyway'));
      await settle();
      expect(result, isTrue);
      expect(
        (await tester.runAsync(() => outbox.readAll('u1')))!.single.orderId,
        's1',
      );

      await tester.runAsync(() => outbox.remove('u1', 's1'));
      answers.add((await tester.runAsync(() => sync.hasWorkToUpload('u1')))!);
      await tester.tap(find.text('Sign Out'));
      await settle();
      expect(find.text('Sign out?'), findsOneWidget);
      expect(find.text('Upload now'), findsNothing);
    },
  );

  test(
    'sign-out does not say work is waiting when nothing is held and the writes settle 1.4 seconds after the app opens',
    () async {
      db.pendingWrites = () =>
          Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(
        await HeldWorkSync(
          firestore: db,
          api: FakeApi(),
        ).hasWorkToUpload('u1'),
        isFalse,
      );
    },
  );

  test(
    'sign-out still says work is waiting when nothing is held but writes stay unsent, after 5 seconds and not before',
    () async {
      db.pendingWrites = () => Completer<void>().future;
      final Stopwatch waited = Stopwatch()..start();
      expect(
        await HeldWorkSync(
          firestore: db,
          api: FakeApi(),
        ).hasWorkToUpload('u1'),
        isTrue,
      );
      expect(waited.elapsedMilliseconds, greaterThanOrEqualTo(4900));
    },
  );

  test(
    'sign-out says work is waiting at once when a sale is held, with no wait for unsent writes',
    () async {
      await outbox.put(heldOrder('s1'));
      db.pendingWrites = () => Completer<void>().future;
      final Stopwatch waited = Stopwatch()..start();
      expect(
        await HeldWorkSync(
          firestore: db,
          api: FakeApi(),
        ).hasWorkToUpload('u1'),
        isTrue,
      );
      expect(waited.elapsedMilliseconds, lessThan(2000));
    },
  );

  testWidgets(
    'delete account warns that waiting work is lost and offers Upload now',
    (WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await confirmSignOut(
                  context,
                  hasWork: () async => true,
                  upload: () async {},
                  deletingAccount: true,
                );
              },
              child: const Text('Delete'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Work is still waiting to upload'), findsOneWidget);
      expect(find.textContaining('they are lost'), findsOneWidget);
      expect(find.text('Upload now'), findsOneWidget);
      await tester.tap(find.text('Delete anyway'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    },
  );

  test(
    'a planner visit saved offline is not lost when the app restarts before the server refuses it',
    () async {
      db.offline = Completer<void>().future;
      final Map<String, Object?> refused = <String, Object?>{
        'ownerUid': 'u1',
        'marketplace': 'Kedai Ah Seng',
        'date': '2026-11-09',
      };
      final Map<String, Object?> accepted = <String, Object?>{
        'ownerUid': 'u1',
        'marketplace': 'Kedai Mei Ling',
        'date': '2026-11-09',
      };
      for (final (String id, Map<String, Object?> fields)
          in <(String, Map<String, Object?>)>[
            ('v1', refused),
            ('v2', accepted),
          ]) {
        expect(
          await HeldVisits(firestore: db).save(
            'u1',
            docId: id,
            fields: fields,
            update: false,
            wait: const Duration(milliseconds: 20),
          ),
          isTrue,
        );
      }

      final FakeDb restarted = FakeDb();
      restarted.docs['visits/v2'] = <String, dynamic>{...accepted};
      final HeldWorkCounts counts = await HeldWorkSync(
        firestore: restarted,
        api: FakeApi(),
      ).counts('u1', open);
      expect(counts.rejected, 1);
      final StuckWork work = StuckWork(
        projectId: testProjectId,
        outcomes: SalesVisitCopilotService(firestore: restarted),
        firestore: restarted,
      );
      final StuckWorkItem item = (await work.list('u1')).single;
      expect(item.title, contains('Kedai Ah Seng'));
      await work.sendAgain('u1', item);
      expect(restarted.docs['visits/v1']?['marketplace'], 'Kedai Ah Seng');
      expect(await work.list('u1'), isEmpty);
    },
  );

  test(
    'every held item that failed before gets a turn, even when three others keep failing at the front',
    () async {
      final Set<String> failing = <String>{'x1', 'x2', 'x3', 'x4'};
      final ServerErrorApi api = ServerErrorApi(failing);
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      for (final String id in <String>['x1', 'x2', 'x3', 'x4']) {
        await outbox.put(heldOrder(id, withTracking: false));
      }
      for (int i = 0; i < 5; i++) {
        await sync.flush('u1', pausedWithDrain());
      }
      failing.remove('x4');
      for (int i = 0; i < 3; i++) {
        final int before = api.calls;
        await sync.flush('u1', pausedWithDrain());
        expect(api.calls - before, lessThanOrEqualTo(4));
      }
      expect(api.sent, <String>['x4']);
      expect(
        (await outbox.readAll('u1')).map((HeldOrder row) => row.orderId),
        unorderedEquals(<String>['x1', 'x2', 'x3']),
      );
    },
  );

  test(
    'a held order whose send is cut off by sign-out is sent again with the same id after sign-in, so it is stored once and never lost',
    () async {
      for (final String cut in <String>[
        'reply_lost',
        'never_arrived',
        'reply_after_sign_out',
      ]) {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        signInTestUser('u1');
        final SignOutMidSendApi api = SignOutMidSendApi(cut);
        final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
        await outbox.put(heldOrder('cut', withTracking: false));

        try {
          await sync.flush('u1', pausedWithDrain());
        } catch (_) {}

        ProjectLocalStore.invalidateIdentity();
        signInTestUser('u1');
        await sync.flush('u1', pausedWithDrain());

        expect(api.stored, <String>['cut'], reason: cut);
        expect(
          api.requestIds.every((String id) => id == 'cut'),
          isTrue,
          reason: cut,
        );
        expect(await outbox.readAll('u1'), isEmpty);
        expect(db.sets.where((String p) => p.startsWith('orders/')), isEmpty);
      }
    },
  );

  test(
    'MOB-01 an order that reached the server late in a company that was never paused is cleared from the phone, and sign-out no longer says work is waiting',
    () async {
      final NeverPausedApi api = NeverPausedApi();
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: api);
      final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor(
        api: api,
        sync: sync,
      );
      addTearDown(monitor.stop);
      await outbox.put(
        heldOrder(
          'late',
          withTracking: false,
        ).copyWith(state: HeldOrderState.pending),
      );
      monitor.start('u1');

      db.queued.add('orders/late');
      await monitor.refresh();
      expect(await sync.hasWorkToUpload('u1'), isTrue);
      expect((await outbox.readAll('u1')).single.state, HeldOrderState.pending);

      db.queued.clear();
      db.docs['orders/late'] = <String, dynamic>{
        'orderId': 'late',
        'salesmanUid': 'u1',
      };
      await monitor.refresh();
      expect(
        (await outbox.readAll('u1')).map((HeldOrder row) => row.orderId),
        isEmpty,
      );
      expect(await sync.hasWorkToUpload('u1'), isFalse);
      expect(db.sets.where((String p) => p.startsWith('orders/')), isEmpty);
      expect(monitor.uploadedCount, 0);
    },
  );

  HeldOrder recordedAfterTheCut(String id) => HeldOrder(
    orderId: id,
    uid: 'u1',
    workSessionId: 'w',
    workSessionGeneration: 1,
    sessionStartedAt: DateTime.now().toUtc(),
    deviceAt: DateTime.now().toUtc(),
    payload: <String, dynamic>{'orderId': id, 'salesmanUid': 'u1'},
    state: HeldOrderState.held,
  );

  FirebaseException refusedByRules() =>
      FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');

  Future<List<String>> rowsLeft() async => <String>[
    for (final HeldOrder row in await outbox.readAll('u1'))
      '${row.orderId} ${row.state.name} ${row.lastError}',
  ];

  test(
    'MOB-02 a held order whose direct send timed out and then reached the server is delivered on the next upload, never refused or sent twice',
    () async {
      final List<String> writes = <String>[];
      String firstSend = 'lands_late';
      final HeldWorkSync sync = HeldWorkSync(
        firestore: db,
        api: FakeApi(),
        orderWriter: (HeldOrder order) async {
          final String path = 'orders/${order.orderId}';
          writes.add(path);
          if (db.docs.containsKey(path)) throw refusedByRules();
          if (firstSend == 'still_queued') {
            db.queued.add(path);
            throw TimeoutException('slow');
          }
          db.docs[path] = <String, dynamic>{...order.payload};
          if (firstSend == 'lands_late') throw TimeoutException('slow');
          if (firstSend == 'lands_while_sending') throw refusedByRules();
        },
      );

      await outbox.put(recordedAfterTheCut('late'));
      expect(await sync.flush('u1', reactivated()), 0);
      expect(await rowsLeft(), <String>['late held ']);
      expect(await sync.flush('u1', reactivated()), 1);
      expect(await rowsLeft(), isEmpty);
      expect(writes, <String>['orders/late']);

      firstSend = 'still_queued';
      await outbox.put(recordedAfterTheCut('queued'));
      await sync.flush('u1', reactivated());
      await sync.flush('u1', reactivated());
      expect(await rowsLeft(), <String>['queued held ']);
      expect(writes, <String>['orders/late', 'orders/queued']);
      db.queued.clear();
      db.docs['orders/queued'] = <String, dynamic>{'salesmanUid': 'u1'};
      expect(await sync.flush('u1', reactivated()), 1);
      expect(await rowsLeft(), isEmpty);
      expect(writes, <String>['orders/late', 'orders/queued']);

      firstSend = 'lands_while_sending';
      await outbox.put(recordedAfterTheCut('raced'));
      expect(await sync.flush('u1', reactivated()), 1);
      expect(await rowsLeft(), isEmpty);
    },
  );

  test(
    'MOB-02 control: a held order the server really refuses still needs attention, and one that never arrived is sent exactly once',
    () async {
      final List<String> writes = <String>[];
      final HeldWorkSync sync = HeldWorkSync(
        firestore: db,
        api: FakeApi(),
        orderWriter: (HeldOrder order) async {
          writes.add(order.orderId);
          if (order.orderId == 'refused') throw refusedByRules();
          db.docs['orders/${order.orderId}'] = <String, dynamic>{
            ...order.payload,
          };
        },
      );
      await outbox.put(recordedAfterTheCut('refused'));
      await outbox.put(recordedAfterTheCut('fresh'));
      expect(await sync.flush('u1', reactivated()), 1);
      await sync.flush('u1', reactivated());

      final HeldOrder left = (await outbox.readAll('u1')).single;
      expect(left.orderId, 'refused');
      expect(left.state, HeldOrderState.needsAttention);
      expect(left.lastError, contains('The server refused this order'));
      expect(db.docs.containsKey('orders/refused'), isFalse);
      expect(writes, <String>['refused', 'fresh']);
      expect(db.docs['orders/fresh']?['orderId'], 'fresh');
      expect((await sync.counts('u1', reactivated())).rejected, 1);
    },
  );

  const String recordAgainAdvice =
      'The server refused this order. Sending it again will not help. Record the order again, then remove this one.';

  HeldOrder leftByTheOldApp(String id, {bool withTracking = false}) {
    final HeldOrder base = recordedAfterTheCut(id);
    return HeldOrder(
      orderId: id,
      uid: base.uid,
      workSessionId: base.workSessionId,
      workSessionGeneration: base.workSessionGeneration,
      sessionStartedAt: base.sessionStartedAt,
      deviceAt: base.deviceAt,
      payload: base.payload,
      state: HeldOrderState.needsAttention,
      lastError: recordAgainAdvice,
      tracking: withTracking ? heldOrder(id).tracking : null,
    );
  }

  int serverReads(String id) =>
      db.serverGets.where((String p) => p == 'orders/$id').length;

  test(
    'MOB-02 an order left under Needs attention that the server already has is cleared on the next upload without being sent, and sign-out no longer reports it',
    () async {
      final List<String> writes = <String>[];
      final FakeApi api = FakeApi();
      final HeldWorkSync sync = HeldWorkSync(
        firestore: db,
        api: api,
        orderWriter: (HeldOrder order) async => writes.add(order.orderId),
      );

      await outbox.put(leftByTheOldApp('old'));
      db.docs['orders/old'] = <String, dynamic>{'salesmanUid': 'u1'};
      expect((await sync.counts('u1', reactivated())).rejected, 1);

      db.serverGetError = (_) => 'unavailable';
      expect(await sync.flush('u1', reactivated()), 0);
      expect(await rowsLeft(), <String>[
        'old needsAttention $recordAgainAdvice',
      ]);

      db.serverGetError = (_) => null;
      db.serverGets.clear();
      expect(await sync.flush('u1', reactivated()), 1);
      expect(await rowsLeft(), isEmpty);
      expect(serverReads('old'), 1);
      expect((await sync.counts('u1', reactivated())).rejected, 0);
      expect(await sync.hasWorkToUpload('u1'), isFalse);

      await outbox.put(leftByTheOldApp('neverPaused'));
      db.docs['orders/neverPaused'] = <String, dynamic>{'salesmanUid': 'u1'};
      final NeverPausedApi openApi = NeverPausedApi();
      final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor(
        api: openApi,
        sync: HeldWorkSync(
          firestore: db,
          api: openApi,
          orderWriter: (HeldOrder order) async => writes.add(order.orderId),
        ),
      );
      addTearDown(monitor.stop);
      monitor.start('u1');
      await monitor.refresh();
      expect(await rowsLeft(), isEmpty);
      expect(monitor.counts.rejected, 0);

      await outbox.put(leftByTheOldApp('located', withTracking: true));
      db.docs['orders/located'] = <String, dynamic>{'salesmanUid': 'u1'};
      db.setError = (String p) =>
          p.startsWith('gps_tracking') ? 'unavailable' : null;
      expect(await sync.flush('u1', reactivated()), 0);
      final HeldOrder waiting = (await outbox.readAll('u1')).single;
      expect(waiting.state, HeldOrderState.pending);
      expect(waiting.lastError, isEmpty);
      expect((await sync.counts('u1', reactivated())).rejected, 0);
      db.setError = (_) => null;
      await outbox.update(
        waiting.copyWith(
          trackingRetryAfter: DateTime.now().toUtc().subtract(
            const Duration(seconds: 1),
          ),
        ),
      );
      expect(await sync.flush('u1', reactivated()), 1);
      expect(await rowsLeft(), isEmpty);
      expect(gpsSets('located'), 2);

      expect(writes, isEmpty);
      expect(api.calls, 0);
      expect(db.sets.where((String p) => p.startsWith('orders/')), isEmpty);
    },
  );

  test(
    'MOB-02 control: an order under Needs attention stays there when the server does not have it, refuses the read, holds that id for another salesperson, or cannot be reached',
    () async {
      final List<String> writes = <String>[];
      final FakeApi api = FakeApi();
      final HeldWorkSync sync = HeldWorkSync(
        firestore: db,
        api: api,
        orderWriter: (HeldOrder order) async => writes.add(order.orderId),
      );
      for (final String id in <String>[
        'missing',
        'denied',
        'theirs',
        'unreachable',
        'behind',
      ]) {
        await outbox.put(leftByTheOldApp(id));
      }
      db.docs['orders/theirs'] = <String, dynamic>{'salesmanUid': 'u2'};
      db.docs['orders/unreachable'] = <String, dynamic>{'salesmanUid': 'u1'};
      db.docs['orders/behind'] = <String, dynamic>{'salesmanUid': 'u1'};
      db.serverGetError = (String p) => switch (p) {
        'orders/denied' => 'permission-denied',
        'orders/unreachable' || 'orders/behind' => 'unavailable',
        _ => null,
      };
      final List<String> unchanged = <String>[
        for (final String id in <String>[
          'missing',
          'denied',
          'theirs',
          'unreachable',
          'behind',
        ])
          '$id needsAttention $recordAgainAdvice',
      ];

      expect(await sync.flush('u1', reactivated()), 0);
      expect(await rowsLeft(), unchanged);
      for (final String id in <String>['missing', 'denied', 'theirs']) {
        expect(serverReads(id), lessThanOrEqualTo(1));
      }
      expect(serverReads('behind'), 0);

      final NeverPausedApi openApi = NeverPausedApi();
      final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor(
        api: openApi,
        sync: HeldWorkSync(
          firestore: db,
          api: openApi,
          orderWriter: (HeldOrder order) async => writes.add(order.orderId),
        ),
      );
      addTearDown(monitor.stop);
      monitor.start('u1');
      await monitor.refresh();
      expect(await rowsLeft(), unchanged);
      expect(monitor.counts.rejected, 5);

      expect(writes, isEmpty);
      expect(api.calls, 0);
      expect(db.sets, isEmpty);
    },
  );

  test(
    'MOB-02 an order under Needs attention that the server does not have is asked for once, not on every upload',
    () async {
      final HeldWorkSync sync = HeldWorkSync(firestore: db, api: FakeApi());
      await outbox.put(leftByTheOldApp('missing'));
      await outbox.put(leftByTheOldApp('denied'));
      db.serverGetError = (String p) =>
          p == 'orders/denied' ? 'permission-denied' : null;
      for (int i = 0; i < 5; i++) {
        await sync.flush('u1', reactivated());
        await sync.forgetStoredOrders('u1', reactivated());
      }
      expect(serverReads('missing'), 1);
      expect(serverReads('denied'), 1);
      expect(await rowsLeft(), <String>[
        'missing needsAttention $recordAgainAdvice',
        'denied needsAttention $recordAgainAdvice',
      ]);
    },
  );
}

class SignOutMidSendApi extends CompanyApi {
  SignOutMidSendApi(this.cut);
  final String cut;
  final List<String> stored = <String>[];
  final List<String> requestIds = <String>[];
  int calls = 0;
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    calls++;
    final List<String> ids = <String>[
      for (final Map<String, Object?> item in items)
        if (item['kind'] == 'order') item['id']! as String,
    ];
    requestIds.addAll(ids);
    if (calls == 1) {
      ProjectLocalStore.invalidateIdentity();
      signInTestUser(null);
      if (cut == 'never_arrived') throw const HeldWorkRefusal.timedOut();
      stored.addAll(ids);
      if (cut == 'reply_lost') throw const HeldWorkRefusal.timedOut();
      return <HeldWorkResult>[
        for (final String id in ids)
          HeldWorkResult(id: id, outcome: 'accepted'),
      ];
    }
    final List<HeldWorkResult> results = <HeldWorkResult>[];
    for (final String id in ids) {
      final bool known = stored.contains(id);
      if (!known) stored.add(id);
      results.add(
        HeldWorkResult(id: id, outcome: known ? 'duplicate' : 'accepted'),
      );
    }
    return results;
  }
}

class ServerErrorApi extends CompanyApi {
  ServerErrorApi(this.poison);
  final Set<String>? poison;
  final List<String> sent = <String>[];
  int calls = 0;
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    calls++;
    final List<Map<String, Object?>> orders = items
        .where((Map<String, Object?> item) => item['kind'] == 'order')
        .toList();
    final Set<String>? bad = poison;
    if (bad == null ||
        orders.any((Map<String, Object?> item) => bad.contains(item['id']))) {
      throw const HeldWorkRefusal.serverError();
    }
    sent.addAll(
      orders.map((Map<String, Object?> item) => item['id']! as String),
    );
    return <HeldWorkResult>[
      for (final Map<String, Object?> item in orders)
        HeldWorkResult(id: item['id']! as String, outcome: 'accepted'),
    ];
  }
}

class RejectingApi extends CompanyApi {
  RejectingApi(this.reason);
  final String reason;
  @override
  bool get enabled => true;
  @override
  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async => <HeldWorkResult>[
    for (final Map<String, Object?> item in items)
      if (item['kind'] == 'order')
        HeldWorkResult(
          id: item['id']! as String,
          outcome: 'rejected',
          reason: reason,
        ),
  ];
}
