import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';

class RouteAttentionService {
  static const int _adminLimit = 1000;
  static const int _scopedLimit = 500;

  RouteAttentionService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Future<List<Map<String, dynamic>>?> loadProgress(UserProfile user) async {
    final Query<Map<String, dynamic>> base = _firestore.collection(
      'route_plan_progress',
    );
    List<Query<Map<String, dynamic>>> scoped;
    if (user.isAdmin) {
      scoped = <Query<Map<String, dynamic>>>[
        base.where('status', isEqualTo: 'in_progress').limit(_adminLimit + 1),
      ];
    } else if (user.isSupervisor) {
      final Iterable<String> assignedCodes = user.assignedSalesmanCodes
          .map((String code) => code.trim())
          .where((String code) => code.isNotEmpty)
          .toSet();
      scoped = whereInQueryChunks(base, 'salesmanCode', assignedCodes).map((
        Query<Map<String, dynamic>> query,
      ) {
        return query
            .where('status', isEqualTo: 'in_progress')
            .limit(_scopedLimit + 1);
      }).toList();
    } else if (user.isBranchManager && user.branchId.trim().isNotEmpty) {
      scoped = <Query<Map<String, dynamic>>>[
        base
            .where('branchId', isEqualTo: user.branchId.trim())
            .where('status', isEqualTo: 'in_progress')
            .limit(_scopedLimit + 1),
      ];
    } else {
      return const <Map<String, dynamic>>[];
    }

    try {
      final documents = await getDocumentsFromQueryChunks(scoped);
      final int resultLimit = user.isAdmin ? _adminLimit : _scopedLimit;
      if (documents.length > resultLimit) return null;
      return documents
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                <String, dynamic>{'docId': document.id, ...document.data()},
          )
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>?> loadReferencedPlans(
    UserProfile user,
    List<Map<String, dynamic>> progressRows,
  ) async {
    final Set<String> planIds = progressRows
        .map((Map<String, dynamic> row) => '${row['planId'] ?? ''}'.trim())
        .where((String id) => id.isNotEmpty)
        .toSet();
    if (planIds.isEmpty) return const <Map<String, dynamic>>[];

    final Query<Map<String, dynamic>> base = _firestore
        .collection('route_plans')
        .where('status', isEqualTo: 'published');
    final List<Query<Map<String, dynamic>>> queries =
        <Query<Map<String, dynamic>>>[];
    final List<List<String>> idChunks = chunkFirestoreWhereIn(planIds);
    if (user.isAdmin) {
      for (final List<String> chunk in idChunks) {
        queries.add(base.where(FieldPath.documentId, whereIn: chunk));
      }
    } else if (user.isSupervisor) {
      final Set<String> assignedCodes = user.assignedSalesmanCodes
          .map((String code) => code.trim())
          .where((String code) => code.isNotEmpty)
          .toSet();
      final Map<String, Set<String>> idsBySalesman = <String, Set<String>>{};
      for (final Map<String, dynamic> row in progressRows) {
        final String code = '${row['salesmanCode'] ?? ''}'.trim();
        final String id = '${row['planId'] ?? ''}'.trim();
        if (assignedCodes.contains(code) && id.isNotEmpty) {
          idsBySalesman.putIfAbsent(code, () => <String>{}).add(id);
        }
      }
      for (final MapEntry<String, Set<String>> entry in idsBySalesman.entries) {
        for (final List<String> chunk in chunkFirestoreWhereIn(entry.value)) {
          queries.add(
            base
                .where('salesmanCode', isEqualTo: entry.key)
                .where(FieldPath.documentId, whereIn: chunk),
          );
        }
      }
    } else if (user.isBranchManager && user.branchId.trim().isNotEmpty) {
      for (final List<String> chunk in idChunks) {
        queries.add(
          base
              .where('branchId', isEqualTo: user.branchId.trim())
              .where(FieldPath.documentId, whereIn: chunk),
        );
      }
    } else {
      return const <Map<String, dynamic>>[];
    }

    try {
      final documents = await getDocumentsFromQueryChunks(queries);
      return documents
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                <String, dynamic>{'docId': document.id, ...document.data()},
          )
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }
}
