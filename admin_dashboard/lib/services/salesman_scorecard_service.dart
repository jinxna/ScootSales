import 'package:cloud_firestore/cloud_firestore.dart';

import '../app/build_flags.dart';
import '../models/ai_insight.dart';
import '../models/conversation_outcome.dart';
import '../models/route_plan.dart';
import '../models/user_profile.dart';
import '../repositories/scoped_dashboard_repository.dart';
import '../utils/order_data_utils.dart';
import '../utils/salesman_scorecard.dart';
import '../utils/ai_data_freshness.dart';

const int kScorecardProgressReadLimit = 500;
const int kScorecardStopArrivalReadLimit = 500;
const int kScorecardPlanReadLimit = 300;
const int kScorecardOrderReadLimit = 1000;
const int kScorecardOutcomeReadLimit = 300;
const int kScorecardInsightReadLimit = 200;

const Duration kScorecardReadTimeout = Duration(seconds: 12);

class SalesmanScorecardService {
  SalesmanScorecardService({FirebaseFirestore? firestore})
    : _repository = ScopedDashboardRepository(firestore: firestore);

  final ScopedDashboardRepository _repository;

  Future<SalesmanScorecardInputs> loadInputs(UserProfile currentUser) async {
    final List<String> failed = <String>[];
    final Set<String> truncated = <String>{};
    int failedReads = 0;

    Future<List<Map<String, dynamic>>> guard(
      String source,
      Future<List<Map<String, dynamic>>> Function() load,
    ) async {
      try {
        return await load();
      } catch (_) {
        failed.add(source);
        failedReads += 1;
        return const <Map<String, dynamic>>[];
      }
    }

    final List<List<Map<String, dynamic>>> results =
        await Future.wait(<Future<List<Map<String, dynamic>>>>[
          guard(
            'visit progress',
            () => _loadProgressDocs(currentUser, truncated),
          ),
          guard(
            'stop arrivals',
            () => _loadStopArrivalDocs(currentUser, truncated),
          ),
          guard('route plans', () => _loadPlanDocs(currentUser, truncated)),
          guard('orders', () => _loadOrderDocs(currentUser, truncated)),
          guard('outcomes', () => _loadOutcomeDocs(currentUser, truncated)),
          guard('insights', () => _loadInsightDocs(currentUser, truncated)),
        ]);

    return SalesmanScorecardInputs(
      progressDocs: results[0],
      stopArrivalDocsByPlanId: stopArrivalDocsByPlanIdFrom(results[1]),
      plannedStopIdsByPlanId: plannedStopIdsFromPlanDocs(results[2]),
      orders: orderEventsFromRows(results[3]),
      outcomes: outcomeEventsFromRows(results[4]),
      insights: insightEventsFromDocs(results[5]),
      aiTimestamps: results[5].map(aiDataTimestamp).toList(growable: false),
      hasAiData: results[5].isNotEmpty,
      hasMissingAiTimestamp: results[5].any(
        (Map<String, dynamic> row) => aiDataTimestamp(row) == null,
      ),
      failedSources: List<String>.unmodifiable(failed),
      truncatedSources: List<String>.unmodifiable(
        truncated.toList(growable: false)..sort(),
      ),
      allSourcesFailed: failedReads >= 6,
    );
  }

  Future<List<Map<String, dynamic>>> _loadProgressDocs(
    UserProfile currentUser,
    Set<String> truncated,
  ) async {
    return _readScopedDocuments(
      'route_plan_progress',
      currentUser,
      orderBy: 'updatedAt',
      limit: kScorecardProgressReadLimit,
      source: 'visit progress',
      truncatedSink: truncated,
    );
  }

  Future<List<Map<String, dynamic>>> _loadStopArrivalDocs(
    UserProfile currentUser,
    Set<String> truncated,
  ) async {
    return _readScopedDocuments(
      'route_stop_progress',
      currentUser,
      orderBy: 'arrivedAt',
      limit: kScorecardStopArrivalReadLimit,
      source: 'stop arrivals',
      truncatedSink: truncated,
    );
  }

  Future<List<Map<String, dynamic>>> _loadPlanDocs(
    UserProfile currentUser,
    Set<String> truncated,
  ) async {
    return _readScopedDocuments(
      'route_plans',
      currentUser,
      orderBy: 'weekStart',
      limit: kScorecardPlanReadLimit,
      includeDocId: true,
      source: 'route plans',
      truncatedSink: truncated,
    );
  }

