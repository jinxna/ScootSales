import '../models/ai_insight.dart';
import '../models/retailer_priority_ranking.dart';

const String kRouteSelectionRankingOrder = 'ranking-order-v1';
const String kNotInWeeklyRanking = 'Not in the weekly ranking';
const String kWeeklyRankingNotUsed =
    "The weekly ranking for this week has none of this salesperson's shops, "
    'so it was not used.';
const Set<String> kRouteFlagInsightTypes = <String>{
  'stopped_product',
  'overdue_reorder',
  'declining_sales',
};

const List<String> _shortWeekdays = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
];

int? routeFollowUpDayIndex(DateTime? date, DateTime monday) {
  if (date == null) return null;
  final int offset = DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime.utc(monday.year, monday.month, monday.day)).inDays;
  if (offset > 6) return null;
  if (offset < 0) return 0;
  return offset == 6 ? 5 : offset;
}

String routeFollowUpLabel(DateTime date, DateTime monday) {
  final DateTime day = DateTime(date.year, date.month, date.day);
  if (day.isBefore(DateTime(monday.year, monday.month, monday.day))) {
    return 'Follow-up overdue';
  }
  return 'Follow-up due '
      '${_shortWeekdays[routeFollowUpDayIndex(date, monday)!]}';
}

String routeDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime? routeDateFromKey(String key) {
  final List<String> parts = key.trim().split('-');
  if (parts.length != 3) return null;
  final int? year = int.tryParse(parts[0]);
  final int? month = int.tryParse(parts[1]);
  final int? day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}

String routeWeekKey(DateTime day) {
  final DateTime date = DateTime.utc(day.year, day.month, day.day);
  final DateTime thursday = date.add(Duration(days: 4 - date.weekday));
  final DateTime firstDay = DateTime.utc(thursday.year, 1, 1);
  final int week = 1 + thursday.difference(firstDay).inDays ~/ 7;
  return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
}

RetailerPriorityRanking? rankingForPlannerWeek(
  Iterable<RetailerPriorityRanking> rankings, {
  required String salesmanUid,
  required String salesmanCode,
  required DateTime weekStart,
}) {
  for (final String key in <String>[
    routeWeekKey(weekStart),
    routeWeekKey(weekStart.subtract(const Duration(days: 7))),
  ]) {
    final RetailerPriorityRanking? found = RetailerPriorityRanking.newestActive(
      rankings.where((RetailerPriorityRanking row) => row.weekKey == key),
      salesmanUid: salesmanUid,
      salesmanCode: salesmanCode,
    );
    if (found != null) return found;
  }
  return null;
}

double rankingRowScore(RankedRetailerOpportunity row) =>
    row.breakdown?.adjustedScore ?? row.opportunityPerRouteDay;

class RouteRankingInput {
  const RouteRankingInput({
    required this.rankingId,
    required this.weekKey,
    required this.rankByRetailer,
    required this.nameByRetailer,
    required this.reasonByRetailer,
  });

  final String rankingId;
  final String weekKey;
  final Map<String, int> rankByRetailer;
  final Map<String, String> nameByRetailer;
  final Map<String, String> reasonByRetailer;

  bool ranksAnyOf(Iterable<String> retailerIds) =>
      retailerIds.any(rankByRetailer.containsKey);

  String reasonFor(String retailerId, String formulaReason) {
    final String stored = reasonByRetailer[retailerId] ?? '';
    if (rankByRetailer.containsKey(retailerId)) {
      return stored.isEmpty ? formulaReason : stored;
    }
    return <String>[
      '$kNotInWeeklyRanking.',
      if (stored.isNotEmpty) stored,
      formulaReason,
    ].join(' ');
  }
}

List<AiInsight> newestWeekRouteInsights(Iterable<AiInsight> insights) {
  final List<AiInsight> open = insights
      .where(
        (AiInsight insight) =>
            insight.isActive &&
            !insight.isDemo &&
            insight.retailerId.trim().isNotEmpty,
      )
      .toList(growable: false);
  DateTime? newest;
  for (final AiInsight insight in open) {
    final DateTime? week = insight.lastObservedWeekStart;
    if (week != null && (newest == null || week.isAfter(newest))) {
      newest = week;
    }
  }
  if (newest == null) return const <AiInsight>[];
  return open
      .where(
        (AiInsight insight) =>
            insight.lastObservedWeekStart?.isAtSameMomentAs(newest!) ?? false,
      )
      .toList(growable: false);
}

String routeInsightSentence(AiInsight insight) {
  final String head = '${insight.typeLabel}: ${insight.productName}';
  if (!insight.isCadenceInsight) return '$head.';
  return '$head, usually orders every '
      '${insight.reorderIntervalDays.round()} days, last order '
      '${insight.daysSinceLastOrder} days ago.';
}

String routeInsightText(List<AiInsight> insights) =>
    insights.take(2).map(routeInsightSentence).join(' ');

RouteRankingInput buildRouteRankingInput(
  RetailerPriorityRanking ranking,
  Iterable<AiInsight> insights,
) {
  final Map<String, List<AiInsight>> insightsByRetailer =
      <String, List<AiInsight>>{};
  for (final AiInsight insight in newestWeekRouteInsights(insights)) {
    insightsByRetailer
        .putIfAbsent(insight.retailerId.trim(), () => <AiInsight>[])
        .add(insight);
  }
  final bool lastOrderBasis = ranking.coverageBasis == 'last_observed_order';
  final Map<String, int> rankByRetailer = <String, int>{};
  final Map<String, String> nameByRetailer = <String, String>{};
  final Map<String, String> reasonByRetailer = <String, String>{};
  for (final RankedRetailerOpportunity row in ranking.ranking) {
    final String id = row.retailerId.trim();
    if (id.isEmpty) continue;
    final String insightText = routeInsightText(
      insightsByRetailer[id] ?? const <AiInsight>[],
    );
    if (row.rank <= 0 || rankingRowScore(row) <= 0) {
      if (insightText.isNotEmpty) reasonByRetailer[id] = insightText;
      continue;
    }
    rankByRetailer[id] = row.rank;
    nameByRetailer[id] = row.retailerName;
    final bool cadenceShown = (insightsByRetailer[id] ?? const <AiInsight>[])
        .take(2)
        .any((AiInsight insight) => insight.isCadenceInsight);
    final double? days = row.daysSinceLastVisit;
    reasonByRetailer[id] = <String>[
      if (insightText.isNotEmpty) insightText,
      'Expected order RM ${row.expectedOrderValueRm.toStringAsFixed(0)}.',
      if (days != null && !(lastOrderBasis && cadenceShown))
        '${lastOrderBasis ? 'Last order' : 'Last contact'} '
            '${days.round()} days ago.',
    ].join(' ');
  }
  insightsByRetailer.forEach((String id, List<AiInsight> rows) {
    reasonByRetailer.putIfAbsent(id, () => routeInsightText(rows));
  });
  return RouteRankingInput(
    rankingId: ranking.rankingId,
    weekKey: ranking.weekKey,
    rankByRetailer: rankByRetailer,
    nameByRetailer: nameByRetailer,
    reasonByRetailer: reasonByRetailer,
  );
}
