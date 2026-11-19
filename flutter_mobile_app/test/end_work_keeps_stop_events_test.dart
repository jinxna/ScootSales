// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/assigned_route_plan.dart';
import 'package:fmcg_sales/models/company_lifecycle.dart';
import 'package:fmcg_sales/models/route_stop_lifecycle_event.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/models/work_session.dart';
import 'package:fmcg_sales/providers/gps_provider.dart';
import 'package:fmcg_sales/services/firestore_service.dart';
import 'package:fmcg_sales/services/gps_backlog.dart';
import 'package:fmcg_sales/services/held_work.dart';
import 'package:fmcg_sales/services/project_local_store.dart';
import 'package:fmcg_sales/services/route_plan_service.dart';
import 'package:fmcg_sales/services/route_stop_outbox.dart';
import 'package:fmcg_sales/services/work_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

class _Db implements FirebaseFirestore {
  bool online = false;
  final Set<String> refusedReads = <String>{};
  final Map<String, Map<String, dynamic>> docs =
      <String, Map<String, dynamic>>{};
  final List<String> writes = <String>[];
  @override
  FirebaseApp get app => Firebase.app();
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Col(this, path);
  @override
  WriteBatch batch() => _Batch(this);
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('db ${i.memberName}');
}

class _Col implements CollectionReference<Map<String, dynamic>> {
  _Col(this.db, this.path);
  final _Db db;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      _Doc(db, '$path/$id');
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('col ${i.memberName}');
}

class _Doc implements DocumentReference<Map<String, dynamic>> {
  _Doc(this.db, this.path);
  final _Db db;
  @override
  final String path;
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    if (!db.online) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    if (db.refusedReads.contains(path)) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
    }
    return _Snap(db.docs[path]);
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('doc ${i.memberName}');
}

class _Snap implements DocumentSnapshot<Map<String, dynamic>> {
  _Snap(this._data);
  final Map<String, dynamic>? _data;
  @override
  Map<String, dynamic>? data() => _data;
  @override
  bool get exists => _data != null;
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('snap ${i.memberName}');
}

class _Batch implements WriteBatch {
  _Batch(this.db);
  final _Db db;
  final List<MapEntry<String, Map<String, dynamic>>> sets =
      <MapEntry<String, Map<String, dynamic>>>[];
  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {
    sets.add(
      MapEntry<String, Map<String, dynamic>>(
        document.path,
        Map<String, dynamic>.from(data as Map<String, dynamic>),
      ),
    );
  }