  Future<List<Map<String, dynamic>>> _loadOrderDocs(
    UserProfile currentUser,
    Set<String> truncated,
  ) async {
    return _readScopedDocuments(
      'orders',
      currentUser,
      orderBy: 'submittedAt',
      limit: kScorecardOrderReadLimit,
      source: 'orders',
      truncatedSink: truncated,
    );
  }

  Future<List<Map<String, dynamic>>> _loadOutcomeDocs(
    UserProfile currentUser,
    Set<String> truncated,
  ) async {
    return _readScopedDocuments(
      'conversation_outcomes',
      currentUser,
      orderBy: 'submittedAt',
      limit: kScorecardOutcomeReadLimit,
      source: 'outcomes',
      truncatedSink: truncated,
    );
  }

  Future<List<Map<String, dynamic>>> _loadInsightDocs(
    UserProfile currentUser,
    Set<String> truncated,
  ) async {
    if (isBasicEdition) return const <Map<String, dynamic>>[];
    return _readScopedDocuments(
      'ai_insights',
      currentUser,
      orderBy: 'updatedAt',
      limit: kScorecardInsightReadLimit,
      source: 'insights',
      truncatedSink: truncated,
    );
  }

  Future<List<Map<String, dynamic>>> _readScopedDocuments(
    String collection,
    UserProfile currentUser, {
    String? orderBy,
    required int limit,
    bool includeDocId = false,
    required String source,
    required Set<String> truncatedSink,
  }) async {
    final ScopedDashboardReadResult result = await _repository.readDocuments(
      collection: collection,
      currentUser: currentUser,
      orderBy: orderBy,
      limit: limit,
      deadline: kScorecardReadTimeout,
      includeDocId: includeDocId,
      historyWindow: const Duration(days: 56),
    );
    if (!result.metadata.isComplete) {
      truncatedSink.add(source);
    }
    return result.documents;
  }
}

class SalesmanScorecardInputs {
  const SalesmanScorecardInputs({
    required this.progressDocs,
    required this.stopArrivalDocsByPlanId,
    required this.plannedStopIdsByPlanId,
    required this.orders,
    required this.outcomes,
    required this.insights,
    this.aiTimestamps = const <DateTime?>[],
    this.hasAiData = false,
    this.hasMissingAiTimestamp = false,
    required this.failedSources,
    this.truncatedSources = const <String>[],
    this.allSourcesFailed = false,
  });

  static const SalesmanScorecardInputs empty = SalesmanScorecardInputs(
    progressDocs: <Map<String, dynamic>>[],
    stopArrivalDocsByPlanId: <String, List<Map<String, dynamic>>>{},
    plannedStopIdsByPlanId: <String, List<String>>{},
    orders: <ScorecardOrderEvent>[],
    outcomes: <ScorecardOutcomeEvent>[],
    insights: <ScorecardInsightEvent>[],
    aiTimestamps: <DateTime?>[],
    hasAiData: false,
    failedSources: <String>[],
    truncatedSources: <String>[],
  );

  final List<Map<String, dynamic>> progressDocs;

  final Map<String, List<Map<String, dynamic>>> stopArrivalDocsByPlanId;

  final Map<String, List<String>> plannedStopIdsByPlanId;
  final List<ScorecardOrderEvent> orders;
  final List<ScorecardOutcomeEvent> outcomes;
  final List<ScorecardInsightEvent> insights;
  final List<DateTime?> aiTimestamps;
  final bool hasAiData;
  final bool hasMissingAiTimestamp;

  final List<String> failedSources;

  final List<String> truncatedSources;

  final bool allSourcesFailed;
}

List<ScorecardSalesman> scorecardSalesmenFromUsers(
  List<Map<String, dynamic>> users,
  UserProfile currentUser,
) {
  final Set<String> supervisorCodes = currentUser.isSupervisor
      ? currentUser.assignedSalesmanCodes
            .map((String c) => c.trim().toLowerCase())
            .where((String c) => c.isNotEmpty)
            .toSet()
      : const <String>{};
  final String branchId = currentUser.branchId.trim();

  final List<ScorecardSalesman> result = <ScorecardSalesman>[];
  final Set<String> seen = <String>{};
  for (final Map<String, dynamic> user in users) {
    final String role = dataText(
      pickFirst(user, const <String>['role', 'user_group']),
    ).toLowerCase();
    if (!role.contains('sales')) continue;

    final String uid = dataText(
      pickFirst(user, const <String>['uid', 'docId', 'id']),
    );
    final String code = dataText(
      pickFirst(user, const <String>[
        'staffId',
        'staff_id',
        'employeeCode',
        'employee_code',
        'salesmanCode',
        'salesman_code',
      ]),
    );
    if (uid.isEmpty && code.isEmpty) continue;

    if (currentUser.isSupervisor) {
      if (!supervisorCodes.contains(code.trim().toLowerCase())) continue;
    } else if (currentUser.isBranchManager) {
      if (branchId.isEmpty ||
          dataText(pickFirst(user, const <String>['branchId', 'branch_id'])) !=
              branchId) {
        continue;
      }
    } else if (!currentUser.isAdmin) {
      continue;
    }

    final String dedupeKey = uid.isNotEmpty
        ? 'u:$uid'
        : 'c:${code.toLowerCase()}';
    if (!seen.add(dedupeKey)) continue;
    result.add(
      ScorecardSalesman(
        uid: uid,
        code: code,
        name: dataText(
          pickFirst(user, const <String>[
            'name',
            'displayName',
            'fullName',
            'email',
          ]),
          fallback: code.isNotEmpty ? code : uid,
        ),
      ),
    );
  }
  return result;
}

