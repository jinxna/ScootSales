library;

const double minServiceMinutes = 1.0;
const double maxServiceMinutes = 240.0;

const double serviceConfidenceSaturation = 4.0;
const double confidenceMediumFloor = 0.35;
const double confidenceHighFloor = 0.7;

const double chronicSkipRate = 0.5;
const int chronicMinPlanned = 3;

class StopExecutionEvent {
  const StopExecutionEvent({
    required this.retailerId,
    this.stopId = '',
    this.planId = '',
    this.status = '',
    this.arrivedAt,
    this.completedAt,
    this.skippedAt,
    this.skipReason = '',
  });

  final String retailerId;
  final String stopId;
  final String planId;

  final String status;
  final DateTime? arrivedAt;
  final DateTime? completedAt;
  final DateTime? skippedAt;
  final String skipReason;

  String get normalizedStatus => status.trim().toLowerCase();
}

class ServiceTimeStat {
  const ServiceTimeStat({
    required this.retailerId,
    required this.meanServiceMinutes,
    required this.sampleCount,
    required this.confidence,
  });

  final String retailerId;
  final double? meanServiceMinutes;

  final int sampleCount;

  final double confidence;

  bool get hasEstimate => meanServiceMinutes != null;

  bool get usedInPlanning => hasEstimate && confidence >= confidenceHighFloor;

  String get confidenceLabel {
    if (confidence >= confidenceHighFloor) return 'High';
    if (confidence >= confidenceMediumFloor) return 'Medium';
    return 'Low';
  }
}

class AdherenceResult {
  const AdherenceResult({
    required this.score,
    required this.comparedStops,
    required this.inversions,
    required this.completedCount,
    required this.skippedCount,
    required this.plannedCount,
    required this.completionRate,
  });

  final double? score;

  final int comparedStops;

  final int inversions;

  final int completedCount;
  final int skippedCount;

  final int plannedCount;

  final double completionRate;

  bool get hasScore => score != null;
}

class SkipPattern {
  const SkipPattern({
    required this.retailerId,
    required this.skipCount,
    required this.totalPlanned,
    required this.skipRate,
    required this.isChronic,
    this.lastSkipReason,
    this.lastSkipAt,
  });

  final String retailerId;
  final int skipCount;

  final int totalPlanned;

  final double skipRate;

  final bool isChronic;

  final String? lastSkipReason;
  final DateTime? lastSkipAt;
}

Map<String, ServiceTimeStat> deriveServiceTimes(
  Iterable<StopExecutionEvent> events,
) {
  final Map<String, List<double>> durationsByRetailer =
      <String, List<double>>{};
  final Set<String> seenRetailers = <String>{};

  for (final StopExecutionEvent event in events) {
    final String retailerId = event.retailerId.trim();
    if (retailerId.isEmpty) continue;
    seenRetailers.add(retailerId);
    if (event.normalizedStatus == 'skipped') continue;
    final DateTime? start = event.arrivedAt;
    final DateTime? end = event.completedAt;
    if (start == null || end == null) continue;
    final double minutes = end.difference(start).inMilliseconds / 60000.0;
    if (minutes < minServiceMinutes || minutes > maxServiceMinutes) continue;
    durationsByRetailer.putIfAbsent(retailerId, () => <double>[]).add(minutes);
  }

  final List<String> retailers = seenRetailers.toList()..sort();
  final Map<String, ServiceTimeStat> result = <String, ServiceTimeStat>{};
  for (final String retailerId in retailers) {
    final List<double> durations =
        durationsByRetailer[retailerId] ?? const <double>[];
    final int sampleCount = durations.length;
    final double? mean = sampleCount == 0
        ? null
        : durations.reduce((double a, double b) => a + b) / sampleCount;
    final double confidence = (sampleCount / serviceConfidenceSaturation).clamp(
      0.0,
      1.0,
    );
    result[retailerId] = ServiceTimeStat(
      retailerId: retailerId,
      meanServiceMinutes: mean,
      sampleCount: sampleCount,
      confidence: confidence,
    );
  }
  return result;
}

