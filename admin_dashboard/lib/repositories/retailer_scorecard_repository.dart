import 'package:cloud_firestore/cloud_firestore.dart';

import '../app_runtime.dart';
import '../models/user_profile.dart';

class RetailerScorecardRepository {
  RetailerScorecardRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  static const int _pageSize = 250;

  Future<RetailerScorecardSource> load(UserProfile currentUser) async {
    if (!currentUser.isAdmin) {
      throw StateError('This report is available to Admin users only.');
    }
    if (!AppRuntime.firebaseReady) {
      throw StateError('Firebase is not ready. Reconnect and retry.');
    }
    final List<Map<String, dynamic>> orders = await _readAll('orders');
    final List<Map<String, dynamic>> products = await _readAll('products');
    return RetailerScorecardSource(orders: orders, products: products);
  }

  Future<List<Map<String, dynamic>>> _readAll(String collectionName) async {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    DocumentSnapshot<Map<String, dynamic>>? cursor;
    while (true) {
      Query<Map<String, dynamic>> query = _firestore
          .collection(collectionName)
          .orderBy(FieldPath.documentId)
          .limit(_pageSize);
      if (cursor != null) query = query.startAfterDocument(cursor);
      final QuerySnapshot<Map<String, dynamic>> page = await query.get(
        const GetOptions(source: Source.server),
      );
      if (page.docs.isEmpty) break;
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in page.docs) {
        rows.add(<String, dynamic>{...doc.data(), 'docId': doc.id});
      }
      cursor = page.docs.last;
      if (page.docs.length < _pageSize) break;
    }
    return List<Map<String, dynamic>>.unmodifiable(rows);
  }
}

class RetailerScorecardSource {
  const RetailerScorecardSource({required this.orders, required this.products});

  final List<Map<String, dynamic>> orders;
  final List<Map<String, dynamic>> products;
}
