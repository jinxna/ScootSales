import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/ai_run_record.dart';
import '../models/user_profile.dart';
import '../models/weekly_ai_summary.dart';
import '../utils/firestore_query_utils.dart';
import '../utils/order_data_utils.dart';

class WeeklyAiReportService {
  WeeklyAiReportService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<WeeklyAiSummary>> watchSummaries(
    UserProfile currentUser, {
    int limit = 60,
  }) {
    final int safeLimit = limit.clamp(1, 60).toInt();
    List<Query<Map<String, dynamic>>> queries = <Query<Map<String, dynamic>>>[];
    final Query<Map<String, dynamic>> baseQuery = _firestore.collection(
      'weekly_ai_summaries',
    );
    if (currentUser.isSupervisor) {
      final List<String> codes = currentUser.assignedSalesmanCodes
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
      if (codes.isEmpty) {
        return Stream<List<WeeklyAiSummary>>.value(const <WeeklyAiSummary>[]);
      }
      queries =
          whereInQueryChunks(
                baseQuery.where('scopeType', isEqualTo: 'salesman'),
                'scopeKey',
                codes,
              )
              .map(
                (Query<Map<String, dynamic>> query) => query
                    .orderBy('weekStart', descending: true)
                    .limit(safeLimit),
              )
              .toList(growable: false);
    } else if (currentUser.isBranchManager) {
      final String branchId = currentUser.branchId.trim();
      if (branchId.isEmpty) {
        return Stream<List<WeeklyAiSummary>>.value(const <WeeklyAiSummary>[]);
      }
      queries = <Query<Map<String, dynamic>>>[
        baseQuery
            .where('scopeType', isEqualTo: 'branch')
            .where('scopeKey', isEqualTo: branchId)
            .orderBy('weekStart', descending: true)
            .limit(safeLimit),
      ];
    } else if (currentUser.isAdmin) {
      queries = <Query<Map<String, dynamic>>>[
        baseQuery
            .where('scopeType', isEqualTo: 'organization')
            .orderBy('weekStart', descending: true)
            .limit(12),
      ];
    } else {
      return Stream<List<WeeklyAiSummary>>.value(const <WeeklyAiSummary>[]);
    }
    return combineFirestoreQuerySnapshots(queries).map((
      List<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
    ) {
      final List<WeeklyAiSummary> rows = documents
          .where(
            (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                !isDemoRow(<String, dynamic>{
                  'docId': document.id,
                  ...document.data(),
                }),
          )
          .map(WeeklyAiSummary.fromFirestore)
          .toList(growable: false);
      rows.sort((WeeklyAiSummary left, WeeklyAiSummary right) {
        final DateTime leftDate =
            left.weekStart ?? DateTime.fromMillisecondsSinceEpoch(0);
        final DateTime rightDate =
            right.weekStart ?? DateTime.fromMillisecondsSinceEpoch(0);
        return rightDate.compareTo(leftDate);
      });
      return rows.length > safeLimit
          ? rows.take(safeLimit).toList(growable: false)
          : rows;
    });
  }

  Stream<List<AiRunRecord>> watchRuns(
    UserProfile currentUser, {
    int limit = 20,
  }) {
    if (!currentUser.isAdmin) {
      return Stream<List<AiRunRecord>>.value(const <AiRunRecord>[]);
    }
    return _firestore
        .collection('ai_runs')
        .orderBy('startedAt', descending: true)
        .limit(limit.clamp(1, 20).toInt())
        .snapshots()
        .map(
          (QuerySnapshot<Map<String, dynamic>> snapshot) => snapshot.docs
              .where(
                (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                    !isDemoRow(<String, dynamic>{
                      'docId': document.id,
                      ...document.data(),
                    }),
              )
              .map(AiRunRecord.fromFirestore)
              .toList(growable: false),
        );
  }
}
