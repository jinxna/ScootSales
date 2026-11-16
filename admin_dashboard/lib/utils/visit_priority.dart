library;

const double weightOpenInsights = 0.35;

const double weightReplenishmentValue = 0.25;

const double weightVisitRecency = 0.25;

const double weightMemoryConfidence = 0.10;

const double weightServiceCost = 0.05;

const Map<String, double> priorityWeights = <String, double>{
  'openInsights': weightOpenInsights,
  'replenishmentValue': weightReplenishmentValue,
  'visitRecency': weightVisitRecency,
  'memoryConfidence': weightMemoryConfidence,
  'serviceCost': weightServiceCost,
};

const Map<String, double> insightSeverityWeights = <String, double>{
  'overdue_reorder': 2.0,
  'stopped_product': 2.0,
  'declining_sales': 1.5,
  'sales_anomaly': 1.0,
  'growth_opportunity': 1.0,
};
const double defaultInsightSeverity = 1.0;

const double insightSaturation = 4.0;

const double recencySaturationDays = 28.0;

const String openInsightStatus = 'open';

class RetailerRef {
  const RetailerRef({required this.id, required this.name});

  final String id;
  final String name;
}

class PriorityInsight {
  const PriorityInsight({
    required this.retailerId,
    required this.type,
    required this.status,
  });

  final String retailerId;
  final String type;
  final String status;

  bool get isOpen => status.trim().toLowerCase() == openInsightStatus;
  String get normalizedType => type.trim().toLowerCase();
}

class VisitPriority {
  const VisitPriority({
    required this.retailerId,
    required this.retailerName,
    required this.score,
    required this.contributions,
    required this.reason,
    required this.openInsightCount,
    required this.replenishmentValueRm,
    required this.daysSinceLastVisit,
    required this.neverVisited,
  });

  final String retailerId;
  final String retailerName;

  final double score;

  final Map<String, double> contributions;

  final String reason;

  final int openInsightCount;

  final double replenishmentValueRm;

  final int? daysSinceLastVisit;
  final bool neverVisited;
}