  @override
  Future<void> commit() async {
    if (!db.online) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    for (final MapEntry<String, Map<String, dynamic>> entry in sets) {
      db.writes.add('${entry.key}:${entry.value['status']}');
      db.docs[entry.key] = <String, dynamic>{
        ...?db.docs[entry.key],
        ...entry.value,
      };
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('batch ${i.memberName}');
}

class _Server implements FirestoreService {
  _Server(this.log);
  final List<String> log;
  bool online = true;
  String status = 'active';
  int reads = 0;
  Completer<void>? gate;

  @override
  Future<WorkSessionServerRecord> readWorkSession(String uid) async {
    reads++;
    final Completer<void>? waitFor = gate;
    if (waitFor != null) await waitFor.future;
    if (!online) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    return WorkSessionServerRecord.fromMap(<String, dynamic>{
      'uid': uid,
      'workSessionStatus': status,
      'activeSessionId': 'w1',
      'activeSessionGeneration': 1,
      'lastFixSequence': 0,
    }, exists: true);
  }

  @override
  Future<UserModel?> getUser(
    String uid, {
    Source source = Source.serverAndCache,
  }) async => _user;

  @override
  Future<void> publishHeldTrack({
    required UserModel user,
    required WorkSession session,
    GpsBacklogStore? store,
  }) async {
    log.add('positions');
  }

  @override
  Future<void> flushHeldTrack({
    required UserModel user,
    GpsBacklogStore? store,
  }) async {}

  @override
  Future<WorkSessionEndResult> endWorkSession({
    required String uid,
    required String sessionId,
    required int generation,
  }) async {
    log.add('end');
    status = 'ended';
    return WorkSessionEndResult.ended;
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('server ${i.memberName}');
}

final UserModel _user = UserModel(
  uid: 'u1',
  staffId: 'S1',
  name: 'Ali',
  email: 'ali@example.test',
  phone: '1',
  territory: 't',
  role: 'salesman',
  joinedDate: '2026-01-01',
);

WorkSession _session({
  WorkSessionLocalStatus status = WorkSessionLocalStatus.active,
  bool endPendingSync = false,
}) => WorkSession(
  uid: 'u1',
  sessionId: 'w1',
  generation: 1,
  lastFixSequence: 0,
  lastRouteStopEventSequence: 2,
  status: status,
  endPendingSync: endPendingSync,
  deviceStartedAt: DateTime.utc(2026, 11, 18, 1),
);

RouteStopLifecycleEvent _event(
  String status,
  int sequence, {
  String planId = 'p1',
  String stopId = 's1',
}) => RouteStopLifecycleEvent(
  uid: 'u1',
  planId: planId,
  stopId: stopId,
  workSessionId: 'w1',
  workSessionGeneration: 1,
  sessionEventSequence: sequence,
  eventId: 'w1_${stopId}_$status',
  status: status,
  deviceOccurredAt: DateTime.utc(2026, 11, 18, 2, sequence),
  payload: <String, dynamic>{},
  expectedSelectedStopId: stopId,
  expectedSelectionRevision: 1,
  sessionDeviceStartedAt: DateTime.utc(2026, 11, 18, 1),
);

AssignedRoutePlan _plan(String planId, String stopId) =>
    AssignedRoutePlan.fromMap(planId, <String, dynamic>{
      'status': 'published',
      'salesmanUid': 'u1',
      'branchId': 'b1',
      'days': <Map<String, dynamic>>[
        <String, dynamic>{
          'dayId': 'd1',
          'stops': <Map<String, dynamic>>[
            <String, dynamic>{'stopId': stopId, 'retailerId': 'r1'},
          ],
        },
      ],
    });

void _publishOnServer(_Db db, String planId, String stopId) {
  db.docs['route_plans/$planId'] = <String, dynamic>{
    'status': 'published',
    'planId': planId,
    'salesmanUid': 'u1',
    'branchId': 'b1',
    'stopIds': <String>[stopId],
  };
  db.docs['route_plan_progress/${planId}_u1'] = <String, dynamic>{
    'status': 'in_progress',
    'selectedStopId': stopId,
    'selectionRevision': 1,
  };
}

const List<String> _deviceChannels = <String>[
  'flutter.baseflow.com/geolocator',
  'flutter.baseflow.com/geolocator_android',
  'flutter.baseflow.com/geolocator_service_updates',
  'flutter.baseflow.com/geolocator_service_updates_android',
  'my.scootsales.app/notifications',
];

void _allowLocation() {
  for (final String name in _deviceChannels) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (
          MethodCall call,
        ) async {
          return switch (call.method) {
            'isLocationServiceEnabled' => true,
            'checkPermission' || 'requestPermission' => 3,
            _ => null,
          };
        });
  }
}

void main() {
  setUpAll(installTestFirebase);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signInTestUser('u1');
  });

  test(
    'a stop record whose route can no longer be read is kept for attention, the other record is sent, the end is not blocked, and a later retry sends it once',
    () async {
      final _Db db = _Db()..online = true;
      final AssignedRoutePlan withdrawn = _plan('p1', 's1');
      await ProjectLocalStore(projectId: testProjectId).write(
        'u1',
        'assigned_routes',
        jsonEncode(<Map<String, dynamic>>[
          withdrawn.toCacheMap(),
          _plan('p2', 's2').toCacheMap(),
        ]),
      );
      final WorkSession ending = _session(
        status: WorkSessionLocalStatus.ended,
        endPendingSync: true,
      );
      await WorkSessionStore(projectId: testProjectId).write(ending);
      final RouteStopOutbox outbox = RouteStopOutbox(projectId: testProjectId);
      await outbox.put(_event('arrived', 1));
      await outbox.put(_event('arrived', 2, planId: 'p2', stopId: 's2'));
      _publishOnServer(db, 'p1', 's1');
      _publishOnServer(db, 'p2', 's2');
      db.docs['live_tracking/u1'] = <String, dynamic>{
        'uid': 'u1',
        'workSessionStatus': 'active',
        'activeSessionId': 'w1',
        'activeSessionGeneration': 1,
      };
      db.refusedReads.add('route_plans/p1');
      final RoutePlanService service = RoutePlanService(firestore: db);

      expect(
        await service.sendWaitingStopEvents(
          uid: 'u1',
          user: _user,
          session: ending,
        ),
        isTrue,
      );
      final List<RouteStopLifecycleEvent> kept = await outbox.readForUid('u1');
      expect(
        kept.map(
          (RouteStopLifecycleEvent e) => '${e.planId}:${e.status}:${e.state.name}',
        ),
        <String>['p1:arrived:needsAttention'],
      );
      expect(
        kept.single.lastError,
        'This stop is not on a route assigned to you now. The route may have been replaced or removed, so this could not be recorded. Ask your manager which route to follow.',
      );
      expect(
        db.writes
            .where((String w) => w.startsWith('route_stop_progress/'))
            .toList(),
        <String>['route_stop_progress/p2_u1_s2:arrived'],
      );

      db.refusedReads.clear();
      expect(
        await service.retryPendingStopEvents(
          plan: withdrawn,
          user: _user,
          progress: RouteProgress.fromMap(null),
        ),
        RouteProgressWriteState.synced,
      );
      expect(
        await service.retryPendingStopEvents(
          plan: withdrawn,
          user: _user,
          progress: RouteProgress.fromMap(null),
        ),
        RouteProgressWriteState.synced,
      );
      expect(
        db.writes
            .where((String w) => w.startsWith('route_stop_progress/'))
            .toList(),
        <String>[
          'route_stop_progress/p2_u1_s2:arrived',
          'route_stop_progress/p1_u1_s1:arrived',
        ],
      );
      expect(await outbox.readForUid('u1'), isEmpty);
    },
  );

  test(
    'a refusal while a company pause is still landing is undecided, so the record is not sent to attention',
    () {
      bool landing(String state, String access) => HeldWorkPolicy.pauseIsLanding(
        CompanyLifecycle(state: state, access: access),
      );
      expect(landing('suspended', 'open'), isTrue);
      expect(landing('expired', 'open'), isTrue);
      expect(landing('cancelled', 'open'), isTrue);
      expect(landing('active', 'open'), isFalse);
      expect(landing('past_due', 'open'), isFalse);
      expect(landing('suspended', 'readonly'), isFalse);
      expect(HeldWorkPolicy.pauseIsLanding(null), isFalse);
    },
  );

  test(
    'after End Work with no signal and a Start Work that also fails, the session end finishes by itself when the signal returns',
    () {
      _allowLocation();
      fakeAsync((FakeAsync async) {
        final List<String> log = <String>[];
        final _Server server = _Server(log)..online = false;
        final GpsProvider gps = GpsProvider(
          firestoreService: server,
          sendWaitingStopEvents:
              (String uid, UserModel? user, WorkSession session) async {
                log.add('events');
                return true;
              },
        );
        WorkSessionStore(projectId: testProjectId).write(_session());
        async.flushMicrotasks();
        gps.endWork(uid: 'u1', user: _user);
        async.flushMicrotasks();
        expect(gps.state, GpsTrackingState.sessionEndPending);

        gps.startTracking(user: _user, explicit: true);
        async.flushMicrotasks();
        expect(gps.state, GpsTrackingState.syncPending);
        expect(gps.hasActiveWorkSession, isFalse);
        expect(log, isEmpty);

        server.online = true;
        async.elapse(const Duration(seconds: 16));

        expect(log, <String>['positions', 'events', 'end']);
        expect(server.status, 'ended');
        expect(gps.state, GpsTrackingState.sessionEnded);
        gps.dispose();
      });
    },
  );

  test(
    'after the app is reopened with a session end still waiting, the end finishes by itself with no resume and no network change',
    () {
      _allowLocation();
      fakeAsync((FakeAsync async) {
        final List<String> log = <String>[];
        final _Server server = _Server(log)..online = false;
        WorkSessionStore(projectId: testProjectId).write(
          _session(status: WorkSessionLocalStatus.ended, endPendingSync: true),
        );
        async.flushMicrotasks();
        final GpsProvider gps = GpsProvider(
          firestoreService: server,
          sendWaitingStopEvents:
              (String uid, UserModel? user, WorkSession session) async {
                log.add('events');
                return true;
              },
        );
        gps.startTracking(user: _user);
        async.flushMicrotasks();
        expect(gps.state, GpsTrackingState.syncPending);
        expect(log, isEmpty);

        server.online = true;
        async.elapse(const Duration(seconds: 16));

        expect(log, <String>['positions', 'events', 'end']);
        expect(server.status, 'ended');
        expect(gps.state, GpsTrackingState.sessionEnded);
        gps.dispose();
      });
    },
  );

  test(
    'an End Work still in flight when the provider is disposed notifies nobody and schedules no retry',
    () {
      fakeAsync((FakeAsync async) {
        final _Server server = _Server(<String>[])
          ..online = false
          ..gate = Completer<void>();
        final GpsProvider gps = GpsProvider(
          firestoreService: server,
          sendWaitingStopEvents:
              (String uid, UserModel? user, WorkSession session) async => true,
        );
        WorkSessionStore(projectId: testProjectId).write(_session());
        async.flushMicrotasks();
        Object? failure;
        gps
            .endWork(uid: 'u1', user: _user)
            .then<void>(
              (_) {},
              onError: (Object error) {
                failure = error;
              },
            );
        async.flushMicrotasks();
        expect(server.reads, 1);

        gps.dispose();
        server.gate!.complete();
        async.flushMicrotasks();

        expect(failure, isNull);
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 16));
        expect(server.reads, 1);
      });
    },
  );

  test(
    'stop events recorded before End Work are sent while the session end waits',
    () async {
      final _Db db = _Db();
      final AssignedRoutePlan plan =
          AssignedRoutePlan.fromMap('p1', <String, dynamic>{
            'status': 'published',
            'salesmanUid': 'u1',
            'branchId': 'b1',
            'days': <Map<String, dynamic>>[
              <String, dynamic>{
                'dayId': 'd1',
                'stops': <Map<String, dynamic>>[
                  <String, dynamic>{'stopId': 's1', 'retailerId': 'r1'},
                ],
              },
            ],
          });
      await ProjectLocalStore(projectId: testProjectId).write(
        'u1',
        'assigned_routes',
        jsonEncode(<Map<String, dynamic>>[plan.toCacheMap()]),
      );
      final WorkSession ending = _session(
        status: WorkSessionLocalStatus.ended,
        endPendingSync: true,
      );
      await WorkSessionStore(projectId: testProjectId).write(ending);
      final RouteStopOutbox outbox = RouteStopOutbox(projectId: testProjectId);
      await outbox.put(_event('arrived', 1));
      await outbox.put(_event('completed', 2));
      final RoutePlanService service = RoutePlanService(firestore: db);

      expect(
        await service.sendWaitingStopEvents(
          uid: 'u1',
          user: _user,
          session: ending,
        ),
        isFalse,
      );
      expect(
        (await outbox.readForUid(
          'u1',
        )).map((RouteStopLifecycleEvent e) => '${e.status}:${e.state.name}'),
        <String>['arrived:pending', 'completed:pending'],
      );

      db.online = true;
      db.docs['route_plans/p1'] = <String, dynamic>{
        'status': 'published',
        'planId': 'p1',
        'salesmanUid': 'u1',
        'branchId': 'b1',
        'stopIds': <String>['s1'],
      };
      db.docs['live_tracking/u1'] = <String, dynamic>{
        'uid': 'u1',
        'workSessionStatus': 'active',
        'activeSessionId': 'w1',
        'activeSessionGeneration': 1,
      };
      db.docs['route_plan_progress/p1_u1'] = <String, dynamic>{
        'status': 'in_progress',
        'selectedStopId': 's1',
        'selectionRevision': 1,
      };

      expect(
        await service.sendWaitingStopEvents(
          uid: 'u1',
          user: _user,
          session: ending,
        ),
        isTrue,
      );
      expect(
        db.writes
            .where((String w) => w.startsWith('route_stop_progress/'))
            .toList(),
        <String>[
          'route_stop_progress/p1_u1_s1:arrived',
          'route_stop_progress/p1_u1_s1:completed',
        ],
      );
      expect(await outbox.readForUid('u1'), isEmpty);
    },
  );

  test(
    'a stop event the server refuses is kept for attention and does not block the end',
    () async {
      final _Db db = _Db()..online = true;
      final WorkSession ending = _session(
        status: WorkSessionLocalStatus.ended,
        endPendingSync: true,
      );
      await WorkSessionStore(projectId: testProjectId).write(ending);
      final RouteStopOutbox outbox = RouteStopOutbox(projectId: testProjectId);
      await outbox.put(_event('completed', 2));
      await ProjectLocalStore(projectId: testProjectId).write(
        'u1',
        'assigned_routes',
        jsonEncode(<Map<String, dynamic>>[
          AssignedRoutePlan.fromMap('p1', <String, dynamic>{
            'status': 'published',
            'salesmanUid': 'u1',
            'branchId': 'b1',
            'days': <Map<String, dynamic>>[
              <String, dynamic>{
                'dayId': 'd1',
                'stops': <Map<String, dynamic>>[
                  <String, dynamic>{'stopId': 's1', 'retailerId': 'r1'},
                ],
              },
            ],
          }).toCacheMap(),
        ]),
      );
      db.docs['route_plans/p1'] = <String, dynamic>{
        'status': 'published',
        'planId': 'p1',
        'salesmanUid': 'u1',
        'branchId': 'b1',
        'stopIds': <String>['s1'],
      };
      db.docs['live_tracking/u1'] = <String, dynamic>{
        'uid': 'u1',
        'workSessionStatus': 'active',
        'activeSessionId': 'w1',
        'activeSessionGeneration': 1,
      };
      db.docs['route_plan_progress/p1_u1'] = <String, dynamic>{
        'status': 'in_progress',
        'selectedStopId': 's1',
        'selectionRevision': 1,
      };

      expect(
        await RoutePlanService(
          firestore: db,
        ).sendWaitingStopEvents(uid: 'u1', user: _user, session: ending),
        isTrue,
      );
      final List<RouteStopLifecycleEvent> kept = await outbox.readForUid('u1');
      expect(kept.single.state, RouteStopOutboxState.needsAttention);
      expect(kept.single.lastError, isNotEmpty);
      expect(db.writes, isEmpty);
    },
  );

  test(
    'End Work ends the server session only after the stop events are sent',
    () async {
      final List<String> log = <String>[];
      final _Server server = _Server(log);
      bool eventsSent = false;
      final GpsProvider gps = GpsProvider(
        firestoreService: server,
        sendWaitingStopEvents:
            (String uid, UserModel? user, WorkSession session) async {
              log.add(
                'events:${session.status.name}:${session.endPendingSync}',
              );
              return eventsSent;
            },
      );
      addTearDown(gps.dispose);
      final WorkSessionStore store = WorkSessionStore(projectId: testProjectId);
      await store.write(_session());

      await gps.endWork(uid: 'u1', user: _user);

      expect(log, <String>['positions', 'events:ended:true']);
      expect(gps.state, GpsTrackingState.sessionEndPending);
      expect(gps.isTracking, isFalse);
      expect((await store.read('u1'))!.endPendingSync, isTrue);
      expect(server.status, 'active');

      log.clear();
      eventsSent = true;
      await gps.refreshTracking();
      await pumpEventQueue();

      expect(log, <String>['positions', 'events:ended:true', 'end']);
      expect(gps.state, GpsTrackingState.sessionEnded);
      expect((await store.read('u1'))!.endPendingSync, isFalse);
      expect(server.status, 'ended');
    },
  );

  test('End Work with no signal stops tracking and ends later', () async {
    final List<String> log = <String>[];
    final _Server server = _Server(log)..online = false;
    final GpsProvider gps = GpsProvider(
      firestoreService: server,
      sendWaitingStopEvents:
          (String uid, UserModel? user, WorkSession session) async {
            log.add('events');
            return true;
          },
    );
    addTearDown(gps.dispose);
    final WorkSessionStore store = WorkSessionStore(projectId: testProjectId);
    await store.write(_session());

    await gps.endWork(uid: 'u1', user: _user);

    expect(log, isEmpty);
    expect(gps.isTracking, isFalse);
    expect(gps.state, GpsTrackingState.sessionEndPending);
    expect((await store.read('u1'))!.status, WorkSessionLocalStatus.ended);

    server.online = true;
    await gps.refreshTracking();
    await pumpEventQueue();

    expect(log, <String>['positions', 'events', 'end']);
    expect(gps.state, GpsTrackingState.sessionEnded);
  });
}
