import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';

class ReplenishmentService {
  ReplenishmentService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Future<Map<String, dynamic>?> loadVisitBriefSnapshot(
    UserProfile currentUser,
    String retailerId, {
    List<String>? failedSources,
  }) async {
    final String safeId = retailerId.trim();
    if (safeId.isEmpty) return null;
    Query<Map<String, dynamic>> query = _firestore
        .collection('visit_briefs')
        .where('retailerId', isEqualTo: safeId);
    final List<Query<Map<String, dynamic>>> scopedQueries = _applyRoleScope(
      query,
      currentUser,
    );
    if (scopedQueries.isEmpty) return null;
    try {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
          await getDocumentsFromQueryChunks(
            scopedQueries.map((Query<Map<String, dynamic>> scoped) {
              return scoped.limit(1);
            }),
          );
      for (final QueryDocumentSnapshot<Map<String, dynamic>> document
          in documents) {
        final Map<String, dynamic> data = document.data();
        final Object? replenishment = data['replenishment'];
        if (replenishment is List && replenishment.isNotEmpty) return data;
      }
      return null;
    } catch (_) {
      failedSources?.add('visit_briefs');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> loadRetailerOrders(
    UserProfile currentUser,
    String retailerId, {
    int limit = 300,
    List<String>? failedSources,
  }) async {
    final String safeId = retailerId.trim();
    if (safeId.isEmpty) return const <Map<String, dynamic>>[];
    final int safeLimit = limit.clamp(1, 500).toInt();
    final List<Query<Map<String, dynamic>>> scopedQueries = _applyRoleScope(
      _firestore.collection('orders').where('retailerId', isEqualTo: safeId),
      currentUser,
    );
    if (scopedQueries.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
          await getDocumentsFromQueryChunks(
            scopedQueries.map((Query<Map<String, dynamic>> scoped) {
              return scoped.limit(safeLimit);
            }),
          );
      final List<Map<String, dynamic>> rows = documents
          .map((QueryDocumentSnapshot<Map<String, dynamic>> doc) => doc.data())
          .toList();
      rows.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
        final DateTime? bDate = _orderMoment(b);
        final DateTime? aDate = _orderMoment(a);
        if (aDate == null && bDate == null) return 0;
        if (aDate == null) return 1;
        if (bDate == null) return -1;
        return bDate.compareTo(aDate);
      });
      return List<Map<String, dynamic>>.unmodifiable(rows);
    } catch (_) {
      failedSources?.add('orders');
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> loadRetailerItemPatterns(
    UserProfile currentUser,
    String retailerId, {
    int limit = 50,
    List<String>? failedSources,
  }) async {
    final String safeId = retailerId.trim();
    if (safeId.isEmpty) return const <Map<String, dynamic>>[];
    final int safeLimit = limit.clamp(1, 120).toInt();
    Query<Map<String, dynamic>> query = _firestore
        .collection('retailer_item_patterns')
        .where('retailerId', isEqualTo: safeId);
    final List<Query<Map<String, dynamic>>> scopedQueries = _applyRoleScope(
      query,
      currentUser,
    );
    if (scopedQueries.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
          await getDocumentsFromQueryChunks(
            scopedQueries.map((Query<Map<String, dynamic>> scoped) {
              return scoped.limit(safeLimit);
            }),
          );
      return documents
          .take(safeLimit)
          .map((QueryDocumentSnapshot<Map<String, dynamic>> doc) => doc.data())
          .toList(growable: false);
    } catch (_) {
      failedSources?.add('retailer_item_patterns');
      return const <Map<String, dynamic>>[];
    }
  }

  List<Query<Map<String, dynamic>>> _applyRoleScope(
    Query<Map<String, dynamic>> query,
    UserProfile currentUser,
  ) {
    if (currentUser.isSupervisor) {
      final List<String> codes = currentUser.assignedSalesmanCodes
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
      return whereInQueryChunks(query, 'salesmanCode', codes);
    }
    if (currentUser.isBranchManager) {
      final String branchId = currentUser.branchId.trim();
      return branchId.isEmpty
          ? const <Query<Map<String, dynamic>>>[]
          : <Query<Map<String, dynamic>>>[
              query.where('branchId', isEqualTo: branchId),
            ];
    }
    if (currentUser.isAdmin) {
      return <Query<Map<String, dynamic>>>[query];
    }
    return const <Query<Map<String, dynamic>>>[];
  }

  DateTime? _orderMoment(Map<String, dynamic> order) {
    final Object? value =
        order['submittedAt'] ?? order['orderDate'] ?? order['createdAt'];
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }
}
