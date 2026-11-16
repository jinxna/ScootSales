import 'retailer_readiness.dart';
import 'order_data_utils.dart';

List<Map<String, dynamic>> filterTrustImpactProductionRows(
  List<Map<String, dynamic>> rows, {
  bool retailers = false,
}) {
  return rows
      .where(
        (Map<String, dynamic> row) =>
            !(retailers ? isDemoRetailerRecord(row) : isDemoRow(row)),
      )
      .toList(growable: false);
}

class TrustMetric {
  const TrustMetric({
    required this.label,
    required this.value,
    required this.sampleSize,
    required this.explanation,
    this.available = true,
    this.numerator,
  });

  final String label;
  final String value;
  final int sampleSize;
  final String explanation;
  final bool available;
  final int? numerator;
}

class TrustImpactReport {
  const TrustImpactReport({
    required this.metrics,
    required this.abstentionReasons,
    required this.latestEvidenceAt,
    this.unavailableAbstentionReasons = const <String>{},
  });

  final List<TrustMetric> metrics;
  final Map<String, int> abstentionReasons;
  final DateTime? latestEvidenceAt;
  final Set<String> unavailableAbstentionReasons;
}

TrustImpactReport deriveTrustImpactReport({
  required List<Map<String, dynamic>> weeklySummaries,
  required List<Map<String, dynamic>> visitBriefs,
  required List<Map<String, dynamic>> orders,
  required List<Map<String, dynamic>> routePlans,
  required List<Map<String, dynamic>> routeProgress,
  required List<Map<String, dynamic>> insights,
  required List<Map<String, dynamic>> retailers,
}) {
  weeklySummaries = filterTrustImpactProductionRows(weeklySummaries);
  visitBriefs = filterTrustImpactProductionRows(visitBriefs);
  orders = filterTrustImpactProductionRows(orders);
  routePlans = filterTrustImpactProductionRows(routePlans);
  routeProgress = filterTrustImpactProductionRows(routeProgress);
  insights = filterTrustImpactProductionRows(insights);
  retailers = filterTrustImpactProductionRows(retailers, retailers: true);

  final int evaluated = weeklySummaries.fold<int>(0, (
    int total,
    Map<String, dynamic> row,
  ) {
    final Map<String, dynamic> accuracy = _forecastAccuracy(row);
    return total +
        _integer(
          accuracy['evaluatedForecastCount'] ?? accuracy['evaluatedCount'],
        );
  });
  double weighted(String key, String fallbackKey) {
    if (evaluated == 0) return 0;
    double total = 0;
    for (final Map<String, dynamic> row in weeklySummaries) {
      final Map<String, dynamic> accuracy = _forecastAccuracy(row);
      final int count = _integer(
        accuracy['evaluatedForecastCount'] ?? accuracy['evaluatedCount'],
      );
      total += _number(accuracy[key] ?? accuracy[fallbackKey]) * count;
    }
    return total / evaluated;
  }

  double? weightedMape() {
    double total = 0;
    int weight = 0;
    for (final Map<String, dynamic> row in weeklySummaries) {
      final Map<String, dynamic> accuracy = _forecastAccuracy(row);
      final Object? value =
          accuracy['meanAbsolutePercentageError'] ?? accuracy['mape'];
      if (value is! num) continue;
      final int count = _integer(
        accuracy['percentageErrorCount'] ??
            accuracy['evaluatedForecastCount'] ??
            accuracy['evaluatedCount'],
      );
      total += value.toDouble() * count;
      weight += count;
    }
    return weight == 0 ? null : total / weight;
  }

  final double? mape = weightedMape();

  final Set<String> retailerIds = retailers
      .map(_retailerId)
      .where((String value) => value.isNotEmpty)
      .toSet();
  final Set<String> recommendedRetailers = <String>{};
  final Map<String, _Suggestion> suggestions = <String, _Suggestion>{};
  int stoppedProducts = 0;
  for (final Map<String, dynamic> brief in visitBriefs) {
    final String retailerId = _retailerId(brief);
    final Object? raw = brief['replenishment'];
    if (raw is List && retailerId.isNotEmpty) {
      final List<Map> usableRows = raw
          .whereType<Map>()
          .where((Map item) {
            final Object? quantity = item['suggestedQty'];
            return item['suggestionStatus'] == 'suggested' &&
                quantity is num &&
                quantity.isFinite &&
                quantity > 0;
          })
          .toList(growable: false);
      if (usableRows.isNotEmpty) recommendedRetailers.add(retailerId);
      for (final Map item in usableRows) {
        final String productId = _text(item['productId']);
        if (productId.isNotEmpty) {
          final String key = '$retailerId|$productId';
          final _Suggestion candidate = _Suggestion(
            retailerId: retailerId,
            productId: productId,
            generatedAt: _date(brief['generatedAt'] ?? brief['updatedAt']),
          );
          final _Suggestion? previous = suggestions[key];
          if (previous == null ||
              (candidate.generatedAt != null &&
                  (previous.generatedAt == null ||
                      candidate.generatedAt!.isAfter(previous.generatedAt!)))) {
            suggestions[key] = candidate;
          }
        }
      }
    }
    final Object? memory = brief['retailerMemory'];
    if (memory is Map) {
      final Object? reasons = memory['commonReasonCodes'];
      if (reasons is List && reasons.map(_text).contains('stopped_product')) {
        stoppedProducts++;
      }
    }
  }

  final Set<String> orderedPairs = <String>{};
  final int recommendedKnownRetailers = recommendedRetailers
      .where(retailerIds.contains)
      .length;
  final List<_Suggestion> comparableSuggestions = suggestions.values
      .where((_Suggestion suggestion) => suggestion.generatedAt != null)
      .toList(growable: false);
  int missingProductIdentity = 0;
  for (final Map<String, dynamic> order in orders) {
    final String retailerId = _retailerId(order);
    final DateTime? submittedAt = orderCountsAsSale(order)
        ? _date(order['submittedAt'] ?? order['createdAt'])
        : null;
    final Object? rawItems = order['items'];
    if (rawItems is! List) continue;
    for (final Object? raw in rawItems) {
      if (raw is! Map) continue;
      final String productId = _text(raw['productId']);
      if (productId.isEmpty) {
        missingProductIdentity++;
        continue;
      }
      if (submittedAt == null) continue;
      for (final _Suggestion suggestion in comparableSuggestions) {
        if (suggestion.retailerId != retailerId ||
            suggestion.productId != productId) {
          continue;
        }
        if (submittedAt.isBefore(suggestion.generatedAt!)) {
          continue;
        }
        orderedPairs.add('${suggestion.retailerId}|${suggestion.productId}');
      }
    }
  }

  final Set<String> priorityStops = <String>{};
  for (final Map<String, dynamic> plan in routePlans) {
    final String planId = _text(plan['planId'] ?? plan['docId']);
    final Object? rawDays = plan['days'];
    if (rawDays is! List) continue;
    for (final Object? rawDay in rawDays) {
      if (rawDay is! Map || rawDay['stops'] is! List) continue;
      for (final Object? rawStop in rawDay['stops'] as List) {
        if (rawStop is! Map) continue;
        final String reason = _text(rawStop['priorityReason']);
        final String stopId = _text(rawStop['stopId']);
        if (planId.isNotEmpty && reason.isNotEmpty && stopId.isNotEmpty) {
          priorityStops.add('$planId|$stopId');
        }
      }
    }
  }
  final Set<String> completedPriorityStops = <String>{};
  for (final Map<String, dynamic> progress in routeProgress) {
    final String planId = _text(progress['planId']);
    final Object? raw = progress['stopProgress'];
    if (raw is! Map) continue;
    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      if (entry.value is! Map) continue;
      final String status = _text((entry.value as Map)['status']).toLowerCase();
      final String stopId = _text(entry.key);
      final String key = '$planId|$stopId';
      if (status == 'completed' && priorityStops.contains(key)) {
        completedPriorityStops.add(key);
      }
    }
  }

  int resolved = 0;
  final List<double> resolutionHours = <double>[];
  for (final Map<String, dynamic> insight in insights) {
    final String status = _text(
      insight['status'] ?? insight['autoState'],
    ).toLowerCase();
    if (status != 'resolved' && status != 'suppressed') continue;
    resolved++;
    final DateTime? opened = _date(insight['createdAt']);
    final DateTime? closed = _date(
      insight['resolvedAt'] ?? insight['updatedAt'],
    );
    if (opened != null && closed != null && !closed.isBefore(opened)) {
      resolutionHours.add(closed.difference(opened).inMinutes / 60);
    }
  }
  resolutionHours.sort();
  final double? medianHours = resolutionHours.isEmpty
      ? null
      : resolutionHours.length.isOdd
      ? resolutionHours[resolutionHours.length ~/ 2]
      : (resolutionHours[resolutionHours.length ~/ 2 - 1] +
                resolutionHours[resolutionHours.length ~/ 2]) /
            2;

  int unverifiedCoordinates = 0;
  for (final Map<String, dynamic> retailer in retailers) {
    if (retailerCoordinateStatus(retailer) != CoordinateStatus.verified) {
      unverifiedCoordinates++;
    }
  }

  final List<DateTime> dates = <DateTime>[];
  for (final List<Map<String, dynamic>> rows in <List<Map<String, dynamic>>>[
    weeklySummaries,
    visitBriefs,
    orders,
    routePlans,
    routeProgress,
    insights,
  ]) {
    for (final Map<String, dynamic> row in rows) {
      final DateTime? value = _date(
        row['updatedAt'] ?? row['generatedAt'] ?? row['createdAt'],
      );
      if (value != null) dates.add(value);
    }
  }
  dates.sort();

  TrustMetric ratioMetric(
    String label,
    int numerator,
    int denominator,
    String explanation,
  ) => TrustMetric(
    label: label,
    value: denominator == 0
        ? 'Unavailable'
        : '${(numerator / denominator * 100).toStringAsFixed(1)}%',
    sampleSize: denominator,
    explanation: explanation,
    available: denominator > 0,
    numerator: numerator,
  );

  return TrustImpactReport(
    metrics: <TrustMetric>[
      TrustMetric(
        label: 'Forecast error',
        value: evaluated == 0
            ? 'Unavailable'
            : 'MAE ${weighted('meanAbsoluteError', 'mae').toStringAsFixed(2)} · MAPE ${mape == null ? 'not available' : '${mape.toStringAsFixed(1)}%'}',
        sampleSize: evaluated,
        explanation: 'Forecasts compared with subsequently ordered quantity.',
        available: evaluated > 0,
      ),
      ratioMetric(
        'Retailers with recommendations',
        recommendedKnownRetailers,
        retailerIds.length,
        'Retailers with at least one usable replenishment suggestion.',
      ),
      ratioMetric(
        'Suggested products ordered',
        orderedPairs.length,
        comparableSuggestions.length,
        'Suggestion pairs matched only to orders at or after brief generation.',
      ),
      ratioMetric(
        'Priority stops completed',
        completedPriorityStops.length,
        priorityStops.length,
        'Planned stops carrying a priority reason that were completed.',
      ),
      ratioMetric(
        'Insight resolution',
        resolved,
        insights.length,
        medianHours == null
            ? 'No trustworthy resolution duration is available.'
            : 'Median resolution time ${medianHours.toStringAsFixed(1)} hours.',
      ),
    ],
    abstentionReasons: <String, int>{
      'Sparse history / no usable recommendation':
          (retailerIds.length - recommendedKnownRetailers)
              .clamp(0, retailerIds.length)
              .toInt(),
      'Missing product identity': missingProductIdentity,
      'Missing recommendation timestamp':
          suggestions.length - comparableSuggestions.length,
      'Stopped product evidence': stoppedProducts,
      'Unverified or missing coordinates': unverifiedCoordinates,
    },
    latestEvidenceAt: dates.isEmpty ? null : dates.last,
  );
}

class _Suggestion {
  const _Suggestion({
    required this.retailerId,
    required this.productId,
    required this.generatedAt,
  });
  final String retailerId;
  final String productId;
  final DateTime? generatedAt;
}

String _retailerId(Map<String, dynamic> row) =>
    _text(row['retailerId'] ?? row['retailer_id'] ?? row['docId']);

Map<String, dynamic> _forecastAccuracy(Map<String, dynamic> row) {
  final Object? raw = row['forecastAccuracy'];
  return raw is Map ? Map<String, dynamic>.from(raw) : row;
}

String _text(Object? value) => value?.toString().trim() ?? '';
double _number(Object? value) => value is num
    ? value.toDouble()
    : double.tryParse(_text(value).replaceAll(',', '')) ?? 0;
int _integer(Object? value) => _number(value).toInt();

DateTime? _date(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  try {
    final dynamic candidate = value;
    final Object? result = candidate.toDate();
    if (result is DateTime) return result;
  } catch (_) {}
  return DateTime.tryParse(_text(value));
}
