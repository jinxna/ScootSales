import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/retailer_segment.dart';
import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';

class RetailerSegmentService {
  RetailerSegmentService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Future<Map<String, RetailerSegment>> loadSegments(
    UserProfile currentUser, {
    int limit = 500,
  }) async {
    final int safeLimit = limit.clamp(1, 500).toInt();
    final Query<Map<String, dynamic>> baseQuery = _firestore.collection(
      'retailer_segments',
    );
    List<Query<Map<String, dynamic>>> queries = <Query<Map<String, dynamic>>>[];
    if (currentUser.isSupervisor) {
      final List<String> codes = currentUser.assignedSalesmanCodes
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
      if (codes.isEmpty) return const <String, RetailerSegment>{};
      queries = whereInQueryChunks(baseQuery, 'salesmanCode', codes)
          .map((Query<Map<String, dynamic>> query) => query.limit(safeLimit))
          .toList(growable: false);
    } else if (currentUser.isBranchManager) {
      final String branchId = currentUser.branchId.trim();
      if (branchId.isEmpty) return const <String, RetailerSegment>{};
      queries = <Query<Map<String, dynamic>>>[
        baseQuery.where('branchId', isEqualTo: branchId).limit(safeLimit),
      ];
    } else if (currentUser.isAdmin) {
      queries = <Query<Map<String, dynamic>>>[
        baseQuery.orderBy('attentionScore', descending: true).limit(safeLimit),
      ];
    } else {
      return const <String, RetailerSegment>{};
    }
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
        await getDocumentsFromQueryChunks(queries);
    final Map<String, RetailerSegment> segments = <String, RetailerSegment>{};
    for (final QueryDocumentSnapshot<Map<String, dynamic>> document
        in documents) {
      final RetailerSegment segment = RetailerSegment.fromFirestore(document);
      if (segment.isActive) segments[segment.retailerId] = segment;
    }
    return segments;
  }
}
