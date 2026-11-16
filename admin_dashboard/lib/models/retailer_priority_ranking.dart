library;

import '../utils/ai_data_freshness.dart';

class RankedRetailerOpportunity {
  const RankedRetailerOpportunity({
    required this.retailerId,
    required this.retailerName,
    required this.rank,
    required this.expectedOrderValueRm,
    required this.opportunityPerRouteDay,
    required this.routeTimeDays,
    required this.travelMinutes,
    required this.serviceMinutes,
    required this.daysSinceLastVisit,
    required this.chosen,
    required this.exploitOrExplore,
    required this.selectionProbability,
    required this.coverageBasis,
    required this.forecastPairCount,
    required this.observedBaselinePairCount,
    this.breakdown,
  });

  final String retailerId;
  final String retailerName;
  final int rank;

  final double expectedOrderValueRm;

  final double opportunityPerRouteDay;

  final double routeTimeDays;
  final double travelMinutes;
  final double serviceMinutes;
  final double? daysSinceLastVisit;
  final bool chosen;

  final String exploitOrExplore;

  final double selectionProbability;

  final String coverageBasis;

  final int forecastPairCount;
  final int observedBaselinePairCount;

  final RankingScoreBreakdown? breakdown;

  bool get isExploration => exploitOrExplore == 'explore';

  factory RankedRetailerOpportunity.fromMap(Map<String, dynamic> data) {
    return RankedRetailerOpportunity(
      retailerId: _text(data['retailerId']),
      retailerName: _text(data['retailerName'], fallback: 'Retailer'),
      rank: (data['rank'] as num?)?.toInt() ?? 0,
      expectedOrderValueRm:
          (data['expectedOrderValueRm'] as num?)?.toDouble() ?? 0,
      opportunityPerRouteDay:
          (data['opportunityPerRouteDay'] as num?)?.toDouble() ?? 0,
      routeTimeDays: (data['routeTimeDays'] as num?)?.toDouble() ?? 0,
      travelMinutes: (data['travelMinutes'] as num?)?.toDouble() ?? 0,
      serviceMinutes: (data['serviceMinutes'] as num?)?.toDouble() ?? 0,
      daysSinceLastVisit: (data['daysSinceLastVisit'] as num?)?.toDouble(),
      chosen: data['chosen'] == true,
      exploitOrExplore: _movement(data['exploitOrExplore']),
      selectionProbability:
          ((data['selectionProbability'] as num?)?.toDouble() ?? 0).clamp(
            0.0,
            1.0,
          ),
      coverageBasis: _text(data['coverageBasis']),
      forecastPairCount: (data['forecastPairCount'] as num?)?.toInt() ?? 0,
      observedBaselinePairCount:
          (data['observedBaselinePairCount'] as num?)?.toInt() ?? 0,
      breakdown: RankingScoreBreakdown.fromComponents(data['components']),
    );
  }
}

class RankingScoreBreakdown {
  const RankingScoreBreakdown({
    required this.expectedValueRm,
    required this.adjustedValueRm,
    required this.travelMinutes,
    required this.serviceMinutes,
    required this.routeTimeDays,
    required this.coverageBoost,
    required this.adjustedScore,
  });

  final double expectedValueRm;
  final double adjustedValueRm;
  final double travelMinutes;
  final double serviceMinutes;
  final double routeTimeDays;
  final double coverageBoost;
  final double adjustedScore;

  double get uncertaintyAllowanceRm => adjustedValueRm - expectedValueRm;

  static RankingScoreBreakdown? fromComponents(Object? raw) {
    if (raw is! Map) return null;
    double? number(String key) => (raw[key] as num?)?.toDouble();
    final double? score = number('adjustedScore');
    final double? adjusted = number('adjustedValueRm');
    final double? days = number('routeTimeDays');
    if (score == null || adjusted == null || days == null) return null;
    return RankingScoreBreakdown(
      expectedValueRm: number('expectedValueRm') ?? adjusted,
      adjustedValueRm: adjusted,
      travelMinutes: number('travelMinutes') ?? 0,
      serviceMinutes: number('serviceMinutes') ?? 0,
      routeTimeDays: days,
      coverageBoost: number('coverageBoost') ?? 0,
      adjustedScore: score,
    );
  }
}

