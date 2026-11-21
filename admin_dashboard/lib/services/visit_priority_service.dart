import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/ai_insight.dart';
import '../models/user_profile.dart';
import '../repositories/scoped_dashboard_repository.dart';
import '../utils/route_execution.dart';
import '../utils/visit_priority.dart';
import '../utils/ai_data_freshness.dart';
import '../models/retailer_priority_ranking.dart';

const int kPriorityInsightReadLimit = 200;
const int kPriorityBriefReadLimit = 400;
const int kPriorityMemoryReadLimit = 400;
const int kPriorityVisitLogReadLimit = 500;

const int kPriorityRankingReadLimit = 200;

const Duration kPriorityReadTimeout = Duration(seconds: 12);

class VisitPriorityService {
  VisitPriorityService({FirebaseFirestore? firestore})
    : _repository = ScopedDashboardRepository(firestore: firestore);

  final ScopedDashboardRepository _repository;

  Future<VisitPriorityInputs> loadInputs(UserProfile currentUser) async {
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
          guard('ai_insights', () => _loadInsightDocs(currentUser)),
          guard('visit_briefs', () => _loadBriefDocs(currentUser)),
          guard('retailer_memory', () => _loadMemoryDocs(currentUser)),
          guard('visit history', () => _loadVisitLogDocs(currentUser)),
          guard('priority rankings', () => _loadRankingDocs(currentUser)),
        ]);

    return VisitPriorityInputs(
      openInsights: openInsightsFromDocs(results[0]),
      replenishmentValueByRetailer: const <String, double>{},
      memoryConfidenceByRetailer: memoryConfidenceIndex(results[2]),
      visitLogRows: results[3],
      priorityRankings: parsePriorityRankings(results[4]),
      aiTimestampBySalesmanCode: _timestampsBySalesmanCode(
        <Map<String, dynamic>>[...results[0], ...results[1], ...results[2]],
      ),
      aiSalesmanCodesWithData: _salesmanCodesWithAiData(<Map<String, dynamic>>[
        ...results[0],
        ...results[1],
        ...results[2],
      ]),
      aiSalesmanCodesWithMissingTimestamp: _salesmanCodesWithMissingAiTimestamp(
        <Map<String, dynamic>>[...results[0], ...results[1], ...results[2]],
      ),
      failedSources: List<String>.unmodifiable(failed),
      incompleteSources: List<String>.unmodifiable(incomplete),
      allSourcesFailed: failedReads >= 5,
    );
  }

  Map<String, DateTime> _timestampsBySalesmanCode(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final Map<String, DateTime> newestByCode = <String, DateTime>{};
    for (final Map<String, dynamic> row in rows) {
      final String code = _firstText(row, const <String>[
        'salesmanCode',
        'salesman_code',
      ]);
      if (code.isEmpty) continue;
      final DateTime? timestamp = aiDataTimestamp(row);
      if (timestamp == null) continue;
      final DateTime? previous = newestByCode[code];
      if (previous == null || timestamp.isAfter(previous)) {
        newestByCode[code] = timestamp;
      }
    }
    return Map<String, DateTime>.unmodifiable(newestByCode);
  }

  Set<String> _salesmanCodesWithAiData(Iterable<Map<String, dynamic>> rows) {
    final Set<String> codes = <String>{};
    for (final Map<String, dynamic> row in rows) {
      final String code = _firstText(row, const <String>[
        'salesmanCode',
        'salesman_code',
      ]);
      if (code.isNotEmpty) codes.add(code);
    }
    return Set<String>.unmodifiable(codes);
  }

  Set<String> _salesmanCodesWithMissingAiTimestamp(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final Set<String> codes = <String>{};
    for (final Map<String, dynamic> row in rows) {
      final String code = _firstText(row, const <String>[
        'salesmanCode',
        'salesman_code',
      ]);
      if (code.isNotEmpty && aiDataTimestamp(row) == null) codes.add(code);
    }
    return Set<String>.unmodifiable(codes);
  }

  Future<ScopedDashboardReadResult> _loadInsightDocs(
    UserProfile currentUser,
  ) async {
    return _repository.readDocuments(
      collection: 'ai_insights',
      currentUser: currentUser,
      orderBy: 'updatedAt',
      limit: kPriorityInsightReadLimit,
      deadline: kPriorityReadTimeout,
      historyWindow: const Duration(days: 180),
    );
  }

  Future<ScopedDashboardReadResult> _loadBriefDocs(
    UserProfile currentUser,
  ) async {
    return _repository.readDocuments(
      collection: 'visit_briefs',
      currentUser: currentUser,
      limit: kPriorityBriefReadLimit,
      deadline: kPriorityReadTimeout,
      historyWindow: const Duration(days: 180),
    );
  }

  Future<ScopedDashboardReadResult> _loadMemoryDocs(
    UserProfile currentUser,
  ) async {
    return _repository.readDocuments(
      collection: 'retailer_memory',
      currentUser: currentUser,
      limit: kPriorityMemoryReadLimit,
      deadline: kPriorityReadTimeout,
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
      limit: kPriorityVisitLogReadLimit,
      deadline: kPriorityReadTimeout,
      historyWindow: const Duration(days: 28),
    );
  }

  Future<List<RetailerPriorityRanking>> loadRankings(
    UserProfile currentUser,
  ) async {
    final result = await _loadRankingDocs(currentUser);
    if (!result.metadata.isComplete) {
      throw StateError('Incomplete priority ranking data');
    }
    return parsePriorityRankings(result.documents);
  }

  Future<List<RetailerPriorityRanking>> loadPlannerWeekRankings(
    UserProfile currentUser, {
    required DateTime weekStart,
  }) async {
    final result = await _repository.readDocuments(
      collection: 'retailer_priority_rankings',
      currentUser: currentUser,
      orderBy: 'generatedAt',
      limit: kPriorityRankingReadLimit,
      deadline: kPriorityReadTimeout,
      historyWindow: const Duration(days: 23),
      asOf: weekStart.add(const Duration(days: 8)),
    );
    if (!result.metadata.isComplete) {
      throw StateError('Incomplete priority ranking data');
    }
    return parsePriorityRankings(result.documents);
  }

  Future<ScopedDashboardReadResult> _loadRankingDocs(
    UserProfile currentUser,
  ) async {
    return _repository.readDocuments(
      collection: 'retailer_priority_rankings',
      currentUser: currentUser,
      orderBy: 'generatedAt',
      limit: kPriorityRankingReadLimit,
      deadline: kPriorityReadTimeout,
      historyWindow: const Duration(days: 180),
    );
  }
}