List<VisitPriority> deriveVisitPriorities({
  required List<RetailerRef> retailers,
  required List<PriorityInsight> insights,
  required Map<String, double> replenishmentValueByRetailer,
  Map<String, double>? memoryConfidenceByRetailer,
  required Map<String, DateTime?> lastVisitByRetailer,
  Map<String, double>? serviceMinutesByRetailer,
  required DateTime now,
}) {
  final List<RetailerRef> candidates = <RetailerRef>[
    for (final RetailerRef retailer in retailers)
      if (retailer.id.trim().isNotEmpty) retailer,
  ];
  if (candidates.isEmpty) return const <VisitPriority>[];

  final Map<String, double> insightWeightByRetailer = <String, double>{};
  final Map<String, int> openCountByRetailer = <String, int>{};
  for (final PriorityInsight insight in insights) {
    if (!insight.isOpen) continue;
    final String retailerId = insight.retailerId.trim();
    if (retailerId.isEmpty) continue;
    final double severity =
        insightSeverityWeights[insight.normalizedType] ??
        defaultInsightSeverity;
    insightWeightByRetailer.update(
      retailerId,
      (double v) => v + severity,
      ifAbsent: () => severity,
    );
    openCountByRetailer.update(retailerId, (int v) => v + 1, ifAbsent: () => 1);
  }

  double maxReplenishment = 0.0;
  double maxServiceMinutes = 0.0;
  for (final RetailerRef retailer in candidates) {
    final double value = replenishmentValueByRetailer[retailer.id] ?? 0.0;
    if (value > maxReplenishment) maxReplenishment = value;
    final double? service = serviceMinutesByRetailer?[retailer.id];
    if (service != null && service.isFinite && service > maxServiceMinutes) {
      maxServiceMinutes = service;
    }
  }

  final List<VisitPriority> result = <VisitPriority>[];
  for (final RetailerRef retailer in candidates) {
    final String id = retailer.id;

    final double insightWeight = insightWeightByRetailer[id] ?? 0.0;
    final int openCount = openCountByRetailer[id] ?? 0;
    final double insightFactor = (insightWeight / insightSaturation).clamp(
      0.0,
      1.0,
    );

    final double replenishmentValue = replenishmentValueByRetailer[id] ?? 0.0;
    final double replenishmentFactor = maxReplenishment > 0
        ? (replenishmentValue / maxReplenishment)
        : 0.0;

    final bool hasVisit =
        lastVisitByRetailer.containsKey(id) && lastVisitByRetailer[id] != null;
    int? daysSinceLastVisit;
    double recencyFactor;
    if (!hasVisit) {
      recencyFactor = 1.0;
    } else {
      final int days = now.difference(lastVisitByRetailer[id]!).inDays;
      final int clampedDays = days < 0 ? 0 : days;
      daysSinceLastVisit = clampedDays;
      recencyFactor = (clampedDays / recencySaturationDays).clamp(0.0, 1.0);
    }

    double memoryFactor = 0.0;
    final double? confidence = memoryConfidenceByRetailer?[id];
    if (confidence != null) {
      memoryFactor = (1.0 - confidence).clamp(0.0, 1.0);
    }

    double serviceFactor = 0.0;
    final double? rawService = serviceMinutesByRetailer?[id];
    final double? service =
        rawService != null && rawService.isFinite && rawService > 0
        ? rawService
        : null;
    if (service != null && maxServiceMinutes > 0) {
      serviceFactor = (1.0 - (service / maxServiceMinutes)).clamp(0.0, 1.0);
    }

    final Map<String, double> contributions = <String, double>{
      'openInsights': weightOpenInsights * insightFactor,
      'replenishmentValue': weightReplenishmentValue * replenishmentFactor,
      'visitRecency': weightVisitRecency * recencyFactor,
      'memoryConfidence': weightMemoryConfidence * memoryFactor,
      'serviceCost': weightServiceCost * serviceFactor,
    };
    final double score = contributions.values.fold(
      0.0,
      (double sum, double v) => sum + v,
    );

    result.add(
      VisitPriority(
        retailerId: id,
        retailerName: retailer.name,
        score: score,
        contributions: contributions,
        reason: _buildReason(
          openCount: openCount,
          replenishmentValue: replenishmentValue,
          neverVisited: !hasVisit,
          daysSinceLastVisit: daysSinceLastVisit,
          memoryFactor: memoryFactor,
          serviceFactor: serviceFactor,
          service: service,
        ),
        openInsightCount: openCount,
        replenishmentValueRm: replenishmentValue,
        daysSinceLastVisit: daysSinceLastVisit,
        neverVisited: !hasVisit,
      ),
    );
  }

  result.sort((VisitPriority a, VisitPriority b) {
    final int byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.retailerId.compareTo(b.retailerId);
  });
  return result;
}

String _buildReason({
  required int openCount,
  required double replenishmentValue,
  required bool neverVisited,
  required int? daysSinceLastVisit,
  required double memoryFactor,
  required double serviceFactor,
  required double? service,
}) {
  final List<String> parts = <String>[];
  if (openCount > 0) {
    parts.add('$openCount open insight${openCount == 1 ? '' : 's'}');
  }
  if (replenishmentValue > 0) {
    parts.add('RM${replenishmentValue.round()} expected reorder');
  }
  if (neverVisited) {
    parts.add('no recent visit on record');
  } else if (daysSinceLastVisit != null && daysSinceLastVisit > 0) {
    parts.add(
      '$daysSinceLastVisit day${daysSinceLastVisit == 1 ? '' : 's'} since last visit',
    );
  }
  if (memoryFactor > 0) {
    parts.add('low retailer confidence');
  }
  if (service != null && serviceFactor > 0) {
    parts.add('${service.round()} min service');
  }
  if (parts.isEmpty) return 'No active priority signals';
  return parts.join(', ');
}
