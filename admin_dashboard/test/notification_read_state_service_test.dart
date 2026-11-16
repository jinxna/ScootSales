// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/services/notification_read_state_service.dart';

void main() {
  test('rejects a path that could escape the owner document', () async {
    final NotificationReadStateService service = NotificationReadStateService(
      firestore: _Database(null),
      authUid: 'user/other',
    );

    expect(service.load(), throwsArgumentError);
  });
}

class _Database implements FirebaseFirestore {
  _Database(this.data);

  Map<String, dynamic>? data;
  String? collectionPath;
  String? documentPath;
  SetOptions? options;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    collectionPath = path;
    return _Collection(this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Collection implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.database);

  final _Database database;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    database.documentPath = path;
    return _Document(database);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Document implements DocumentReference<Map<String, dynamic>> {
  _Document(this.database);

  final _Database database;

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    return _Snapshot(database.data);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    database.data = <String, dynamic>{...data};
    database.options = options;
  }

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    return Stream<DocumentSnapshot<Map<String, dynamic>>>.value(
      _Snapshot(database.data),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Snapshot implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.value);

  final Map<String, dynamic>? value;

  @override
  bool get exists => value != null;

  @override
  Map<String, dynamic>? data() => value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
