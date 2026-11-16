// ignore_for_file: subtype_of_sealed_class
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/models/work_session.dart';
import 'package:fmcg_sales/services/firestore_service.dart';
import 'package:fmcg_sales/services/gps_backlog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

const String sessionId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class BacklogDb implements FirebaseFirestore {
  BacklogDb(this.live);
  Map<String, dynamic>? live;
  final List<MapEntry<String, Map<String, dynamic>>> sets =
      <MapEntry<String, Map<String, dynamic>>>[];
  String? failAfterSets;
  String failCode = 'unavailable';
  @override
  FirebaseApp get app => Firebase.app();
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      BacklogCol(this, path);
  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> handler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) => handler(BacklogTx(this));
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('db ${i.memberName}');
}

class BacklogTx implements Transaction {
  BacklogTx(this.db);
  final BacklogDb db;
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> documentReference,
  ) async => BacklogSnap(db.live) as DocumentSnapshot<T>;
  @override
  Transaction set<T>(
    DocumentReference<T> documentReference,
    T data, [
    SetOptions? options,
  ]) {
    final Map<String, dynamic> map = data as Map<String, dynamic>;
    db.sets.add(
      MapEntry<String, Map<String, dynamic>>(documentReference.path, map),
    );
    if (documentReference.path.startsWith('live_tracking/')) {
      db.live = <String, dynamic>{...?db.live, ...map};
    }
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('tx ${i.memberName}');
}

class BacklogCol implements CollectionReference<Map<String, dynamic>> {
  BacklogCol(this.db, this.path);
  final BacklogDb db;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      BacklogDoc(db, '$path/$id');
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('col ${i.memberName}');
}

class BacklogDoc implements DocumentReference<Map<String, dynamic>> {
  BacklogDoc(this.db, this.path);
  final BacklogDb db;
  @override
  final String path;
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => BacklogSnap(db.live);
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    if (db.sets.length >= (int.tryParse(db.failAfterSets ?? '') ?? 1 << 30)) {
      throw FirebaseException(plugin: 'cloud_firestore', code: db.failCode);
    }
    db.sets.add(MapEntry<String, Map<String, dynamic>>(path, data));
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('doc ${i.memberName}');
}

class BacklogSnap implements DocumentSnapshot<Map<String, dynamic>> {
  BacklogSnap(this.value);
  final Map<String, dynamic>? value;
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('snap ${i.memberName}');
}

Object? plain(Object? value) {
  if (value is FieldValue) return '__serverTimestamp__';
  if (value is GeoPoint) {
    return <String, Object?>{
      '__geo__': <double>[value.latitude, value.longitude],
    };
  }
  if (value is DateTime) {
    return <String, Object?>{
      '__ageMs__': DateTime.now().difference(value).inMilliseconds,
    };
  }
  return value;
}

