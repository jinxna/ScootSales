library;

const int newRetailerMaxDays = 28;

const int activeMaxDaysSinceOrder = 35;

const int dormantMinDaysSinceOrder = 84;

const int churnedMinDaysSinceOrder = 168;

const int longUncoveredMinDays = 42;

const double lowMemoryConfidenceFloor = 0.35;

const Set<String> riskInsightTypes = <String>{
  'overdue_reorder',
  'stopped_product',
};

enum LifecycleStage {
  newcomer,
  active,
  atRisk,
  dormant,
  churned,
  neverOrdered,
  orderHistoryUnknown,
}

const Map<LifecycleStage, int> lifecycleStageRank = <LifecycleStage, int>{
  LifecycleStage.atRisk: 0,
  LifecycleStage.dormant: 1,
  LifecycleStage.churned: 2,
  LifecycleStage.neverOrdered: 3,
  LifecycleStage.newcomer: 4,
  LifecycleStage.active: 5,
  LifecycleStage.orderHistoryUnknown: 6,
};

class LifecycleRetailer {
  const LifecycleRetailer({
    required this.id,
    required this.name,
    this.createdAt,
    this.isAssigned = false,
  });

  final String id;
  final String name;
  final DateTime? createdAt;
  final bool isAssigned;
}

class RetailerOrderStats {
  const RetailerOrderStats({this.firstAt, this.lastAt, this.count = 0});

  final DateTime? firstAt;
  final DateTime? lastAt;
  final int count;
}

class RetailerLifecycle {
  const RetailerLifecycle({
    required this.retailerId,
    required this.retailerName,
    required this.stage,
    required this.daysSinceLastOrder,
    required this.orderCount,
    required this.daysSinceLastCoverage,
    required this.neverAssigned,
    required this.longUncovered,
    required this.lowMemoryConfidence,
    required this.riskInsightCount,
    required this.reason,
  });

  final String retailerId;
  final String retailerName;
  final LifecycleStage stage;

  final int? daysSinceLastOrder;
  final int orderCount;

  final int? daysSinceLastCoverage;

  final bool neverAssigned;

  final bool longUncovered;

  final bool lowMemoryConfidence;

  final int riskInsightCount;

  final String reason;
}