class VisitPriorityInputs {
  const VisitPriorityInputs({
    required this.openInsights,
    required this.replenishmentValueByRetailer,
    required this.memoryConfidenceByRetailer,
    required this.visitLogRows,
    required this.failedSources,
    this.incompleteSources = const <String>[],
    this.priorityRankings = const <RetailerPriorityRanking>[],
    this.aiTimestampBySalesmanCode = const <String, DateTime>{},
    this.aiSalesmanCodesWithData = const <String>{},
    this.aiSalesmanCodesWithMissingTimestamp = const <String>{},
    this.allSourcesFailed = false,
  });

  static const VisitPriorityInputs empty = VisitPriorityInputs(
    openInsights: <PriorityInsight>[],
    replenishmentValueByRetailer: <String, double>{},
    memoryConfidenceByRetailer: <String, double>{},
    visitLogRows: <Map<String, dynamic>>[],
    failedSources: <String>[],
    aiTimestampBySalesmanCode: <String, DateTime>{},
    aiSalesmanCodesWithData: <String>{},
    aiSalesmanCodesWithMissingTimestamp: <String>{},
  );

  final List<PriorityInsight> openInsights;
  final Map<String, double> replenishmentValueByRetailer;
  final Map<String, double> memoryConfidenceByRetailer;

  final List<Map<String, dynamic>> visitLogRows;

  final List<RetailerPriorityRanking> priorityRankings;

