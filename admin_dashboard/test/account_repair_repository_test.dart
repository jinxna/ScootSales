// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/repositories/account_repair_repository.dart';
import 'package:flutter_web_app/utils/account_repair_analysis.dart';

void main() {
  const UserProfile admin = UserProfile(
    docId: 'admin',
    uid: 'admin-uid',
    email: 'admin@example.com',
    name: 'Admin',
    role: UserProfile.roleAdmin,
    employeeCode: 'A001',
    status: UserProfile.statusActive,
  );

  test(
    'invalid UID link cannot be cleared when supervisor profile lacks access',
    () async {
      final Map<String, dynamic> salesman = <String, dynamic>{
        'uid': 'sales-uid',
        'role': 'salesman',
        'branchId': 'KCH',
        'employeeCode': 'S001',
        'supervisorId': 'SV001',
        'supervisorUid': 'supervisor-uid',
      };
      final _FakeFirestore firestore = _FakeFirestore(
        <String, Map<String, dynamic>>{
          'users/SV001': <String, dynamic>{
            'uid': 'supervisor-uid',
            'role': 'supervisor',
            'employeeCode': 'SV001',
          },
          'users/S001': salesman,
          'user_access/sales-uid': <String, dynamic>{
            'uid': 'sales-uid',
            'userDocId': 'S001',
            'role': 'salesman',
            'supervisorUid': 'supervisor-uid',
          },
        },
      );

      await expectLater(
        FirestoreAccountRepairRepository(firestore: firestore).repair(
          const AccountRepairFinding(
            kind: AccountRepairFindingKind.invalidSalesmanSupervisor,
            recordId: 'S001',
            relatedId: 'supervisor-uid',
            title: 'stale scan',
            description: 'fabricated repairable finding',
            canRepair: true,
          ),
          actor: admin,
        ),
        throwsStateError,
      );
      expect(firestore.writeCount, 0);
      expect(
        firestore.documents['users/S001']?['supervisorUid'],
        'supervisor-uid',
      );
    },
  );

  test(
    'supervisor profile found by code cannot be cleared from a fabricated finding',
    () async {
      final _FakeFirestore firestore = _FakeFirestore(
        <String, Map<String, dynamic>>{
          'users/legacy-supervisor': <String, dynamic>{
            'role': 'supervisor',
            'employeeCode': 'SV-LEGACY',
          },
          'users/S001': <String, dynamic>{
            'uid': 'sales-uid',
            'role': 'salesman',
            'branchId': 'KCH',
            'employeeCode': 'S001',
            'supervisorId': 'SV-LEGACY',
            'supervisor_id': 'SV-LEGACY',
            'supervisorUid': 'former-supervisor',
          },
          'user_access/sales-uid': <String, dynamic>{
            'uid': 'sales-uid',
            'userDocId': 'S001',
            'role': 'salesman',
            'supervisorUid': 'former-supervisor',
          },
        },
      );

      await expectLater(
        FirestoreAccountRepairRepository(firestore: firestore).repair(
          const AccountRepairFinding(
            kind: AccountRepairFindingKind.invalidSalesmanSupervisor,
            recordId: 'S001',
            relatedId: 'former-supervisor',
            title: 'stale scan',
            description: 'fabricated repairable finding',
            canRepair: true,
          ),
          actor: admin,
        ),
        throwsStateError,
      );
      expect(firestore.writeCount, 0);
      expect(
        firestore.documents['users/S001']?['supervisorUid'],
        'former-supervisor',
      );
      expect(firestore.documents['users/S001']?['supervisorId'], 'SV-LEGACY');
    },
  );
}

class _FakeFirestore implements FirebaseFirestore {
  _FakeFirestore(this.documents);
  final Map<String, Map<String, dynamic>> documents;
  int writeCount = 0;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _FakeCollection(this, path);

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(Transaction) handler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) => handler(_FakeTransaction(this));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCollection extends _FakeQuery
    implements CollectionReference<Map<String, dynamic>> {
  _FakeCollection(super.firestore, super.collectionName);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _FakeDocument(firestore, '$collectionName/${path ?? ''}');
}

class _FakeQuery implements Query<Map<String, dynamic>> {
  _FakeQuery(
    this.firestore, [
    this.collectionName = '',
    this.filters = const {},
    this.maxResults,
  ]);
  @override
  final _FakeFirestore firestore;
  final String collectionName;
  final Map<String, Object?> filters;
  final int? maxResults;

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
  }) => _FakeQuery(firestore, collectionName, <String, Object?>{
    ...filters,
    field.toString(): isEqualTo,
  }, maxResults);

  @override
  Query<Map<String, dynamic>> limit(int limit) =>
      _FakeQuery(firestore, collectionName, filters, limit);

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    Iterable<MapEntry<String, Map<String, dynamic>>> rows = firestore
        .documents
        .entries
        .where((MapEntry<String, Map<String, dynamic>> entry) {
          if (!entry.key.startsWith('$collectionName/')) return false;
          for (final MapEntry<String, Object?> filter in filters.entries) {
            if (entry.value[filter.key] != filter.value) return false;
          }
          return true;
        });
    if (maxResults case final int limit) rows = rows.take(limit);
    return _FakeQuerySnapshot(
      rows.map((MapEntry<String, Map<String, dynamic>> entry) {
        final String id = entry.key.substring(collectionName.length + 1);
        return _FakeQueryDocument(id, entry.value);
      }).toList(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDocument implements DocumentReference<Map<String, dynamic>> {
  _FakeDocument(this.firestore, this.path);
  @override
  final _FakeFirestore firestore;
  @override
  final String path;

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => _FakeDocumentSnapshot(firestore.documents[path]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDocumentSnapshot implements DocumentSnapshot<Map<String, dynamic>> {
  _FakeDocumentSnapshot(this.value);
  final Map<String, dynamic>? value;

  @override
  bool get exists => value != null;

  @override
  Map<String, dynamic>? data() => value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeQueryDocument extends _FakeDocumentSnapshot
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _FakeQueryDocument(this.id, super.value);
  @override
  final String id;

  @override
  Map<String, dynamic> data() => value!;
}

class _FakeQuerySnapshot implements QuerySnapshot<Map<String, dynamic>> {
  _FakeQuerySnapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTransaction implements Transaction {
  _FakeTransaction(this.firestore);
  final _FakeFirestore firestore;

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> reference,
  ) async {
    final _FakeDocument document = reference as _FakeDocument;
    return _FakeDocumentSnapshot(firestore.documents[document.path])
        as DocumentSnapshot<T>;
  }

  @override
  Transaction set<T>(
    DocumentReference<T> reference,
    T data, [
    SetOptions? options,
  ]) {
    final _FakeDocument document = reference as _FakeDocument;
    firestore.documents[document.path] = Map<String, dynamic>.from(data as Map);
    firestore.writeCount++;
    return this;
  }

  @override
  Transaction update(
    DocumentReference<Object?> reference,
    Map<Object, Object?> data,
  ) {
    final _FakeDocument document = reference as _FakeDocument;
    firestore.documents[document.path] = <String, dynamic>{
      ...?firestore.documents[document.path],
      ...data.cast<String, dynamic>(),
    };
    firestore.writeCount++;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
