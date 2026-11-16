import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/ai_insight.dart';
import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';
import '../utils/order_data_utils.dart';

List<AiInsight> productionAiInsightsFromRows(
  Iterable<Map<String, dynamic>> rows,
) {
  return rows
      .where((Map<String, dynamic> row) => !isDemoRow(row))
      .map(
        (Map<String, dynamic> row) =>
            AiInsight.fromMap((row['docId'] ?? '').toString(), row),
      )
      .where((AiInsight insight) => !insight.isDemo)
      .toList(growable: false);
}

Iterable<Map<String, dynamic>> _rawInsightRows(
  QuerySnapshot<Map<String, dynamic>> snapshot,
) {
  return snapshot.docs.map(
    (QueryDocumentSnapshot<Map<String, dynamic>> document) => <String, dynamic>{
      ...document.data(),
      'docId': document.id,
    },
  );
}

int _activeProductionInsightCount(
  QuerySnapshot<Map<String, dynamic>> snapshot,
) {
  return productionAiInsightsFromRows(
    _rawInsightRows(snapshot),
  ).where((AiInsight insight) => insight.isActive).length;
}

int _activeProductionInsightCountFromDocuments(
  Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
) {
  return productionAiInsightsFromRows(
    documents.map(
      (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
          <String, dynamic>{...document.data(), 'docId': document.id},
    ),
  ).where((AiInsight insight) => insight.isActive).length;
}

class AiAlertService {
  AiAlertService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  static const List<String> _closedStatuses = <String>[
    'resolved',
    'dismissed',
    'suppressed',
  ];

  Stream<QuerySnapshot<Map<String, dynamic>>> _openFirst(
    Query<Map<String, dynamic>> base,
    int limit,
  ) => snapshotsWithIndexFallback(
    base.where('status', whereNotIn: _closedStatuses).limit(limit),
    base.limit(limit),
  );

  Stream<int> watchAdminHighPriorityCount({int limit = 100}) {
    final int safeLimit = limit.clamp(1, 100).toInt();
    return _openFirst(
      _firestore.collection('ai_insights').where('priority', isEqualTo: 'high'),
      safeLimit,
    ).map(
      (QuerySnapshot<Map<String, dynamic>> snapshot) =>
          _activeProductionInsightCount(snapshot),
    );
  }

  Stream<int> watchSupervisorOverdueCount(
    UserProfile currentUser, {
    int limit = 200,
  }) {
    final List<String> codes = currentUser.assignedSalesmanCodes
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    if (!currentUser.isSupervisor || codes.isEmpty) {
      return Stream<int>.value(0);
    }
    final int safeLimit = limit.clamp(1, 200).toInt();
    return combineQuerySnapshotStreams(
      <Stream<QuerySnapshot<Map<String, dynamic>>>>[
        for (final String code in codes.toSet())
          _openFirst(
            _firestore
                .collection('ai_insights')
                .where('salesmanCode', isEqualTo: code),
            safeLimit,
          ),
      ],
    ).map((List<QueryDocumentSnapshot<Map<String, dynamic>>> documents) {
      final DateTime now = DateTime.now();
      return productionAiInsightsFromRows(
        documents.map(
          (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
              <String, dynamic>{...document.data(), 'docId': document.id},
        ),
      ).where((AiInsight insight) => insight.isOverdueAt(now)).length;
    });
  }

  Stream<int> watchActionCenterOpenCount(
    UserProfile currentUser, {
    int limit = 200,
  }) {
    final String role = currentUser.role.trim().toLowerCase();
    final int safeLimit = limit.clamp(1, 200).toInt();

    if (role == 'admin' || role == 'developer') {
      return _openFirst(_firestore.collection('ai_insights'), safeLimit).map(
        (QuerySnapshot<Map<String, dynamic>> snapshot) =>
            _activeProductionInsightCount(snapshot),
      );
    }

    if (role == 'branch_manager') {
      if (currentUser.branchId.isEmpty) {
        return Stream<int>.value(0);
      }
      return _openFirst(
        _firestore
            .collection('ai_insights')
            .where('branchId', isEqualTo: currentUser.branchId),
        safeLimit,
      ).map(
        (QuerySnapshot<Map<String, dynamic>> snapshot) =>
            _activeProductionInsightCount(snapshot),
      );
    }

    if (role == 'supervisor') {
      final List<String> codes = currentUser.assignedSalesmanCodes
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (codes.isEmpty) {
        return Stream<int>.value(0);
      }
      return combineQuerySnapshotStreams(
        <Stream<QuerySnapshot<Map<String, dynamic>>>>[
          for (final String code in codes)
            _openFirst(
              _firestore
                  .collection('ai_insights')
                  .where('salesmanCode', isEqualTo: code),
              safeLimit,
            ),
        ],
      ).map(_activeProductionInsightCountFromDocuments);
    }

    return Stream<int>.value(0);
  }
}
