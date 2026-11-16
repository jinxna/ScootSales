import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/ai_insight.dart';
import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';
import '../utils/order_data_utils.dart';

class AiInsightService {
  AiInsightService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<AiInsight>> watchInsights(
    UserProfile currentUser, {
    int limit = 200,
  }) {
    final int safeLimit = limit.clamp(1, 200).toInt();
    List<Query<Map<String, dynamic>>> queries = <Query<Map<String, dynamic>>>[];

    if (currentUser.isSupervisor) {
      final List<String> codes = currentUser.assignedSalesmanCodes
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
      if (codes.isEmpty) {
        return Stream<List<AiInsight>>.value(const <AiInsight>[]);
      }
      queries =
          whereInQueryChunks(
                _firestore.collection('ai_insights'),
                'salesmanCode',
                codes,
              )
              .map(
                (Query<Map<String, dynamic>> query) => query.limit(safeLimit),
              )
              .toList(growable: false);
    } else if (currentUser.isBranchManager) {
      final String branchId = currentUser.branchId.trim();
      if (branchId.isEmpty) {
        return Stream<List<AiInsight>>.value(const <AiInsight>[]);
      }
      queries = <Query<Map<String, dynamic>>>[
        _firestore
            .collection('ai_insights')
            .where('branchId', isEqualTo: branchId)
            .limit(safeLimit),
      ];
    } else if (currentUser.isAdmin) {
      queries = <Query<Map<String, dynamic>>>[
        _firestore
            .collection('ai_insights')
            .orderBy('updatedAt', descending: true)
            .limit(safeLimit),
      ];
    } else {
      return Stream<List<AiInsight>>.value(const <AiInsight>[]);
    }

    return combineFirestoreQuerySnapshots(queries).map((
      List<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
    ) {
      final List<AiInsight> insights = documents
          .where(
            (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                !isDemoRow(<String, dynamic>{
                  'docId': document.id,
                  ...document.data(),
                }),
          )
          .map(AiInsight.fromFirestore)
          .where((AiInsight insight) => !insight.isDemo)
          .toList(growable: false);
      insights.sort(_compare);
      return insights.length > safeLimit
          ? insights.take(safeLimit).toList(growable: false)
          : insights;
    });
  }

  int _compare(AiInsight left, AiInsight right) {
    const Map<String, int> priorityOrder = <String, int>{
      'high': 0,
      'medium': 1,
      'low': 2,
    };
    final int priority = (priorityOrder[left.priority] ?? 3).compareTo(
      priorityOrder[right.priority] ?? 3,
    );
    if (priority != 0) return priority;
    final DateTime leftTime =
        left.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final DateTime rightTime =
        right.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return rightTime.compareTo(leftTime);
  }
}
