// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/services/sales_visit_copilot_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

class OutcomeDb implements FirebaseFirestore {
  final Map<String, Map<String, dynamic>> docs =
      <String, Map<String, dynamic>>{};
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
    db.docs[path] = data;
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
);

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
}
