import 'package:cloud_firestore/cloud_firestore.dart';

import '../app/build_flags.dart';
import '../models/ai_insight.dart';
import '../models/user_profile.dart';
import '../repositories/scoped_dashboard_repository.dart';
import '../utils/order_data_utils.dart';
import '../utils/ai_data_freshness.dart';
import '../utils/retailer_lifecycle.dart';
import 'visit_priority_service.dart'
    show memoryConfidenceIndex, resolveLastVisitByRetailer;

const int kLifecycleOrderReadLimit = 1000;
const int kLifecycleInsightReadLimit = 200;
const int kLifecycleMemoryReadLimit = 400;
const int kLifecycleVisitLogReadLimit = 500;
const int kLifecycleProgressReadLimit = 500;

const Duration kLifecycleReadTimeout = Duration(seconds: 12);

class RetailerLifecycleService {
  RetailerLifecycleService({FirebaseFirestore? firestore})
    : _repository = ScopedDashboardRepository(firestore: firestore);

  final ScopedDashboardRepository _repository;

  Future<RetailerLifecycleInputs> loadInputs(UserProfile currentUser) async {
    final List<String> failed = <String>[];
    int failedReads = 0;
    final incomplete = <String>[];

    Future<List<Map<String, dynamic>>> guard(
      String source,
      Future<ScopedDashboardReadResult> Function() load,
    ) async {
      try {
        final result = await load();
        if (!result.metadata.isComplete) incomplete.add(source);
        return result.documents;
      } catch (_) {
        failed.add(source);
        failedReads += 1;
        return const <Map<String, dynamic>>[];
      }
    }

    final List<List<Map<String, dynamic>>> results =
        await Future.wait(<Future<List<Map<String, dynamic>>>>[
          guard('orders', () => _loadOrderDocs(currentUser)),
          isBasicEdition
              ? Future.value(<Map<String, dynamic>>[])
              : guard('insights', () => _loadInsightDocs(currentUser)),
          isBasicEdition
              ? Future.value(<Map<String, dynamic>>[])
              : guard('retailer memory', () => _loadMemoryDocs(currentUser)),
          guard('visit history', () => _loadVisitLogDocs(currentUser)),
          guard('route progress', () => _loadProgressDocs(currentUser)),
        ]);

    return RetailerLifecycleInputs(
      orderStatsByRetailer: orderStatsFromRows(results[0]),
      orderHistoryComplete: false,
      riskInsightCountByRetailer: riskInsightCountFromDocs(results[1]),
      memoryConfidenceByRetailer: memoryConfidenceIndex(results[2]),
      lastVisitByRetailer: resolveLastVisitByRetailer(
        progressDocs: results[4],
        visitLogRows: results[3],
      ),
      aiTimestamps: <DateTime?>[
        for (final Map<String, dynamic> row in <Map<String, dynamic>>[
          ...results[1],
          ...results[2],
        ])
          aiDataTimestamp(row),
      ],
      hasAiData: results[1].isNotEmpty || results[2].isNotEmpty,
      hasMissingAiTimestamp: <Map<String, dynamic>>[
        ...results[1],
        ...results[2],
      ].any((Map<String, dynamic> row) => aiDataTimestamp(row) == null),
      failedSources: List<String>.unmodifiable(failed),
      incompleteSources: List<String>.unmodifiable(incomplete),
      allSourcesFailed: failedReads >= 5,
    );
  }

  Future<ScopedDashboardReadResult> _loadProgressDocs(
    UserProfile currentUser,
  ) async {
    return _repository.readDocuments(
      collection: 'route_plan_progress',
      currentUser: currentUser,
      orderBy: 'updatedAt',
      limit: kLifecycleProgressReadLimit,
      deadline: kLifecycleReadTimeout,
      historyWindow: const Duration(days: 180),
    );
  }

  Future<ScopedDashboardReadResult> _loadOrderDocs(UserProfile currentUser) {
    return _repository.readDocuments(
      collection: 'orders',
      currentUser: currentUser,
      orderBy: 'submittedAt',
      limit: kLifecycleOrderReadLimit,
      deadline: kLifecycleReadTimeout,
      historyWindow: const Duration(days: 180),
    );
  }

  Future<ScopedDashboardReadResult> _loadInsightDocs(
    UserProfile currentUser,
  ) async {
    return _repository.readDocuments(
      collection: 'ai_insights',
      currentUser: currentUser,
      orderBy: 'updatedAt',
      limit: kLifecycleInsightReadLimit,
      deadline: kLifecycleReadTimeout,
      historyWindow: const Duration(days: 180),
    );
  }

  Future<ScopedDashboardReadResult> _loadMemoryDocs(
    UserProfile currentUser,
  ) async {
    return _repository.readDocuments(
      collection: 'retailer_memory',
      currentUser: currentUser,
      limit: kLifecycleMemoryReadLimit,
      deadline: kLifecycleReadTimeout,
      historyWindow: const Duration(days: 180),
    );
  }

  Future<ScopedDashboardReadResult> _loadVisitLogDocs(
    UserProfile currentUser,
  ) async {
    return _repository.readDocuments(
      collection: 'visit_logs',
      currentUser: currentUser,
      orderBy: 'arrivalTime',
      limit: kLifecycleVisitLogReadLimit,
      deadline: kLifecycleReadTimeout,
      historyWindow: const Duration(days: 180),
    );
  }
}