void main() {
  late DateTime now;
  late UserModel user;
  late GpsBacklogStore store;

  setUpAll(installTestFirebase);
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signInTestUser('sales-1');
    now = DateTime.now().toUtc();
    user = UserModel(
      uid: 'sales-1',
      staffId: 'S001',
      name: 'Rep',
      email: 'r@example.test',
      phone: '',
      territory: '',
      role: 'salesman',
      branchId: 'B1',
      joinedDate: '',
    );
    store = GpsBacklogStore(projectId: testProjectId);
    for (int sequence = 1; sequence <= 20; sequence++) {
      await store.add(
        'sales-1',
        GpsBacklogFix(
          sessionId: sessionId,
          generation: 1,
          fixSequence: sequence,
          latitude: 1.55 + sequence / 10000,
          longitude: 110.35,
          accuracyMeters: 12,
          deviceCapturedAt: now.subtract(
            Duration(seconds: (21 - sequence) * 20),
          ),
        ),
      );
    }
  });

  Map<String, dynamic> live({String status = 'active', int last = 21}) =>
      <String, dynamic>{
        'activeSessionId': sessionId,
        'activeSessionGeneration': 1,
        'workSessionStatus': status,
        'lastFixSequence': last,
        'deviceCapturedAt': now,
        'workSessionStartedAt': now.subtract(const Duration(minutes: 8)),
        if (status == 'ended') 'workSessionEndedAt': now,
      };

  test('20 fixes recorded offline are all written after reconnect', () async {
    final BacklogDb db = BacklogDb(live());
    final int written = await FirestoreService(
      firestore: db,
    ).flushGpsBacklog(user: user, store: store);
    expect(written, 20);
    expect(await store.readAll('sales-1'), isEmpty);
    expect(db.sets.map((e) => e.key).toList(), <String>[
      for (int s = 1; s <= 20; s++)
        'gps_tracking/session_sales-1_${sessionId}_$s',
    ]);
    expect(db.sets.every((e) => e.value['backlog'] == true), isTrue);
    final String? dump = Platform.environment['GPS_BACKLOG_DUMP'];
    if (dump != null) {
      File(dump).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'sessionId': sessionId,
          'docs': <Object?>[
            for (final e in db.sets)
              <String, Object?>{
                'path': e.key,
                'data': e.value.map(
                  (String k, Object? v) =>
                      MapEntry<String, Object?>(k, plain(v)),
                ),
              },
          ],
        }),
      );
    }
  });

  test('a flush that loses the network keeps the unsent fixes', () async {
    final BacklogDb db = BacklogDb(live())..failAfterSets = '7';
    final int written = await FirestoreService(
      firestore: db,
    ).flushGpsBacklog(user: user, store: store);
    expect(written, 7);
    expect((await store.readAll('sales-1')).length, 13);
  });

  test('fixes of another session are dropped, not written', () async {
    final Map<String, dynamic> other = live()
      ..['activeSessionId'] = 'cccccccccccccccccccccccccccccccc';
    final BacklogDb db = BacklogDb(other);
    final int written = await FirestoreService(
      firestore: db,
    ).flushGpsBacklog(user: user, store: store);
    expect(written, 0);
    expect(await store.readAll('sales-1'), isEmpty);
  });

  test('work ended while offline sends the whole offline track', () async {
    await store.removeAll('sales-1', await store.readAll('sales-1'));
    final DateTime lastOnline = now.subtract(const Duration(hours: 2));
    for (int sequence = 5; sequence <= 24; sequence++) {
      await store.add(
        'sales-1',
        GpsBacklogFix(
          sessionId: sessionId,
          generation: 1,
          fixSequence: sequence,
          latitude: 1.55 + sequence / 10000,
          longitude: 110.35,
          accuracyMeters: 12,
          deviceCapturedAt: lastOnline.add(
            Duration(minutes: 5 * (sequence - 4)),
          ),
        ),
      );
    }
    final BacklogDb db = BacklogDb(<String, dynamic>{
      ...live(last: 4),
      'deviceCapturedAt': lastOnline,
      'workSessionStartedAt': now.subtract(const Duration(hours: 3)),
    });
    final WorkSession session = WorkSession(
      uid: 'sales-1',
      sessionId: sessionId,
      generation: 1,
      lastFixSequence: 24,
      status: WorkSessionLocalStatus.ended,
      userDocumentId: 'sales-1',
    );
    final FirestoreService service = FirestoreService(firestore: db);
    await service.publishHeldTrack(user: user, session: session, store: store);
    await service.endWorkSession(
      uid: 'sales-1',
      sessionId: sessionId,
      generation: 1,
    );
    await service.flushHeldTrack(user: user, store: store);
    final List<String> crumbs = db.sets
        .map((e) => e.key)
        .where((String path) => path.startsWith('gps_tracking/'))
        .toList();
    expect(crumbs.length, 20);
    expect(db.live?['lastFixSequence'], 24);
    expect(await store.readAll('sales-1'), isEmpty);
  });

  test(
    'fixes after the 24 hour upload window are dropped with a reason',
    () async {
      gpsBacklogNotice.value = '';
      await store.removeAll('sales-1', await store.readAll('sales-1'));
      for (int sequence = 5; sequence <= 9; sequence++) {
        await store.add(
          'sales-1',
          GpsBacklogFix(
            sessionId: sessionId,
            generation: 1,
            fixSequence: sequence,
            latitude: 1.55,
            longitude: 110.35,
            accuracyMeters: 12,
            deviceCapturedAt: now.subtract(Duration(hours: 31 - sequence)),
          ),
        );
      }
      final Map<String, dynamic> ended = <String, dynamic>{
        ...live(status: 'ended'),
        'workSessionEndedAt': now.subtract(const Duration(hours: 25)),
        'deviceCapturedAt': now.subtract(const Duration(hours: 26)),
        'workSessionStartedAt': now.subtract(const Duration(hours: 28)),
        'lastFixSequence': 30,
      };
      final BacklogDb db = BacklogDb(ended);
      final int written = await FirestoreService(
        firestore: db,
      ).flushGpsBacklog(user: user, store: store);
      expect(written, 0);
      expect(db.sets, isEmpty);
      expect(await store.readAll('sales-1'), isEmpty);
      expect(gpsBacklogNotice.value, contains('24 hour upload window'));
    },
  );

  test(
    'fixes more than 500 sequences below the live fix are dropped',
    () async {
      final List<GpsBacklogFix> fixesNow = await store.readAll('sales-1');
      final GpsBacklogPlan plan = planGpsBacklog(
        fixesNow,
        GpsLiveSnapshot(
          sessionId: sessionId,
          generation: 1,
          status: 'active',
          lastFixSequence: 515,
          deviceCapturedAt: now,
          startedAt: now.subtract(const Duration(minutes: 8)),
        ),
        now,
      );
      expect(plan.drop.map((GpsBacklogFix f) => f.fixSequence), <int>[
        for (int s = 1; s <= 14; s++) s,
      ]);
      expect(plan.write.length, 6);
    },
  );

  test('a refused write is removed and reported', () async {
    gpsBacklogNotice.value = '';
    final BacklogDb db = BacklogDb(live())
      ..failAfterSets = '0'
      ..failCode = 'permission-denied';
    final int written = await FirestoreService(
      firestore: db,
    ).flushGpsBacklog(user: user, store: store);
    expect(written, 0);
    expect(await store.readAll('sales-1'), isEmpty);
    expect(gpsBacklogNotice.value, contains('the server refused it'));
    expect(gpsBacklogNotice.value, contains('permission-denied'));
  });
}
