import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/ai_data_freshness.dart';

class WeeklyAiSummary {
  const WeeklyAiSummary({
    required this.id,
    required this.weekStart,
    this.generatedAt,
    this.updatedAt,
    this.freshnessAt,
    required this.scopeType,
    required this.scopeKey,
    required this.insightCount,
    required this.unresolvedCount,
    required this.resolvedCount,
    required this.ignoredCount,
    required this.highPriorityCount,
    required this.valueAtRiskRm,
    required this.evaluatedForecastCount,
    required this.meanAbsoluteError,
    required this.meanAbsolutePercentageError,
    this.percentageErrorCount,
  });

  final String id;
  final DateTime? weekStart;
  final DateTime? generatedAt;
  final DateTime? updatedAt;
  final DateTime? freshnessAt;
  final String scopeType;
  final String scopeKey;
  final int insightCount;
  final int unresolvedCount;
  final int resolvedCount;
  final int ignoredCount;
  final int highPriorityCount;
  final double valueAtRiskRm;
  final int evaluatedForecastCount;
  final double meanAbsoluteError;

  final double? meanAbsolutePercentageError;

  final int? percentageErrorCount;

  int get mapeWeight => meanAbsolutePercentageError == null
      ? 0
      : (percentageErrorCount ?? evaluatedForecastCount);

  factory WeeklyAiSummary.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    return WeeklyAiSummary.fromMap(snapshot.id, snapshot.data());
  }

  factory WeeklyAiSummary.fromMap(String id, Map<String, dynamic> data) {
    final Map<String, dynamic> accuracy = data['forecastAccuracy'] is Map
        ? Map<String, dynamic>.from(data['forecastAccuracy'] as Map)
        : const <String, dynamic>{};
    return WeeklyAiSummary(
      id: id,
      weekStart: _date(data['weekStart']),
      generatedAt: _date(data['generatedAt']),
      updatedAt: _date(data['updatedAt']),
      freshnessAt: aiDataTimestamp(data),
      scopeType: _text(data['scopeType'], fallback: 'organization'),
      scopeKey: _text(data['scopeKey'], fallback: 'all'),
      insightCount: _integer(data['insightCount']),
      unresolvedCount: _integer(data['unresolvedCount']),
      resolvedCount: _integer(data['resolvedCount']),
      ignoredCount: _integer(data['ignoredCount']),
      highPriorityCount: _integer(data['highPriorityCount']),
      valueAtRiskRm: _number(data['valueAtRiskRm']),
      evaluatedForecastCount: _integer(accuracy['evaluatedForecastCount']),
      meanAbsoluteError: _number(accuracy['meanAbsoluteError']),
      meanAbsolutePercentageError:
          accuracy['meanAbsolutePercentageError'] is num
          ? _number(accuracy['meanAbsolutePercentageError'])
          : null,
      percentageErrorCount: accuracy['percentageErrorCount'] is num
          ? _integer(accuracy['percentageErrorCount'])
          : null,
    );
  }
}

class WeeklyAiRollup {
  const WeeklyAiRollup({
    required this.weekStart,
    required this.insightCount,
    required this.unresolvedCount,
    required this.resolvedCount,
    required this.ignoredCount,
    required this.highPriorityCount,
    required this.valueAtRiskRm,
    required this.evaluatedForecastCount,
    required this.meanAbsoluteError,
    required this.meanAbsolutePercentageError,
    this.percentageErrorCount = 0,
  });

  final DateTime? weekStart;
  final int insightCount;
  final int unresolvedCount;
  final int resolvedCount;
  final int ignoredCount;
  final int highPriorityCount;
  final double valueAtRiskRm;
  final int evaluatedForecastCount;
  final double meanAbsoluteError;

  final double? meanAbsolutePercentageError;
  final int percentageErrorCount;

  factory WeeklyAiRollup.fromSummaries(List<WeeklyAiSummary> summaries) {
    if (summaries.isEmpty) {
      return const WeeklyAiRollup(
        weekStart: null,
        insightCount: 0,
        unresolvedCount: 0,
        resolvedCount: 0,
        ignoredCount: 0,
        highPriorityCount: 0,
        valueAtRiskRm: 0,
        evaluatedForecastCount: 0,
        meanAbsoluteError: 0,
        meanAbsolutePercentageError: null,
      );
    }
    final int evaluated = summaries.fold<int>(
      0,
      (int total, WeeklyAiSummary row) => total + row.evaluatedForecastCount,
    );
    double weightedMae = 0;
    double weightedMape = 0;
    int mapeWeight = 0;
    for (final WeeklyAiSummary row in summaries) {
      weightedMae += row.meanAbsoluteError * row.evaluatedForecastCount;
      weightedMape += (row.meanAbsolutePercentageError ?? 0) * row.mapeWeight;
      mapeWeight += row.mapeWeight;
    }
    return WeeklyAiRollup(
      weekStart: summaries.first.weekStart,
      insightCount: summaries.fold<int>(
        0,
        (int total, WeeklyAiSummary row) => total + row.insightCount,
      ),
      unresolvedCount: summaries.fold<int>(
        0,
        (int total, WeeklyAiSummary row) => total + row.unresolvedCount,
      ),
      resolvedCount: summaries.fold<int>(
        0,
        (int total, WeeklyAiSummary row) => total + row.resolvedCount,
      ),
      ignoredCount: summaries.fold<int>(
        0,
        (int total, WeeklyAiSummary row) => total + row.ignoredCount,
      ),
      highPriorityCount: summaries.fold<int>(
        0,
        (int total, WeeklyAiSummary row) => total + row.highPriorityCount,
      ),
      valueAtRiskRm: summaries.fold<double>(
        0,
        (double total, WeeklyAiSummary row) => total + row.valueAtRiskRm,
      ),
      evaluatedForecastCount: evaluated,
      meanAbsoluteError: evaluated == 0 ? 0 : weightedMae / evaluated,
      meanAbsolutePercentageError: mapeWeight == 0
          ? null
          : weightedMape / mapeWeight,
      percentageErrorCount: mapeWeight,
    );
  }
}

String _text(Object? value, {String fallback = ''}) {
  final String text = (value ?? '').toString().trim();
  return text.isEmpty ? fallback : text;
}

int _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(_text(value)) ?? 0;
}

double _number(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(_text(value)) ?? 0;
}

DateTime? _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return DateTime.tryParse(_text(value));
}