  final Map<String, DateTime> aiTimestampBySalesmanCode;
  final Set<String> aiSalesmanCodesWithData;
  final Set<String> aiSalesmanCodesWithMissingTimestamp;

  final List<String> failedSources;
  final List<String> incompleteSources;

  final bool allSourcesFailed;
}

List<RetailerPriorityRanking> parsePriorityRankings(
  Iterable<Map<String, dynamic>> rows,
) {
  final List<RetailerPriorityRanking> parsed = <RetailerPriorityRanking>[];
  for (final Map<String, dynamic> row in rows) {
    final RetailerPriorityRanking ranking = RetailerPriorityRanking.fromMap(
      row,
    );
    if (ranking.rankingId.isEmpty && ranking.scopeKey.isEmpty) continue;
    parsed.add(ranking);
  }
  return List<RetailerPriorityRanking>.unmodifiable(parsed);
}

String? salesmanScopeTruncationNote(List<String> assignedSalesmanCodes) {
  final int total = assignedSalesmanCodes
      .map((String value) => value.trim())
      .where((String value) => value.isNotEmpty)
      .length;
  if (total <= 30) return null;
  return 'salesman scope (first 30 of $total codes)';
}

String _text(Object? value) => value == null ? '' : value.toString().trim();

String _firstText(Map<String, dynamic> row, List<String> fields) {
  for (final String field in fields) {
    final String value = _text(row[field]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

List<PriorityInsight> openInsightsFromDocs(
  Iterable<Map<String, dynamic>> insightDocs,
) {
  final List<PriorityInsight> result = <PriorityInsight>[];
  for (final Map<String, dynamic> doc in insightDocs) {
    final AiInsight insight = AiInsight.fromMap(_text(doc['issueId']), doc);
    if (!insight.isActive) continue;
    if (insight.retailerId.trim().isEmpty) continue;
    result.add(
      PriorityInsight(
        retailerId: insight.retailerId,
        type: insight.type,
        status: openInsightStatus,
      ),
    );
  }
  return result;
}

Map<String, double> memoryConfidenceIndex(
  Iterable<Map<String, dynamic>> memoryDocs,
) {
  final Map<String, double> index = <String, double>{};
  for (final Map<String, dynamic> doc in memoryDocs) {
    final String retailerId = _firstText(doc, const <String>[
      'retailerId',
      'retailer_id',
    ]);
    if (retailerId.isEmpty) continue;
    final Object? raw = doc['confidence'];
    if (raw is! num) continue;
    index[retailerId] = raw.toDouble().clamp(0.0, 1.0);
  }
  return index;
}

Map<String, DateTime> resolveLastVisitByRetailer({
  required Iterable<Map<String, dynamic>> progressDocs,
  Iterable<Map<String, dynamic>> visitLogRows = const <Map<String, dynamic>>[],
}) {
  final Map<String, DateTime> lastVisit = <String, DateTime>{};

  void record(String retailerId, DateTime? at) {
    if (at == null) return;
    final String id = retailerId.trim();
    if (id.isEmpty || id == 'unknown') return;
    final DateTime? existing = lastVisit[id];
    if (existing == null || at.isAfter(existing)) lastVisit[id] = at;
  }

  for (final Map<String, dynamic> doc in progressDocs) {
    for (final StopExecutionEvent event in mapProgressDocToEvents(doc)) {
      record(event.retailerId, event.completedAt);
    }
  }
  for (final Map<String, dynamic> row in visitLogRows) {
    record(
      _firstText(row, const <String>['retailerId', 'retailer_id']),
      parseEventTimestamp(row['arrivalTime'] ?? row['arrival_time']),
    );
  }
  return lastVisit;
}

Map<String, double> highConfidenceServiceMinutes(
  Map<String, ServiceTimeStat> serviceTimes,
) {
  final Map<String, double> minutes = <String, double>{};
  serviceTimes.forEach((String retailerId, ServiceTimeStat stat) {
    if (stat.usedInPlanning) {
      minutes[retailerId] = stat.meanServiceMinutes!;
    }
  });
  return minutes;
}
