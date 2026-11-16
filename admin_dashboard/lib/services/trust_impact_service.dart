import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import '../utils/retailer_scope.dart';
import '../utils/trust_impact.dart';
import '../utils/ai_data_freshness.dart';

class TrustImpactLoadResult {
  const TrustImpactLoadResult({
    required this.report,
    required this.failedSources,
    this.aiTimestamps = const <DateTime?>[],
    this.hasAiData = false,
    this.hasMissingAiTimestamp = false,
  });
  final TrustImpactReport report;
  final List<String> failedSources;
  final List<DateTime?> aiTimestamps;
  final bool hasAiData;
  final bool hasMissingAiTimestamp;
}

class TrustImpactService {
  TrustImpactService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  static const Duration _timeout = Duration(seconds: 12);

  Future<TrustImpactLoadResult> load(UserProfile user) async {
    final List<String> failed = <String>[];
    Future<List<Map<String, dynamic>>> safeWeeklySummaries() async {
      try {
        Query<Map<String, dynamic>> query = _firestore.collection(
          'weekly_ai_summaries',
        );
        int limit = 60;
        if (user.isSupervisor) {
          final List<String> codes = user.assignedSalesmanCodes
              .map((String value) => value.trim())
              .where((String value) => value.isNotEmpty)
              .take(30)
              .toList(growable: false);
          if (codes.isEmpty) return const <Map<String, dynamic>>[];
          query = query
              .where('scopeType', isEqualTo: 'salesman')
              .where('scopeKey', whereIn: codes);
        } else if (user.isBranchManager) {
          final String branchId = user.branchId.trim();
          if (branchId.isEmpty) return const <Map<String, dynamic>>[];
          query = query
              .where('scopeType', isEqualTo: 'branch')
              .where('scopeKey', isEqualTo: branchId);
        } else if (user.isAdmin) {
          query = query.where('scopeType', isEqualTo: 'organization');
          limit = 12;
        } else {
          return const <Map<String, dynamic>>[];
        }
        final QuerySnapshot<Map<String, dynamic>> snapshot = await query
            .orderBy('weekStart', descending: true)
            .limit(limit)
            .get()
            .timeout(_timeout);
        return snapshot.docs
            .map(
              (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                  <String, dynamic>{...doc.data(), 'docId': doc.id},
            )
            .toList(growable: false);
      } catch (_) {
        failed.add('weekly_ai_summaries');
        return const <Map<String, dynamic>>[];
      }
    }

    Future<List<Map<String, dynamic>>> safe(
      String collection,
      String salesmanField,
      int limit, {
      bool retailerAssignments = false,
    }) async {
      try {
        Query<Map<String, dynamic>> query = _firestore.collection(collection);
        if (user.isSupervisor) {
          final List<String> codes = user.assignedSalesmanCodes
              .map((String value) => value.trim())
              .where((String value) => value.isNotEmpty)
              .take(30)
              .toList(growable: false);
          if (codes.isEmpty) return const <Map<String, dynamic>>[];
          if (retailerAssignments) {
            final String branchId = user.branchId.trim();
            if (branchId.isEmpty) return const <Map<String, dynamic>>[];
            query = query.where('branchId', isEqualTo: branchId);
          } else {
            query = query.where(salesmanField, whereIn: codes);
          }
        } else if (user.isBranchManager) {
          if (user.branchId.trim().isEmpty) {
            return const <Map<String, dynamic>>[];
          }
          query = query.where('branchId', isEqualTo: user.branchId.trim());
        } else if (!user.isAdmin) {
          return const <Map<String, dynamic>>[];
        }
        final QuerySnapshot<Map<String, dynamic>> snapshot = await query
            .limit(limit)
            .get()
            .timeout(_timeout);
        return snapshot.docs
            .map(
              (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                  <String, dynamic>{...doc.data(), 'docId': doc.id},
            )
            .where(
              (Map<String, dynamic> row) =>
                  !(retailerAssignments && user.isSupervisor) ||
                  retailerInActorScope(user, row),
            )
            .toList(growable: false);
      } catch (_) {
        failed.add(collection);
        return const <Map<String, dynamic>>[];
      }
    }

    final List<List<Map<String, dynamic>>> rows =
        await Future.wait(<Future<List<Map<String, dynamic>>>>[
          safeWeeklySummaries(),
          safe('visit_briefs', 'salesmanCode', 500),
          safe('orders', 'staffId', 1000),
          safe('route_plans', 'salesmanCode', 200),
          safe('route_plan_progress', 'salesmanCode', 500),
          safe('ai_insights', 'salesmanCode', 500),
          safe(
            'retailers',
            'assignedSalesmanCode',
            3000,
            retailerAssignments: true,
          ),
        ]);

    final TrustImpactReport derived = deriveTrustImpactReport(
      weeklySummaries: filterTrustImpactProductionRows(rows[0]),
      visitBriefs: filterTrustImpactProductionRows(rows[1]),
      orders: filterTrustImpactProductionRows(rows[2]),
      routePlans: filterTrustImpactProductionRows(rows[3]),
      routeProgress: filterTrustImpactProductionRows(rows[4]),
      insights: filterTrustImpactProductionRows(rows[5]),
      retailers: filterTrustImpactProductionRows(rows[6], retailers: true),
    );
    final List<Set<String>> dependencies = <Set<String>>[
      <String>{'weekly_ai_summaries'},
      <String>{'visit_briefs', 'retailers'},
      <String>{'visit_briefs', 'orders'},
      <String>{'route_plans', 'route_plan_progress'},
      <String>{'ai_insights'},
    ];
    final List<Map<String, dynamic>> aiRows = <Map<String, dynamic>>[
      ...filterTrustImpactProductionRows(rows[0]),
      ...filterTrustImpactProductionRows(rows[1]),
      ...filterTrustImpactProductionRows(rows[5]),
    ];
    final List<TrustMetric> metrics = <TrustMetric>[
      for (int index = 0; index < derived.metrics.length; index++)
        if (dependencies[index].any(failed.contains))
          TrustMetric(
            label: derived.metrics[index].label,
            value: 'Unavailable',
            sampleSize: 0,
            explanation:
                'Evidence source unavailable: ${dependencies[index].where(failed.contains).join(', ')}.',
            available: false,
          )
        else
          derived.metrics[index],
    ];
    final Map<String, Set<String>> abstentionDependencies =
        <String, Set<String>>{
          'Sparse history / no usable recommendation': <String>{
            'visit_briefs',
            'retailers',
          },
          'Missing product identity': <String>{'orders'},
          'Missing recommendation timestamp': <String>{'visit_briefs'},
          'Stopped product evidence': <String>{'visit_briefs'},
          'Unverified or missing coordinates': <String>{'retailers'},
        };
    return TrustImpactLoadResult(
      report: TrustImpactReport(
        metrics: metrics,
        abstentionReasons: derived.abstentionReasons,
        latestEvidenceAt: derived.latestEvidenceAt,
        unavailableAbstentionReasons: <String>{
          for (final MapEntry<String, Set<String>> entry
              in abstentionDependencies.entries)
            if (entry.value.any(failed.contains)) entry.key,
        },
      ),
      failedSources: List<String>.unmodifiable(failed),
      aiTimestamps: aiRows.map(aiDataTimestamp).toList(growable: false),
      hasAiData: aiRows.isNotEmpty,
      hasMissingAiTimestamp: aiRows.any(
        (Map<String, dynamic> row) => aiDataTimestamp(row) == null,
      ),
    );
  }
}
