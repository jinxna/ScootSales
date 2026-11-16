// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/services/visit_submission.dart';

class Db implements FirebaseFirestore {
  final Map<String, Map<String, dynamic>> orders =
      <String, Map<String, dynamic>>{};
  final List<String> updates = <String>[];
  final Map<String, Map<Object, Object?>> lastUpdate =
      <String, Map<Object, Object?>>{};
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      Col(this, path, <String, Object?>{});
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class Col implements CollectionReference<Map<String, dynamic>> {
  Col(this.db, this.path, this.filters);
  final Db db;
  @override
  final String path;
  final Map<String, Object?> filters;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      Doc(db, '$path/$id');
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #where) {
      final String field = i.positionalArguments.first as String;
      final Map<String, Object?> next = <String, Object?>{...filters};
      next['$field=='] = i.namedArguments[#isEqualTo];
      next['${field}in'] = i.namedArguments[#whereIn];
      return Col(db, path, next);
    }
    if (i.memberName == #get) {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
          <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      db.orders.forEach((String id, Map<String, dynamic> data) {
        final Object? uid = filters['salesmanUid=='];
        final List<Object?> ids = (filters['visitIdin'] as List?) ?? const [];
        if (data['salesmanUid'] == uid && ids.contains(data['visitId'])) {
          docs.add(QDoc(id, data));
        }
      });
      return Future<QuerySnapshot<Map<String, dynamic>>>.value(QSnap(docs));
    }
    throw UnimplementedError('col $i');
  }
}

class Doc implements DocumentReference<Map<String, dynamic>> {
  Doc(this.db, this.path);
  final Db db;
  @override
  final String path;
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #update) {
      db.updates.add(path);
      db.lastUpdate[path] = i.positionalArguments.first as Map<Object, Object?>;
      return Future<void>.value();
    }
    throw UnimplementedError('doc $i');
  }
}

class QSnap implements QuerySnapshot<Map<String, dynamic>> {
  QSnap(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class QDoc implements QueryDocumentSnapshot<Map<String, dynamic>> {
  QDoc(this.id, this._data);
  @override
  final String id;
  final Map<String, dynamic> _data;
  @override
  Map<String, dynamic> data() => _data;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

void main() {
  test(
    'the planner repair never marks an already submitted visit again and writes each visit once, for its newest order',
    () async {
      final Db db = Db();
      db.orders['o1'] = <String, dynamic>{'salesmanUid': 'u1', 'visitId': 'v1'};
      db.orders['oA'] = <String, dynamic>{
        'salesmanUid': 'u1',
        'visitId': 'v3',
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 11, 8, 9)),
      };
      db.orders['oB'] = <String, dynamic>{
        'salesmanUid': 'u1',
        'visitId': 'v3',
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 11, 8, 8)),
      };
      db.orders['oX'] = <String, dynamic>{'salesmanUid': 'u2', 'visitId': 'v4'};
      final int repaired = await repairSubmittedVisits(
        db,
        uid: 'u1',
        visits: <QueryDocumentSnapshot<Map<String, dynamic>>>[
          QDoc('v1', <String, dynamic>{
            'status': 'counting',
            'draftStage': 2,
            'submittedOrderId': 'o1',
            'cartDraftItems': <Object>[
              <String, Object>{'productId': 'p9', 'qty': 3},
            ],
          }),
          QDoc('v3', <String, dynamic>{'status': 'counting'}),
          QDoc('v4', <String, dynamic>{'status': 'counting'}),
        ],
      );
      expect(db.updates, <String>['visits/v3']);
      expect(db.lastUpdate['visits/v3']?['submittedOrderId'], 'oA');
      expect(repaired, 1);
    },
  );

  test(
    'the repair never links an order older than the linked one and keeps the cart of a new order being made',
    () async {
      final Db db = Db();
      db.orders['o0'] = <String, dynamic>{
        'salesmanUid': 'u1',
        'visitId': 'v7',
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 11, 8, 8)),
      };
      db.orders['o1'] = <String, dynamic>{
        'salesmanUid': 'u1',
        'visitId': 'v7',
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 11, 8, 9)),
      };
      final int repaired = await repairSubmittedVisits(
        db,
        uid: 'u1',
        visits: <QueryDocumentSnapshot<Map<String, dynamic>>>[
          QDoc('v7', <String, dynamic>{
            'status': 'counting',
            'draftStage': 2,
            'submittedOrderId': 'o1',
            'cartDraftItems': <Object>[
              <String, Object>{'productId': 'p9', 'qty': 3},
            ],
          }),
        ],
      );
      expect(db.updates, isEmpty);
      expect(repaired, 0);
    },
  );
}
