// ignore_for_file: subtype_of_sealed_class
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/follow_up_promise.dart';
import 'package:fmcg_sales/services/follow_up_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

class CacheDb implements FirebaseFirestore {
  CacheDb({
    this.cached = const <String, Map<String, dynamic>>{},
    this.cacheErrorCode = '',
    this.serverErrorCode = '',
    this.cacheTimesOut = false,
    this.serverTimesOut = false,
    this.cacheTimeoutIds = const <String>{},
  });

  final Map<String, Map<String, dynamic>> cached;
  final String cacheErrorCode;
  final String serverErrorCode;
  final bool cacheTimesOut;
  final bool serverTimesOut;
  final Set<String> cacheTimeoutIds;

  @override
  FirebaseApp get app => Firebase.app();

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      CacheCol(this);

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('db ${i.memberName}');
}

class CacheCol implements CollectionReference<Map<String, dynamic>> {
  CacheCol(this.db);
  final CacheDb db;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      CacheDoc(db, '$id');

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) => this;

  @override
  Query<Map<String, dynamic>> orderBy(
    Object field, {
    bool descending = false,
  }) => this;

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future<QuerySnapshot<Map<String, dynamic>>>.error(
        db.serverTimesOut
            ? TimeoutException('server read')
            : FirebaseException(
                plugin: 'cloud_firestore',
                code: db.serverErrorCode,
              ),
      );

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('col ${i.memberName}');
}

class CacheDoc implements DocumentReference<Map<String, dynamic>> {
  CacheDoc(this.db, this.id);
  final CacheDb db;
  @override
  final String id;

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    if (options?.source != Source.cache) {
      throw StateError('a follow-up must be reconciled from the cache only');
    }
    if (db.cacheTimesOut || db.cacheTimeoutIds.contains(id)) {
      throw TimeoutException('cache read');
    }
    if (db.cacheErrorCode.isNotEmpty) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: db.cacheErrorCode,
      );
    }
    return CacheSnapshot(id, db.cached[id]);
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('doc ${i.memberName}');
}

class CacheSnapshot implements DocumentSnapshot<Map<String, dynamic>> {
  CacheSnapshot(this.id, this._data);
  @override
  final String id;
  final Map<String, dynamic>? _data;

  @override
  Map<String, dynamic>? data() => _data;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('snapshot ${i.memberName}');
}

Map<String, dynamic> outcome(String id, {String status = 'open'}) =>
    <String, dynamic>{
      'outcomeId': id,
      'salesmanUid': 'sales-1',
      'retailerId': 'retailer-$id',
      'retailerName': 'Retailer $id',
      'reasonCode': 'retailer_busy',
      'followUpDate': '2026-12-01',
      'followUpStatus': status,
    };

Future<void> saveOpen(CacheDb db, List<String> ids) async {
  final FollowUpService service = FollowUpService(firestore: db);
  for (final String id in ids) {
    await service.remember('sales-1', outcome(id));
  }
}

Future<List<String>> shown(CacheDb db, {required bool online}) async =>
    <String>[
      for (final FollowUpPromise one in await FollowUpService(
        firestore: db,
      ).openPromises('sales-1', online: online))
        one.outcomeId,
    ];

void main() {
  setUpAll(installTestFirebase);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signInTestUser('sales-1');
  });

  test(
    'offline, a saved follow-up the cache says is done is not shown',
    () async {
      final CacheDb db = CacheDb(
        cached: <String, Map<String, dynamic>>{
          'a': outcome('a', status: 'completed'),
        },
      );
      await saveOpen(db, <String>['a']);
      expect(await shown(db, online: false), isEmpty);
    },
  );

  test(
    'offline, a saved follow-up the cache says is cancelled is not shown',
    () async {
      final CacheDb db = CacheDb(
        cached: <String, Map<String, dynamic>>{
          'a': outcome('a', status: 'cancelled'),
        },
      );
      await saveOpen(db, <String>['a']);
      expect(await shown(db, online: false), isEmpty);
    },
  );

  test('offline, only the saved follow-ups that are still open stay', () async {
    final CacheDb db = CacheDb(
      cached: <String, Map<String, dynamic>>{
        'a': outcome('a', status: 'completed'),
        'b': outcome('b'),
      },
    );
    await saveOpen(db, <String>['a', 'b', 'c']);
    expect(await shown(db, online: false), <String>['b', 'c']);
  });

  test(
    'offline, a saved follow-up with no cached copy is still shown',
    () async {
      final CacheDb db = CacheDb();
      await saveOpen(db, <String>['a']);
      expect(await shown(db, online: false), <String>['a']);
    },
  );

  test('offline, an unavailable cache keeps the saved follow-ups', () async {
    final CacheDb db = CacheDb(cacheErrorCode: 'unavailable');
    await saveOpen(db, <String>['a']);
    expect(await shown(db, online: false), <String>['a']);
  });

  test('offline, any other cache error keeps the saved follow-ups', () async {
    final CacheDb db = CacheDb(cacheErrorCode: 'permission-denied');
    await saveOpen(db, <String>['a']);
    expect(await shown(db, online: false), <String>['a']);
  });

  test(
    'online with a failed server read, a done follow-up is not shown',
    () async {
      final CacheDb db = CacheDb(
        serverErrorCode: 'unavailable',
        cached: <String, Map<String, dynamic>>{
          'a': outcome('a', status: 'completed'),
          'b': outcome('b'),
        },
      );
      await saveOpen(db, <String>['a', 'b']);
      expect(await shown(db, online: true), <String>['b']);
    },
  );

  test(
    'offline, a cache read that times out keeps the saved follow-ups',
    () async {
      final CacheDb db = CacheDb(cacheTimesOut: true);
      await saveOpen(db, <String>['a']);
      expect(await shown(db, online: false), <String>['a']);
    },
  );

  test(
    'online with a timed-out server read, a done follow-up is not shown',
    () async {
      final CacheDb db = CacheDb(
        serverTimesOut: true,
        cached: <String, Map<String, dynamic>>{
          'a': outcome('a', status: 'completed'),
          'b': outcome('b'),
        },
      );
      await saveOpen(db, <String>['a', 'b']);
      expect(await shown(db, online: true), <String>['b']);
    },
  );

  test(
    'offline, one cache read that times out keeps the other rows reconciled',
    () async {
      final CacheDb db = CacheDb(
        cacheTimeoutIds: <String>{'b'},
        cached: <String, Map<String, dynamic>>{
          'a': outcome('a', status: 'completed'),
        },
      );
      await saveOpen(db, <String>['a', 'b']);
      expect(await shown(db, online: false), <String>['b']);
    },
  );
}