const String rankingScoreNote =
    'The rank order uses the ranking score, which adds the uncertainty '
    'allowance and the coverage boost to RM per route-day.';

List<String> rankingScoreSteps(RankedRetailerOpportunity row) {
  final RankingScoreBreakdown? b = row.breakdown;
  if (b == null) return const <String>[];
  String rm(double value) => 'RM${value.toStringAsFixed(2)}';
  final String contact = row.daysSinceLastVisit == null
      ? 'no contact on record'
      : '${row.daysSinceLastVisit!.round()} days since last contact';
  return <String>[
    'Expected order value: ${rm(b.expectedValueRm)}',
    'Plus uncertainty allowance: ${rm(b.uncertaintyAllowanceRm)} '
        '= ${rm(b.adjustedValueRm)}',
    'Route time: ${b.travelMinutes.round()} min travel + '
        '${b.serviceMinutes.round()} min visit = '
        '${b.routeTimeDays.toStringAsFixed(3)} route-days',
    'Adjusted value per route-day: ${rm(b.adjustedValueRm)} / '
        '${b.routeTimeDays.toStringAsFixed(3)} = '
        '${rm(b.routeTimeDays > 0 ? b.adjustedValueRm / b.routeTimeDays : 0)}',
    'Coverage boost: +${(b.coverageBoost * 100).toStringAsFixed(1)}% '
        '($contact)',
    'Ranking score: ${b.adjustedScore.toStringAsFixed(2)} -> rank '
        '#${row.rank}${row.isExploration ? ' (exploration pick)' : ''}',
  ];
}

class PriorityDecisionEntry {
  const PriorityDecisionEntry({
    required this.candidate,
    required this.score,
    required this.rank,
    required this.selectionProbability,
    required this.exploitOrExplore,
    required this.chosen,
    required this.policyVersion,
  });

  final String candidate;
  final double score;
  final int rank;
  final double selectionProbability;
  final String exploitOrExplore;
  final bool chosen;
  final String policyVersion;

  factory PriorityDecisionEntry.fromMap(Map<String, dynamic> data) {
    return PriorityDecisionEntry(
      candidate: _text(data['candidate']),
      score: (data['score'] as num?)?.toDouble() ?? 0,
      rank: (data['rank'] as num?)?.toInt() ?? 0,
      selectionProbability:
          ((data['selectionProbability'] as num?)?.toDouble() ?? 0).clamp(
            0.0,
            1.0,
          ),
      exploitOrExplore: _movement(data['exploitOrExplore']),
      chosen: data['chosen'] == true,
      policyVersion: _text(data['policyVersion']),
    );
  }
}

class RetailerPriorityRanking {
  const RetailerPriorityRanking({
    required this.rankingId,
    required this.scopeKey,
    required this.salesmanUid,
    required this.salesmanCode,
    required this.branchId,
    required this.weekKey,
    required this.status,
    required this.policyVersion,
    required this.rankingVersion,
    required this.expectedOrderValueVersion,
    required this.coverageBasis,
    required this.targetSize,
    required this.retailerCount,
    required this.chosenCount,
    required this.isDemo,
    required this.generatedAt,
    this.freshnessAt,
    required this.ranking,
    required this.decisionLog,
  });

  final String rankingId;
  final String scopeKey;
  final String salesmanUid;
  final String salesmanCode;
  final String branchId;
  final String weekKey;
  final String status;
  final String policyVersion;
  final String rankingVersion;
  final String expectedOrderValueVersion;
  final String coverageBasis;
  final int targetSize;
  final int retailerCount;
  final int chosenCount;
  final bool isDemo;
  final DateTime? generatedAt;

  final DateTime? freshnessAt;
  final List<RankedRetailerOpportunity> ranking;
  final List<PriorityDecisionEntry> decisionLog;

  bool get isActive => status.toLowerCase() == 'active';

