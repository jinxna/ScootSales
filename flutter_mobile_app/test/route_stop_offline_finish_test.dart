// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/assigned_route_plan.dart';
import 'package:fmcg_sales/models/route_stop_lifecycle_event.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/models/work_session.dart';
import 'package:fmcg_sales/services/route_plan_service.dart';
import 'package:fmcg_sales/services/route_stop_outbox.dart';
import 'package:fmcg_sales/services/work_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

class _Db implements FirebaseFirestore {
  bool online = false;
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
  SnapshotMetadata get metadata => _ServerMetadata();
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('snap ${i.memberName}');
}

class _ServerMetadata implements SnapshotMetadata {
  @override
  bool get hasPendingWrites => false;
  @override
  bool get isFromCache => false;
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('metadata ${i.memberName}');
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

void main() {
  setUpAll(installTestFirebase);

  for (final bool retryWithLocalSnapshot in <bool>[false, true]) {
    test(
      retryWithLocalSnapshot
          ? 'FIX-282 queued events upload in order when the phone still shows its own arrival'
          : 'FIX-282 a visit can be finished offline and its events upload in order',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        signInTestUser('u1');
        final _Db db = _Db();
        final AssignedRoutePlan plan = AssignedRoutePlan.fromMap(
          'p1',
          <String, dynamic>{
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
          },
        );
        final UserModel user = UserModel(
          uid: 'u1',
          staffId: 'S1',
          name: 'Ali',
          email: 'a@b.c',
          phone: '1',
          territory: 't',
          role: 'salesman',
          joinedDate: '2026-01-01',
        );
        final WorkSession session = WorkSession(
          uid: 'u1',
          sessionId: 'w1',
          generation: 1,
          lastFixSequence: 0,
          lastRouteStopEventSequence: 1,
          status: WorkSessionLocalStatus.active,
          deviceStartedAt: DateTime.now().toUtc(),
        );
        await WorkSessionStore(projectId: testProjectId).write(session);
        final RouteStopOutbox outbox = RouteStopOutbox(
          projectId: testProjectId,
        );
        await outbox.put(
          RouteStopLifecycleEvent(
            uid: 'u1',
            planId: 'p1',
            stopId: 's1',
            workSessionId: 'w1',
            workSessionGeneration: 1,
            sessionEventSequence: 1,
            eventId: 'w1_s1_arrived',
            status: 'arrived',
            deviceOccurredAt: DateTime.now().toUtc(),
            payload: <String, dynamic>{},
            expectedSelectedStopId: 's1',
            expectedSelectionRevision: 1,
            sessionDeviceStartedAt: session.deviceStartedAt,
          ),
        );
        final RoutePlanService service = RoutePlanService(firestore: db);
        final RouteProgress arrivedLocally = RouteProgress.fromMap(
          <String, dynamic>{
            'status': 'in_progress',
            'selectedStopId': 's1',
            'selectionRevision': 1,
            'stopProgress': <String, dynamic>{
              's1': <String, dynamic>{'status': 'arrived'},
            },
          },
          hasPendingWrites: true,
        );

        final RouteProgressWriteState offline = await service.updateStopStatus(
          plan: plan,
          stop: plan.stops.single,
          user: user,
          progress: arrivedLocally,
          status: 'completed',
        );
        expect(offline, RouteProgressWriteState.pending);
        final List<RouteStopLifecycleEvent> queued = await outbox.readForUid(
          'u1',
        );
        expect(
          queued.map((RouteStopLifecycleEvent e) => e.status).toList(),
          <String>['arrived', 'completed'],
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
        final RouteProgress confirmed = RouteProgress.fromMap(
          db.docs['route_plan_progress/p1_u1'],
        );
        await service.retryPendingStopEvents(
          plan: plan,
          user: user,
          progress: retryWithLocalSnapshot ? arrivedLocally : confirmed,
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
  }
}