AdherenceResult deriveAdherence(
  List<String> plannedStopIds,
  Iterable<StopExecutionEvent> executedEvents,
) {
  final List<String> planned = plannedStopIds
      .map((String id) => id.trim())
      .where((String id) => id.isNotEmpty)
      .toList();
  final Map<String, int> plannedIndex = <String, int>{};
  for (int i = 0; i < planned.length; i++) {
    plannedIndex.putIfAbsent(planned[i], () => i);
  }
  final int plannedCount = plannedIndex.length;

  int completedCount = 0;
  int skippedCount = 0;
  bool missingTimestamp = false;
  final List<_ExecutedStop> completedPlanned = <_ExecutedStop>[];

  for (final StopExecutionEvent event in executedEvents) {
    final String stopId = event.stopId.trim();
    final String status = event.normalizedStatus;
    if (status == 'completed') {
      completedCount++;
      if (!plannedIndex.containsKey(stopId)) continue;
      final DateTime? at = event.completedAt;
      if (at == null) {
        missingTimestamp = true;
        continue;
      }
      completedPlanned.add(
        _ExecutedStop(
          stopId: stopId,
          plannedIndex: plannedIndex[stopId]!,
          at: at,
        ),
      );
    } else if (status == 'skipped') {
      skippedCount++;
    }
  }

  final double completionRate = plannedCount == 0
      ? 0.0
      : completedCount / plannedCount;

  if (missingTimestamp || completedPlanned.isEmpty) {
    return AdherenceResult(
      score: null,
      comparedStops: 0,
      inversions: 0,
      completedCount: completedCount,
      skippedCount: skippedCount,
      plannedCount: plannedCount,
      completionRate: completionRate,
    );
  }

  completedPlanned.sort((_ExecutedStop a, _ExecutedStop b) {
    final int byTime = a.at.compareTo(b.at);
    return byTime != 0 ? byTime : a.stopId.compareTo(b.stopId);
  });

  final int n = completedPlanned.length;
  int inversions = 0;
  for (int i = 0; i < n; i++) {
    for (int j = i + 1; j < n; j++) {
      if (completedPlanned[i].plannedIndex > completedPlanned[j].plannedIndex) {
        inversions++;
      }
    }
  }
  final int maxInversions = n * (n - 1) ~/ 2;
  final double score = maxInversions == 0
      ? 1.0
      : 1.0 - inversions / maxInversions;

  return AdherenceResult(
    score: score,
    comparedStops: n,
    inversions: inversions,
    completedCount: completedCount,
    skippedCount: skippedCount,
    plannedCount: plannedCount,
    completionRate: completionRate,
  );
}

Map<String, SkipPattern> deriveSkipPatterns(
  Iterable<StopExecutionEvent> events,
) {
  final Map<String, int> skips = <String, int>{};
  final Map<String, int> decided = <String, int>{};
  final Map<String, DateTime?> lastSkipAt = <String, DateTime?>{};
  final Map<String, String> lastSkipReason = <String, String>{};

  for (final StopExecutionEvent event in events) {
    final String retailerId = event.retailerId.trim();
    if (retailerId.isEmpty) continue;
    final String status = event.normalizedStatus;
    final bool isSkip = status == 'skipped';
    final bool isCompleted = status == 'completed';
    if (!isSkip && !isCompleted) continue;
    decided.update(retailerId, (int v) => v + 1, ifAbsent: () => 1);
    if (isSkip) {
      skips.update(retailerId, (int v) => v + 1, ifAbsent: () => 1);
      final DateTime? at = event.skippedAt;
      final DateTime? prev = lastSkipAt[retailerId];
      if (!lastSkipAt.containsKey(retailerId) ||
          (at != null && (prev == null || at.isAfter(prev)))) {
        lastSkipAt[retailerId] = at;
        lastSkipReason[retailerId] = event.skipReason.trim();
      }
    }
  }

  final List<String> retailers = decided.keys.toList()..sort();
  final Map<String, SkipPattern> result = <String, SkipPattern>{};
  for (final String retailerId in retailers) {
    final int totalPlanned = decided[retailerId] ?? 0;
    final int skipCount = skips[retailerId] ?? 0;
    final double skipRate = totalPlanned == 0 ? 0.0 : skipCount / totalPlanned;
    final bool isChronic =
        skipRate >= chronicSkipRate && totalPlanned >= chronicMinPlanned;
    final String reason = lastSkipReason[retailerId]?.trim() ?? '';
    result[retailerId] = SkipPattern(
      retailerId: retailerId,
      skipCount: skipCount,
      totalPlanned: totalPlanned,
      skipRate: skipRate,
      isChronic: isChronic,
      lastSkipReason: reason.isEmpty ? null : reason,
      lastSkipAt: lastSkipAt[retailerId],
    );
  }
  return result;
}