class RetailerLifecycleInputs {
  const RetailerLifecycleInputs({
    required this.orderStatsByRetailer,
    this.orderHistoryComplete = true,
    required this.riskInsightCountByRetailer,
    required this.memoryConfidenceByRetailer,
    required this.lastVisitByRetailer,
    this.aiTimestamps = const <DateTime?>[],
    this.hasAiData = false,
    this.hasMissingAiTimestamp = false,
    required this.failedSources,
    this.incompleteSources = const <String>[],
    this.allSourcesFailed = false,
  });

  static const RetailerLifecycleInputs empty = RetailerLifecycleInputs(
    orderStatsByRetailer: <String, RetailerOrderStats>{},
    riskInsightCountByRetailer: <String, int>{},
    memoryConfidenceByRetailer: <String, double>{},
    lastVisitByRetailer: <String, DateTime>{},
    aiTimestamps: <DateTime?>[],
    hasAiData: false,
    failedSources: <String>[],
  );

  final Map<String, RetailerOrderStats> orderStatsByRetailer;

  final bool orderHistoryComplete;
  final Map<String, int> riskInsightCountByRetailer;
  final Map<String, double> memoryConfidenceByRetailer;
  final Map<String, DateTime> lastVisitByRetailer;
  final List<DateTime?> aiTimestamps;
  final bool hasAiData;
  final bool hasMissingAiTimestamp;
  final List<String> failedSources;
  final List<String> incompleteSources;
  final bool allSourcesFailed;
}

List<LifecycleRetailer> lifecycleRetailersFromRows(
  List<Map<String, dynamic>> rows,
) {
  final List<LifecycleRetailer> result = <LifecycleRetailer>[];
  for (final Map<String, dynamic> row in rows) {
    if (isDemoRow(row)) continue;
    final String id = dataText(
      pickFirst(row, const <String>[
        'retailerId',
        'retailer_id',
        'docId',
        'id',
      ]),
    );
    if (id.isEmpty) continue;
    result.add(
      LifecycleRetailer(
        id: id,
        name: dataText(
          pickFirst(row, const <String>[
            'retailerName',
            'retailer_name',
            'name',
            'martName',
            'customerName',
          ]),
          fallback: id,
        ),
        createdAt: parseFlexibleDate(
          pickFirst(row, const <String>[
            'createdAt',
            'created_at',
            'registeredAt',
          ]),
        ),
        isAssigned: _hasAssignment(row),
      ),
    );
  }
  return result;
}

bool _hasAssignment(Map<String, dynamic> row) {
  for (final String field in const <String>[
    'assignedSalesmanCodes',
    'assigned_salesman_codes',
    'assignedUsers',
    'assigned_users',
    'assignedTo',
    'assigned_salesmen',
    'assignedSalesmen',
  ]) {
    final Object? value = row[field];
    if (value is List && value.any((Object? v) => dataText(v).isNotEmpty)) {
      return true;
    }
  }
  for (final String field in const <String>[
    'assignedSalesmanId',
    'assigned_salesman_id',
    'assignedSalesmanUid',
    'assigned_salesman_uid',
    'assignedSalesmanCode',
    'assigned_salesman_code',
  ]) {
    if (dataText(row[field]).isNotEmpty) return true;
  }
  return false;
}

Map<String, RetailerOrderStats> orderStatsFromRows(
  List<Map<String, dynamic>> rows,
) {
  final Map<String, DateTime?> first = <String, DateTime?>{};
  final Map<String, DateTime?> last = <String, DateTime?>{};
  final Map<String, int> count = <String, int>{};
  for (final Map<String, dynamic> row in rows) {
    if (isDemoRow(row)) continue;
    if (!isSubmittedOrApprovedOrder(row)) continue;
    final String retailerId = dataText(
      pickFirst(row, const <String>['retailerId', 'retailer_id']),
    );
    if (retailerId.isEmpty) continue;
    count.update(retailerId, (int v) => v + 1, ifAbsent: () => 1);
    final DateTime? at = orderDateFromRow(row);
    if (at == null) continue;
    final DateTime? currentFirst = first[retailerId];
    if (currentFirst == null || at.isBefore(currentFirst)) {
      first[retailerId] = at;
    }
    final DateTime? currentLast = last[retailerId];
    if (currentLast == null || at.isAfter(currentLast)) {
      last[retailerId] = at;
    }
  }
  return <String, RetailerOrderStats>{
    for (final String id in count.keys)
      id: RetailerOrderStats(
        firstAt: first[id],
        lastAt: last[id],
        count: count[id]!,
      ),
  };
}

Map<String, int> riskInsightCountFromDocs(List<Map<String, dynamic>> docs) {
  final Map<String, int> result = <String, int>{};
  for (final Map<String, dynamic> doc in docs) {
    final AiInsight insight = AiInsight.fromMap(dataText(doc['issueId']), doc);
    if (!insight.isActive) continue;
    if (!riskInsightTypes.contains(insight.type.trim().toLowerCase())) continue;
    final String retailerId = insight.retailerId.trim();
    if (retailerId.isEmpty) continue;
    result.update(retailerId, (int v) => v + 1, ifAbsent: () => 1);
  }
  return result;
}
