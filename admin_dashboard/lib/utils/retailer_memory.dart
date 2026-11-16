library;

const int memoryWindowDays = 56;

const double minDecayWeight = 0.25;

const double unknownAgeWeight = 0.1;

const double priceSensitivityThreshold = 0.3;

const Set<String> priceReasonCodes = <String>{
  'price_too_high',
  'cash_flow_issue',
};

const Set<String> followUpReasonCodes = <String>{
  'not_asked_today',
  'retailer_busy',
  'decision_maker_unavailable',
  'not_decision_maker',
};

const double confidenceSaturation = 4.0;
const double confidenceMediumFloor = 0.35;
const double confidenceHighFloor = 0.7;

class RetailerOutcomeEvent {
  const RetailerOutcomeEvent({
    required this.reasonCode,
    this.replacementProductId = '',
    this.productId = '',
    this.productName = '',
    this.issueKey = '',
    this.submittedAt,
    this.isDemo = false,
  });

  final String reasonCode;
  final String replacementProductId;
  final String productId;
  final String productName;
  final String issueKey;
  final DateTime? submittedAt;
  final bool isDemo;
}

class ReasonStat {
  const ReasonStat({
    required this.reasonCode,
    required this.count,
    required this.share,
  });

  final String reasonCode;
  final int count;

  final double share;
}

class ReplacementStat {
  const ReplacementStat({required this.productId, required this.count});

  final String productId;
  final int count;
}

class IssueMemory {
  const IssueMemory({
    required this.issueKey,
    required this.productName,
    required this.reasonCode,
    this.at,
    required this.needsFollowUp,
  });

  final String issueKey;
  final String productName;
  final String reasonCode;
  final DateTime? at;
  final bool needsFollowUp;
}

class RetailerMemory {
  const RetailerMemory({
    required this.outcomeCount,
    required this.demoCount,
    this.mostRecentAt,
    required this.topReasons,
    required this.priceSensitivityShare,
    required this.isPriceSensitive,
    required this.hasSeasonalitySignal,
    this.lastSeasonalAt,
    required this.commonReplacements,
    required this.lastIssues,
    required this.confidence,
  });

  final int outcomeCount;

  final int demoCount;
  final DateTime? mostRecentAt;
  final List<ReasonStat> topReasons;
  final double priceSensitivityShare;
  final bool isPriceSensitive;
  final bool hasSeasonalitySignal;
  final DateTime? lastSeasonalAt;
  final List<ReplacementStat> commonReplacements;

  final List<IssueMemory> lastIssues;

  final double confidence;

  bool get isEmpty => outcomeCount == 0;

  String get confidenceLabel {
    if (confidence >= confidenceHighFloor) return 'High';
    if (confidence >= confidenceMediumFloor) return 'Medium';
    return 'Low';
  }

  static const RetailerMemory empty = RetailerMemory(
    outcomeCount: 0,
    demoCount: 0,
    topReasons: <ReasonStat>[],
    priceSensitivityShare: 0,
    isPriceSensitive: false,
    hasSeasonalitySignal: false,
    commonReplacements: <ReplacementStat>[],
    lastIssues: <IssueMemory>[],
    confidence: 0,
  );
}

double decayWeight(int ageDays) {
  if (ageDays < 0) return 1.0;
  if (ageDays > memoryWindowDays) return 0;
  return 1.0 - (1.0 - minDecayWeight) * (ageDays / memoryWindowDays);
}