Map<String, List<String>> plannedStopIdsFromPlanDocs(
  List<Map<String, dynamic>> planDocs,
) {
  final Map<String, List<String>> result = <String, List<String>>{};
  for (final Map<String, dynamic> doc in planDocs) {
    final String docId = dataText(doc['docId']);
    final RoutePlan plan = RoutePlan.fromMap(docId, doc);
    final String planId = plan.id.trim().isNotEmpty ? plan.id.trim() : docId;
    if (planId.isEmpty) continue;
    final List<String> stopIds = <String>[
      for (final RouteDay day in plan.days)
        ...(List<RouteStop>.from(day.stops)..sort(
              (RouteStop a, RouteStop b) => a.sequence.compareTo(b.sequence),
            ))
            .map((RouteStop s) => s.stopId),
    ];
    if (stopIds.isNotEmpty) result[planId] = stopIds;
  }
  return result;
}

Map<String, List<Map<String, dynamic>>> stopArrivalDocsByPlanIdFrom(
  List<Map<String, dynamic>> rows,
) {
  final Map<String, List<Map<String, dynamic>>> result =
      <String, List<Map<String, dynamic>>>{};
  for (final Map<String, dynamic> row in rows) {
    final String planId = dataText(row['planId']);
    if (planId.isEmpty) continue;
    result.putIfAbsent(planId, () => <Map<String, dynamic>>[]).add(row);
  }
  return result;
}

List<ScorecardOrderEvent> orderEventsFromRows(List<Map<String, dynamic>> rows) {
  final List<ScorecardOrderEvent> result = <ScorecardOrderEvent>[];
  for (final Map<String, dynamic> row in rows) {
    if (isDemoRow(row)) continue;
    if (!isSubmittedOrApprovedOrder(row)) continue;
    result.add(
      ScorecardOrderEvent(
        salesmanUid: dataText(
          pickFirst(row, const <String>[
            'salesmanUid',
            'salesman_uid',
            'createdByUid',
          ]),
        ),
        salesmanCode: dataText(
          pickFirst(row, const <String>[
            'staffId',
            'staff_id',
            'salesmanCode',
            'salesman_code',
            'salesmanId',
          ]),
        ),
        at: orderDateFromRow(row),
      ),
    );
  }
  return result;
}

List<ScorecardOutcomeEvent> outcomeEventsFromRows(
  List<Map<String, dynamic>> rows,
) {
  final List<ScorecardOutcomeEvent> result = <ScorecardOutcomeEvent>[];
  for (final Map<String, dynamic> row in rows) {
    final ConversationOutcome outcome = ConversationOutcome.fromMap('', row);
    if (outcome.isDemo) continue;
    result.add(
      ScorecardOutcomeEvent(
        salesmanUid: outcome.salesmanUid,
        salesmanCode: outcome.salesmanCode,
        at: outcome.submittedAt,
        qualityScore: outcome.qualityScore,
        hasIssueRef: outcome.issueId.isNotEmpty || outcome.issueKey.isNotEmpty,
      ),
    );
  }
  return result;
}

List<ScorecardInsightEvent> insightEventsFromDocs(
  List<Map<String, dynamic>> docs,
) {
  final List<ScorecardInsightEvent> result = <ScorecardInsightEvent>[];
  for (final Map<String, dynamic> doc in docs) {
    final AiInsight insight = AiInsight.fromMap(dataText(doc['issueId']), doc);
    result.add(
      ScorecardInsightEvent(
        salesmanUid: insight.salesmanUid,
        salesmanCode: insight.salesmanCode,
        isResolved: insight.status == 'resolved',
      ),
    );
  }
  return result;
}