List<RetailerLifecycle> deriveRetailerLifecycles({
  required List<LifecycleRetailer> retailers,
  required Map<String, RetailerOrderStats> orderStatsByRetailer,
  required Map<String, int> riskInsightCountByRetailer,
  required Map<String, double> memoryConfidenceByRetailer,
  Map<String, DateTime> lastVisitByRetailer = const <String, DateTime>{},
  bool orderHistoryComplete = true,
  required DateTime now,
}) {
  final List<RetailerLifecycle> result = <RetailerLifecycle>[];
  for (final LifecycleRetailer retailer in retailers) {
    final String id = retailer.id.trim();
    if (id.isEmpty) continue;

    final RetailerOrderStats stats =
        orderStatsByRetailer[id] ?? const RetailerOrderStats();
    final int riskInsights = riskInsightCountByRetailer[id] ?? 0;
    final double? confidence = memoryConfidenceByRetailer[id];
    final bool lowConfidence =
        confidence != null && confidence < lowMemoryConfidenceFloor;

    int? daysSince(DateTime? at) {
      if (at == null) return null;
      final int days = now.difference(at).inDays;
      return days < 0 ? 0 : days;
    }

    final int? daysSinceLastOrder = daysSince(stats.lastAt);
    final int? daysSinceVisit = daysSince(lastVisitByRetailer[id]);
    final int? daysSinceCoverage =
        daysSinceLastOrder == null && daysSinceVisit == null
        ? null
        : <int>[
            if (daysSinceLastOrder != null) daysSinceLastOrder,
            if (daysSinceVisit != null) daysSinceVisit,
          ].reduce((int a, int b) => a < b ? a : b);

    final DateTime? earliest = retailer.createdAt ?? stats.firstAt;
    final int? ageDays = daysSince(earliest);

    LifecycleStage stage;
    if (ageDays != null && ageDays <= newRetailerMaxDays) {
      stage = LifecycleStage.newcomer;
    } else if (daysSinceLastOrder == null) {
      stage = orderHistoryComplete
          ? LifecycleStage.neverOrdered
          : LifecycleStage.orderHistoryUnknown;
    } else if (daysSinceLastOrder <= activeMaxDaysSinceOrder) {
      stage = riskInsights > 0 ? LifecycleStage.atRisk : LifecycleStage.active;
    } else if (daysSinceLastOrder <= dormantMinDaysSinceOrder) {
      stage = LifecycleStage.atRisk;
    } else if (daysSinceLastOrder <= churnedMinDaysSinceOrder) {
      stage = LifecycleStage.dormant;
    } else {
      stage = LifecycleStage.churned;
    }

    final bool neverAssigned = !retailer.isAssigned;
    final bool longUncovered =
        retailer.isAssigned &&
        (daysSinceCoverage == null || daysSinceCoverage > longUncoveredMinDays);

    result.add(
      RetailerLifecycle(
        retailerId: id,
        retailerName: retailer.name.trim(),
        stage: stage,
        daysSinceLastOrder: daysSinceLastOrder,
        orderCount: stats.count,
        daysSinceLastCoverage: daysSinceCoverage,
        neverAssigned: neverAssigned,
        longUncovered: longUncovered,
        lowMemoryConfidence: lowConfidence,
        riskInsightCount: riskInsights,
        reason: _buildReason(
          stage: stage,
          daysSinceLastOrder: daysSinceLastOrder,
          orderCount: stats.count,
          riskInsights: riskInsights,
          neverAssigned: neverAssigned,
          longUncovered: longUncovered,
          daysSinceCoverage: daysSinceCoverage,
          lowConfidence: lowConfidence,
          ageDays: ageDays,
        ),
      ),
    );
  }

  result.sort((RetailerLifecycle a, RetailerLifecycle b) {
    final int byRank = (lifecycleStageRank[a.stage] ?? 9).compareTo(
      lifecycleStageRank[b.stage] ?? 9,
    );
    if (byRank != 0) return byRank;
    final int byName = a.retailerName.toLowerCase().compareTo(
      b.retailerName.toLowerCase(),
    );
    return byName != 0 ? byName : a.retailerId.compareTo(b.retailerId);
  });
  return result;
}

String _buildReason({
  required LifecycleStage stage,
  required int? daysSinceLastOrder,
  required int orderCount,
  required int riskInsights,
  required bool neverAssigned,
  required bool longUncovered,
  required int? daysSinceCoverage,
  required bool lowConfidence,
  required int? ageDays,
}) {
  final List<String> parts = <String>[];
  switch (stage) {
    case LifecycleStage.newcomer:
      parts.add('onboarded $ageDays day(s) ago');
    case LifecycleStage.active:
      parts.add('last order $daysSinceLastOrder day(s) ago');
    case LifecycleStage.atRisk:
      if (daysSinceLastOrder != null &&
          daysSinceLastOrder > activeMaxDaysSinceOrder) {
        parts.add('last order $daysSinceLastOrder day(s) ago');
      }
      if (riskInsights > 0) {
        parts.add('$riskInsights active reorder-risk insight(s)');
      }
    case LifecycleStage.dormant:
      parts.add(
        'no order for $daysSinceLastOrder day(s) '
        '(dormant after $dormantMinDaysSinceOrder)',
      );
    case LifecycleStage.churned:
      parts.add(
        'no order for $daysSinceLastOrder day(s) '
        '(churned after $churnedMinDaysSinceOrder)',
      );
    case LifecycleStage.neverOrdered:
      parts.add('no order on record ($orderCount total)');
    case LifecycleStage.orderHistoryUnknown:
      parts.add('no order in the loaded history; older orders were not read');
  }
  if (neverAssigned) parts.add('no salesman assigned');
  if (longUncovered) {
    parts.add(
      daysSinceCoverage == null
          ? 'never covered by a visit or order'
          : 'uncovered for $daysSinceCoverage day(s)',
    );
  }
  if (lowConfidence) parts.add('low memory confidence');
  return parts.join(', ');
}