DateTime? parseEventTimestamp(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  if (raw is num) {
    final int value = raw.toInt();
    return DateTime.fromMillisecondsSinceEpoch(
      value < 10000000000 ? value * 1000 : value,
    );
  }
  try {
    final dynamic dynamicValue = raw;
    final Object? converted = dynamicValue.toDate();
    if (converted is DateTime) return converted;
  } catch (_) {}
  return DateTime.tryParse(raw.toString());
}

List<StopExecutionEvent> mapProgressDocToEvents(
  Map<String, dynamic> progressDoc, {
  String? planId,

  List<Map<String, dynamic>> stopDocuments = const <Map<String, dynamic>>[],
}) {
  final String resolvedPlanId =
      (planId ?? progressDoc['planId']?.toString() ?? '').trim();
  final Map<String, Map<String, dynamic>> legacyByStopId =
      <String, Map<String, dynamic>>{};
  final Object? stopProgressRaw = progressDoc['stopProgress'];
  if (stopProgressRaw is Map) {
    for (final MapEntry<dynamic, dynamic> entry in stopProgressRaw.entries) {
      final Object? rawStop = entry.value;
      if (rawStop is! Map) continue;
      final String stopId = (rawStop['stopId'] ?? entry.key).toString().trim();
      if (stopId.isEmpty) continue;
      legacyByStopId[stopId] = rawStop.map<String, dynamic>(
        (Object? key, Object? value) =>
            MapEntry<String, dynamic>(key.toString(), value),
      );
    }
  }

  final List<StopExecutionEvent> merged = <StopExecutionEvent>[];
  final Set<String> coveredStopIds = <String>{};
  for (final Map<String, dynamic> stopDoc in stopDocuments) {
    final String retailerId = (stopDoc['retailerId'] ?? '').toString().trim();
    final String stopId = (stopDoc['stopId'] ?? '').toString().trim();
    if (stopId.isEmpty || retailerId.isEmpty) continue;
    coveredStopIds.add(stopId);
    final Map<String, dynamic> legacy =
        legacyByStopId[stopId] ?? const <String, dynamic>{};
    final String arrivalStatus = (stopDoc['status'] ?? '').toString();
    final String legacyStatus = (legacy['status'] ?? '').toString();
    final String status =
        _isTerminalStopStatus(arrivalStatus) ||
            !_isTerminalStopStatus(legacyStatus)
        ? arrivalStatus
        : legacyStatus;
    merged.add(
      StopExecutionEvent(
        retailerId: retailerId,
        stopId: stopId,
        planId: (stopDoc['planId'] ?? resolvedPlanId).toString(),
        status: status,
        arrivedAt:
            parseEventTimestamp(stopDoc['arrivedAt']) ??
            parseEventTimestamp(legacy['arrivedAt']),
        completedAt:
            parseEventTimestamp(stopDoc['completedAt']) ??
            parseEventTimestamp(legacy['completedAt']),
        skippedAt:
            parseEventTimestamp(stopDoc['skippedAt']) ??
            parseEventTimestamp(legacy['skippedAt']),
        skipReason: _firstNonEmptyText(<Object?>[
          stopDoc['skipReason'],
          legacy['skipReason'],
        ]),
      ),
    );
  }

  for (final MapEntry<String, Map<String, dynamic>> entry
      in legacyByStopId.entries) {
    if (coveredStopIds.contains(entry.key)) continue;
    final Map<String, dynamic> rawStop = entry.value;
    final String retailerId = (rawStop['retailerId'] ?? '').toString().trim();
    if (retailerId.isEmpty) continue;
    merged.add(
      StopExecutionEvent(
        retailerId: retailerId,
        stopId: entry.key,
        planId: resolvedPlanId,
        status: (rawStop['status'] ?? '').toString(),
        arrivedAt: parseEventTimestamp(rawStop['arrivedAt']),
        completedAt: parseEventTimestamp(rawStop['completedAt']),
        skippedAt: parseEventTimestamp(rawStop['skippedAt']),
        skipReason: (rawStop['skipReason'] ?? '').toString(),
      ),
    );
  }
  return merged;
}

bool _isTerminalStopStatus(String status) {
  final String normalized = status.trim().toLowerCase();
  return normalized == 'completed' || normalized == 'skipped';
}

String _firstNonEmptyText(List<Object?> values) {
  for (final Object? value in values) {
    final String text = (value ?? '').toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

class _ExecutedStop {
  const _ExecutedStop({
    required this.stopId,
    required this.plannedIndex,
    required this.at,
  });

  final String stopId;
  final int plannedIndex;
  final DateTime at;
}