RetailerMemory deriveRetailerMemory(
  Iterable<RetailerOutcomeEvent> events, {
  required DateTime now,
  int maxReasons = 3,
  int maxReplacements = 3,
  int maxIssues = 3,
}) {
  final List<RetailerOutcomeEvent> kept = <RetailerOutcomeEvent>[];
  final List<double> weights = <double>[];
  for (final RetailerOutcomeEvent event in events) {
    final String reason = event.reasonCode.trim().toLowerCase();
    if (reason.isEmpty) continue;
    final DateTime? at = event.submittedAt;
    if (at == null) {
      kept.add(event);
      weights.add(unknownAgeWeight);
      continue;
    }
    final double weight = decayWeight(now.difference(at).inDays);
    if (weight <= 0) continue;
    kept.add(event);
    weights.add(weight);
  }
  if (kept.isEmpty) return RetailerMemory.empty;

  double totalWeight = 0;
  double priceWeight = 0;
  int priceCount = 0;
  int demoCount = 0;
  DateTime? mostRecentAt;
  DateTime? lastSeasonalAt;
  bool seasonal = false;
  final Map<String, double> reasonWeights = <String, double>{};
  final Map<String, int> reasonCounts = <String, int>{};
  final Map<String, double> replacementWeights = <String, double>{};
  final Map<String, int> replacementCounts = <String, int>{};
  final Map<String, RetailerOutcomeEvent> latestByIssue =
      <String, RetailerOutcomeEvent>{};

  for (int i = 0; i < kept.length; i++) {
    final RetailerOutcomeEvent event = kept[i];
    final double weight = weights[i];
    final String reason = event.reasonCode.trim().toLowerCase();
    totalWeight += weight;
    if (event.isDemo) demoCount++;
    reasonWeights.update(
      reason,
      (double value) => value + weight,
      ifAbsent: () => weight,
    );
    reasonCounts.update(reason, (int value) => value + 1, ifAbsent: () => 1);
    if (priceReasonCodes.contains(reason)) {
      priceWeight += weight;
      priceCount++;
    }
    if (reason == 'seasonal_change') {
      seasonal = true;
      final DateTime? at = event.submittedAt;
      if (at != null &&
          (lastSeasonalAt == null || at.isAfter(lastSeasonalAt))) {
        lastSeasonalAt = at;
      }
    }
    if (reason == 'switched_to_alternative') {
      final String replacement = event.replacementProductId.trim();
      if (replacement.isNotEmpty) {
        replacementWeights.update(
          replacement,
          (double value) => value + weight,
          ifAbsent: () => weight,
        );
        replacementCounts.update(
          replacement,
          (int value) => value + 1,
          ifAbsent: () => 1,
        );
      }
    }
    final DateTime? at = event.submittedAt;
    if (at != null && (mostRecentAt == null || at.isAfter(mostRecentAt))) {
      mostRecentAt = at;
    }
    final String issueKey = event.issueKey.trim();
    if (issueKey.isNotEmpty) {
      final RetailerOutcomeEvent? existing = latestByIssue[issueKey];
      final DateTime existingAt =
          existing?.submittedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime candidateAt = at ?? DateTime.fromMillisecondsSinceEpoch(0);
      if (existing == null || !candidateAt.isBefore(existingAt)) {
        latestByIssue[issueKey] = event;
      }
    }
  }

  final List<ReasonStat> topReasons =
      reasonWeights.entries
          .map(
            (MapEntry<String, double> entry) => ReasonStat(
              reasonCode: entry.key,
              count: reasonCounts[entry.key] ?? 0,
              share: totalWeight <= 0 ? 0 : entry.value / totalWeight,
            ),
          )
          .toList()
        ..sort((ReasonStat left, ReasonStat right) {
          final int byShare = right.share.compareTo(left.share);
          return byShare != 0
              ? byShare
              : left.reasonCode.compareTo(right.reasonCode);
        });

  final List<ReplacementStat> replacements =
      replacementWeights.entries
          .map(
            (MapEntry<String, double> entry) => ReplacementStat(
              productId: entry.key,
              count: replacementCounts[entry.key] ?? 0,
            ),
          )
          .toList()
        ..sort((ReplacementStat left, ReplacementStat right) {
          final int byWeight = (replacementWeights[right.productId] ?? 0)
              .compareTo(replacementWeights[left.productId] ?? 0);
          return byWeight != 0
              ? byWeight
              : left.productId.compareTo(right.productId);
        });

  final List<IssueMemory> issues =
      latestByIssue.entries
          .map(
            (MapEntry<String, RetailerOutcomeEvent> entry) => IssueMemory(
              issueKey: entry.key,
              productName: entry.value.productName,
              reasonCode: entry.value.reasonCode.trim().toLowerCase(),
              at: entry.value.submittedAt,
              needsFollowUp: followUpReasonCodes.contains(
                entry.value.reasonCode.trim().toLowerCase(),
              ),
            ),
          )
          .toList()
        ..sort((IssueMemory left, IssueMemory right) {
          final DateTime leftAt =
              left.at ?? DateTime.fromMillisecondsSinceEpoch(0);
          final DateTime rightAt =
              right.at ?? DateTime.fromMillisecondsSinceEpoch(0);
          final int byDate = rightAt.compareTo(leftAt);
          return byDate != 0 ? byDate : left.issueKey.compareTo(right.issueKey);
        });

  final double priceShare = totalWeight <= 0 ? 0 : priceWeight / totalWeight;
  final double confidence = (totalWeight / confidenceSaturation).clamp(
    0.0,
    1.0,
  );

  return RetailerMemory(
    outcomeCount: kept.length,
    demoCount: demoCount,
    mostRecentAt: mostRecentAt,
    topReasons: topReasons.take(maxReasons).toList(growable: false),
    priceSensitivityShare: priceShare,
    isPriceSensitive:
        priceShare >= priceSensitivityThreshold && priceCount >= 2,
    hasSeasonalitySignal: seasonal,
    lastSeasonalAt: lastSeasonalAt,
    commonReplacements: replacements
        .take(maxReplacements)
        .toList(growable: false),
    lastIssues: issues.take(maxIssues).toList(growable: false),
    confidence: confidence,
  );
}

String reasonCodeLabel(String reasonCode) {
  return reasonCode
      .split('_')
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) =>
            '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}
