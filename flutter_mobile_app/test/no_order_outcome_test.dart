// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/follow_up_promise.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/services/follow_up_service.dart';
import 'package:fmcg_sales/services/sales_visit_copilot_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

class OutcomeDb implements FirebaseFirestore {
  OutcomeDb([Map<String, Map<String, dynamic>>? docs])
    : docs = docs ?? <String, Map<String, dynamic>>{};

  final Map<String, Map<String, dynamic>> docs;
  final List<String> writes = <String>[];
  String failSetWith = '';
  String failUpdateWith = '';
  @override
  FirebaseApp get app => Firebase.app();
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      OutcomeCol(this, path);
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('db ${i.memberName}');
}

class OutcomeCol implements CollectionReference<Map<String, dynamic>> {
  OutcomeCol(this.db, this.path);
  final OutcomeDb db;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      OutcomeDoc(db, '$path/$id');
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('col ${i.memberName}');
}

class OutcomeDoc implements DocumentReference<Map<String, dynamic>> {
  OutcomeDoc(this.db, this.path);
  final OutcomeDb db;
  @override
  final String path;
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    if (db.failSetWith.isNotEmpty) {
      throw FirebaseException(plugin: 'cloud_firestore', code: db.failSetWith);
    }
    db.writes.add('set');
    db.docs[path] = data;
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    if (db.failUpdateWith.isNotEmpty) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: db.failUpdateWith,
      );
    }
    db.writes.add('update');
    db.docs[path] = <String, dynamic>{
      ...?db.docs[path],
      for (final MapEntry<Object, Object?> entry in data.entries)
        '${entry.key}': entry.value,
    };
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('doc ${i.memberName}');
}