  List<RankedRetailerOpportunity> get chosen => ranking
      .where((RankedRetailerOpportunity row) => row.chosen)
      .toList(growable: false);

  factory RetailerPriorityRanking.fromMap(Map<String, dynamic> data) {
    final Object? rawRanking = data['ranking'];
    final Object? rawLog = data['decisionLog'];
    return RetailerPriorityRanking(
      rankingId: _text(data['rankingId']),
      scopeKey: _text(data['scopeKey']),
      salesmanUid: _text(data['salesmanUid']),
      salesmanCode: _text(data['salesmanCode']),
      branchId: _text(data['branchId']),
      weekKey: _text(data['weekKey']),
      status: _text(data['status'], fallback: 'inactive'),
      policyVersion: _text(data['policyVersion']),
      rankingVersion: _text(data['rankingVersion']),
      expectedOrderValueVersion: _text(data['expectedOrderValueVersion']),
      coverageBasis: _text(data['coverageBasis']),
      targetSize: (data['targetSize'] as num?)?.toInt() ?? 0,
      retailerCount: (data['retailerCount'] as num?)?.toInt() ?? 0,
      chosenCount: (data['chosenCount'] as num?)?.toInt() ?? 0,
      isDemo: data['isDemo'] == true,
      generatedAt: _date(data['generatedAt']),
      freshnessAt: aiDataTimestamp(data),
      ranking: rawRanking is List
          ? rawRanking
                .whereType<Map>()
                .map(
                  (Map row) => RankedRetailerOpportunity.fromMap(
                    Map<String, dynamic>.from(row),
                  ),
                )
                .toList(growable: false)
          : const <RankedRetailerOpportunity>[],
      decisionLog: rawLog is List
          ? rawLog
                .whereType<Map>()
                .map(
                  (Map row) => PriorityDecisionEntry.fromMap(
                    Map<String, dynamic>.from(row),
                  ),
                )
                .toList(growable: false)
          : const <PriorityDecisionEntry>[],
    );
  }

  static RetailerPriorityRanking? newestActive(
    Iterable<RetailerPriorityRanking> rows, {
    String? salesmanUid,
    String? salesmanCode,
  }) {
    RetailerPriorityRanking? best;
    for (final RetailerPriorityRanking row in rows) {
      if (!row.isActive || row.ranking.isEmpty) continue;
      if (row.isDemo) continue;
      if (row.salesmanUid.isEmpty && row.salesmanCode.isEmpty) continue;
      if (salesmanUid != null &&
          salesmanUid.isNotEmpty &&
          row.salesmanUid.isNotEmpty &&
          row.salesmanUid != salesmanUid) {
        continue;
      }
      if (row.salesmanUid.isEmpty &&
          salesmanCode != null &&
          salesmanCode.isNotEmpty &&
          row.salesmanCode.isNotEmpty &&
          row.salesmanCode != salesmanCode) {
        continue;
      }
      if (best == null || _isNewer(row, best)) best = row;
    }
    return best;
  }

  static bool _isNewer(
    RetailerPriorityRanking candidate,
    RetailerPriorityRanking current,
  ) {
    final DateTime? left = candidate.generatedAt;
    final DateTime? right = current.generatedAt;
    if (left != null && right != null) {
      final int byTime = left.compareTo(right);
      if (byTime != 0) return byTime > 0;
    } else if (left != null) {
      return true;
    } else if (right != null) {
      return false;
    }
    return candidate.weekKey.compareTo(current.weekKey) > 0;
  }
}

String _text(Object? value, {String fallback = ''}) {
  final String text = (value ?? '').toString().trim();
  return text.isEmpty ? fallback : text;
}

String _movement(Object? value) {
  final String movement = _text(value).toLowerCase();
  return const <String>{'exploit', 'explore', 'not_selected'}.contains(movement)
      ? movement
      : 'not_selected';
}

DateTime? _date(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  try {
    final dynamic dynamicValue = value;
    return (dynamicValue.toDate() as DateTime);
  } catch (_) {
  }
  return DateTime.tryParse(_text(value));
}
