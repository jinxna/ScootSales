import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/master_data_hygiene.dart';
import '../utils/order_data_utils.dart';

class MasterDataHygieneService {
  MasterDataHygieneService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Future<List<HygieneIssue>> loadIssues() async {
    final List<QuerySnapshot<Map<String, dynamic>>> snapshots =
        await Future.wait(<Future<QuerySnapshot<Map<String, dynamic>>>>[
          _firestore.collection('products').limit(2000).get(),
          _firestore.collection('retailers').limit(2000).get(),
          _firestore.collection('users').limit(1000).get(),
          _firestore.collection('orders').limit(1500).get(),
        ]);
    List<Map<String, dynamic>> rows(int index) => snapshots[index].docs
        .map(
          (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
              <String, dynamic>{'docId': document.id, ...document.data()},
        )
        .where((Map<String, dynamic> row) => !isDemoRow(row))
        .toList(growable: false);
    return detectMasterDataIssues(
      products: rows(0),
      retailers: rows(1),
      users: rows(2),
      orders: rows(3),
    );
  }
}