UserModel salesman() => UserModel(
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

Future<OutcomeQueueResult> queue(
  SalesVisitCopilotService service, {
  String reason = 'retailer_busy',
  String note = '',
  bool online = true,
  DateTime? followUpOn,
}) => service.queueNoOrderOutcome(
  user: salesman(),
  branchId: 'B1',
  planId: 'route-own',
  stopId: 'stop-1',
  retailerId: 'retailer-1',
  retailerName: 'Retailer One',
  reasonCode: reason,
  note: note,
  isDemo: false,
  isOnline: online,
  followUpOn: followUpOn,
);

DateTime inDays(int days) {
  final DateTime now = DateTime.now();
  return DateTime(now.year, now.month, now.day + days);
}

void main() {
  setUpAll(installTestFirebase);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signInTestUser('sales-1');
  });

  test('offline it stays queued for the next sync', () async {
    final OutcomeDb db = OutcomeDb();
    final SalesVisitCopilotService service = SalesVisitCopilotService(
      firestore: db,
    );
    final OutcomeQueueResult result = await queue(service, online: false);
    expect(result.synced, isFalse);
    expect(service.pendingCount, 1);
    expect(db.docs, isEmpty);
    await service.flushPending(isOnline: true, force: true);
    expect(service.pendingCount, 0);
    expect(db.docs.length, 1);
  });

  test('a reason with no date writes the outcome only', () async {
    final OutcomeDb db = OutcomeDb();
    final SalesVisitCopilotService service = SalesVisitCopilotService(
      firestore: db,
    );
    final OutcomeQueueResult result = await queue(service);
    expect(result.synced, isTrue);
    expect(db.writes, <String>['set']);
    final Map<String, dynamic> stored = db.docs.values.single;
    expect(stored['outcomeKind'], 'no_order');
    expect(stored.containsKey('productId'), isFalse);
    expect(stored.containsKey('issueId'), isFalse);
    expect(stored.keys.where((String key) => key.startsWith('followUp')), []);
    expect(
      await FollowUpService(
        firestore: db,
      ).openPromises('sales-1', online: false),
      isEmpty,
    );
  });

  test(
    'a follow-up date is sent after its outcome, to the same document',
    () async {
      final OutcomeDb db = OutcomeDb();
      final SalesVisitCopilotService service = SalesVisitCopilotService(
        firestore: db,
      );
      final DateTime day = inDays(8);
      final OutcomeQueueResult result = await queue(service, followUpOn: day);
      expect(result.synced, isTrue);
      expect(db.writes, <String>['set', 'update']);
      expect(db.docs.keys.single, 'conversation_outcomes/${result.outcomeId}');
      final Map<String, dynamic> stored = db.docs.values.single;
      expect(stored['followUpDate'], followUpDateKey(day));
      expect(
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch('${stored['followUpDate']}'),
        isTrue,
      );
      expect(stored['followUpStatus'], 'open');
      expect(stored.containsKey('followUpTime'), isFalse);
      expect(service.pendingCount, 0);
      final List<FollowUpPromise> saved = await FollowUpService(
        firestore: db,
      ).openPromises('sales-1', online: false);
      expect(saved.single.shop, 'Retailer One');
      expect(saved.single.dateKey, followUpDateKey(day));
    },
  );

  test(
    'with no signal the promise is kept, shown, and sent in order later',
    () async {
      final OutcomeDb db = OutcomeDb();
      final SalesVisitCopilotService service = SalesVisitCopilotService(
        firestore: db,
      );
      final DateTime day = inDays(3);
      await queue(service, online: false, followUpOn: day);
      expect(db.writes, isEmpty);
      final List<FollowUpPromise> held = await FollowUpService(
        firestore: db,
      ).openPromises('sales-1', online: false);
      expect(held.single.dateKey, followUpDateKey(day));
      expect(held.single.about, 'retailer busy');

      final OutcomeDb restarted = OutcomeDb(db.docs);
      final SalesVisitCopilotService later = SalesVisitCopilotService(
        firestore: restarted,
      );
      await later.initialiseForUser('sales-1');
      expect(later.pendingCount, 1);
      await later.flushPending(isOnline: true, force: true);
      expect(restarted.writes, <String>['set', 'update']);
      expect(later.pendingCount, 0);
      expect(db.docs.values.single['followUpStatus'], 'open');
    },
  );

  test(
    'a stop between the two writes keeps the promise and never repeats the outcome',
    () async {
      final OutcomeDb db = OutcomeDb()..failUpdateWith = 'unavailable';
      final SalesVisitCopilotService service = SalesVisitCopilotService(
        firestore: db,
      );
      final DateTime day = inDays(5);
      final OutcomeQueueResult result = await queue(service, followUpOn: day);
      expect(result.synced, isFalse);
      expect(db.writes, <String>['set']);
      expect(db.docs.values.single.containsKey('followUpDate'), isFalse);
      expect(service.pendingCount, 1);
      expect(service.stuckOutcomes, isEmpty);

      final OutcomeDb restarted = OutcomeDb(db.docs);
      final SalesVisitCopilotService later = SalesVisitCopilotService(
        firestore: restarted,
      );
      await later.initialiseForUser('sales-1');
      expect(later.pendingCount, 1);
      await later.flushPending(isOnline: true, force: true);
      expect(restarted.writes, <String>['update']);
      expect(db.docs.values.single['followUpDate'], followUpDateKey(day));
      expect(db.docs.values.single['followUpStatus'], 'open');
      expect(later.pendingCount, 0);
    },
  );

  test(
    'a refused outcome never sends its follow-up and shows the refusal',
    () async {
      final OutcomeDb db = OutcomeDb()..failSetWith = 'invalid-argument';
      final SalesVisitCopilotService service = SalesVisitCopilotService(
        firestore: db,
      );
      await queue(service, followUpOn: inDays(2));
      expect(db.writes, isEmpty);
      expect(service.stuckOutcomes.single.lastError, contains('refused'));
      db.failSetWith = '';
      await service.flushPending(isOnline: true, force: true);
      expect(db.writes, isEmpty);
      expect(
        await FollowUpService(
          firestore: db,
        ).openPromises('sales-1', online: false),
        isEmpty,
      );
      await service.discardOutcome(service.stuckOutcomes.single.operationId);
      expect(service.stuckOutcomes, isEmpty);
      await service.flushPending(isOnline: true, force: true);
      expect(db.writes, isEmpty);
    },
  );

  test('a refused follow-up date keeps the outcome and says so', () async {
    final OutcomeDb db = OutcomeDb()..failUpdateWith = 'invalid-argument';
    final SalesVisitCopilotService service = SalesVisitCopilotService(
      firestore: db,
    );
    await queue(service, followUpOn: inDays(2));
    expect(db.writes, <String>['set']);
    expect(
      service.stuckOutcomes.single.lastError,
      SalesVisitCopilotService.followUpRefusedMessage,
    );
  });

  test(
    'a date before today or more than 60 days ahead is not accepted',
    () async {
      final OutcomeDb db = OutcomeDb();
      final SalesVisitCopilotService service = SalesVisitCopilotService(
        firestore: db,
      );
      await expectLater(
        queue(service, followUpOn: inDays(-1)),
        throwsArgumentError,
      );
      await expectLater(
        queue(service, followUpOn: inDays(61)),
        throwsArgumentError,
      );
      await queue(service, followUpOn: inDays(0));
      await queue(service, followUpOn: inDays(60));
      expect(db.writes, <String>['set', 'update', 'set', 'update']);
    },
  );

  test(
    'another account on the same phone does not send or see the promise',
    () async {
      final OutcomeDb db = OutcomeDb();
      final SalesVisitCopilotService service = SalesVisitCopilotService(
        firestore: db,
      );
      await queue(service, online: false, followUpOn: inDays(4));
      signInTestUser('sales-2');
      await service.flushPending(isOnline: true, force: true);
      expect(db.writes, isEmpty);
      final SalesVisitCopilotService other = SalesVisitCopilotService(
        firestore: OutcomeDb(db.docs),
      );
      await other.initialiseForUser('sales-2');
      await other.flushPending(isOnline: true, force: true);
      expect(other.pendingCount, 0);
      expect(db.docs, isEmpty);
      expect(
        await FollowUpService(
          firestore: db,
        ).openPromises('sales-2', online: false),
        isEmpty,
      );
    },
  );

  test(
    'mark as done changes only the status, also after a restart with no signal',
    () async {
      final Map<String, Map<String, dynamic>> docs =
          <String, Map<String, dynamic>>{
            'conversation_outcomes/seeded-1': <String, dynamic>{
              'outcomeId': 'seeded-1',
              'salesmanUid': 'sales-1',
              'retailerId': 'retailer-1',
              'retailerName': 'Retailer One',
              'reasonCode': 'retailer_busy',
              'followUpDate': '2026-11-26',
              'followUpStatus': 'open',
            },
          };
      final OutcomeDb db = OutcomeDb(docs);
      final SalesVisitCopilotService service = SalesVisitCopilotService(
        firestore: db,
      );
      final FollowUpPromise promise = FollowUpPromise.fromOutcome(
        docs.values.single,
      )!;
      await service.markFollowUpDone(
        user: salesman(),
        promise: promise,
        isOnline: false,
      );
      expect(db.writes, isEmpty);
      final OutcomeDb restarted = OutcomeDb(docs);
      final SalesVisitCopilotService later = SalesVisitCopilotService(
        firestore: restarted,
      );
      await later.initialiseForUser('sales-1');
      expect(later.pendingCount, 1);
      await later.flushPending(isOnline: true, force: true);
      expect(restarted.writes, <String>['update']);
      expect(docs.values.single, <String, dynamic>{
        'outcomeId': 'seeded-1',
        'salesmanUid': 'sales-1',
        'retailerId': 'retailer-1',
        'retailerName': 'Retailer One',
        'reasonCode': 'retailer_busy',
        'followUpDate': '2026-11-26',
        'followUpStatus': 'completed',
      });
      expect(later.pendingCount, 0);
    },
  );
}
