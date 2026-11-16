library;

import 'route_execution.dart';

const int minDecidedVisitsForScore = 3;

const double highSkipRateFloor = 0.3;
const int skipRateMinDecided = 5;

const double lowAdherenceCeiling = 0.6;

const double lowConversionCeiling = 0.3;
const int conversionMinCompleted = 5;

const int noOutcomesMinDecided = 5;

const double lowOutcomeQualityCeiling = 50.0;
const int outcomeQualityMinCount = 3;

const double onTrackCompletionFloor = 0.7;

const double trendImproveRatio = 1.2;
const double trendDeclineRatio = 0.8;

class ScorecardSalesman {
  const ScorecardSalesman({
    required this.uid,
    required this.code,
    required this.name,
  });

  final String uid;
  final String code;
  final String name;
}

class ScorecardOrderEvent {
  const ScorecardOrderEvent({
    this.salesmanUid = '',
    this.salesmanCode = '',
    this.at,
  });

  final String salesmanUid;
  final String salesmanCode;
  final DateTime? at;
}

class ScorecardOutcomeEvent {
  const ScorecardOutcomeEvent({
    this.salesmanUid = '',
    this.salesmanCode = '',
    this.at,
    this.qualityScore = 0,
    this.hasIssueRef = false,
  });

  final String salesmanUid;
  final String salesmanCode;
  final DateTime? at;
  final int qualityScore;
  final bool hasIssueRef;
}

class ScorecardInsightEvent {
  const ScorecardInsightEvent({
    this.salesmanUid = '',
    this.salesmanCode = '',
    this.isResolved = false,
  });

  final String salesmanUid;
  final String salesmanCode;
  final bool isResolved;
}

class CoachingPrompt {
  const CoachingPrompt({required this.code, required this.message});

  final String code;
  final String message;
}

enum ScorecardTrend { improving, steady, declining, insufficient }

class SalesmanScorecard {
  const SalesmanScorecard({
    required this.salesmanUid,
    required this.salesmanCode,
    required this.salesmanName,
    required this.decidedStops,
    required this.completedStops,
    required this.skippedStops,
    required this.completionRate,
    required this.skipRate,
    required this.meanAdherence,
    required this.adherencePlanCount,
    required this.meanServiceMinutes,
    required this.serviceSampleCount,
    required this.ordersInWindow,
    required this.ordersPerCompletedVisit,
    required this.outcomesRecorded,
    required this.outcomesLinkedToIssue,
    required this.meanOutcomeQuality,
    required this.resolvedInsightCount,
    required this.weeklyCompleted,
    required this.trend,
    required this.hasSufficientData,
    required this.coachingPrompts,
  });

  final String salesmanUid;
  final String salesmanCode;
  final String salesmanName;

  final int decidedStops;
  final int completedStops;
  final int skippedStops;

  final double? completionRate;
  final double? skipRate;

  final double? meanAdherence;

  final int adherencePlanCount;

  final double? meanServiceMinutes;
  final int serviceSampleCount;

  final int ordersInWindow;

  final double? ordersPerCompletedVisit;

  final int outcomesRecorded;
  final int outcomesLinkedToIssue;

  final double? meanOutcomeQuality;

  final int resolvedInsightCount;

  final List<int> weeklyCompleted;

  final ScorecardTrend trend;

  final bool hasSufficientData;

  final List<CoachingPrompt> coachingPrompts;
}

List<SalesmanScorecard> deriveSalesmanScorecards({
  required List<ScorecardSalesman> salesmen,
  required List<Map<String, dynamic>> progressDocs,
  required Map<String, List<Map<String, dynamic>>> stopArrivalDocsByPlanId,
  required Map<String, List<String>> plannedStopIdsByPlanId,
  required List<ScorecardOrderEvent> orders,
  required List<ScorecardOutcomeEvent> outcomes,
  required List<ScorecardInsightEvent> insights,
  required DateTime now,
  int windowDays = 56,
}) {
  final DateTime windowStart = now.subtract(Duration(days: windowDays));
  final int weekCount = (windowDays / 7).ceil().clamp(1, 52).toInt();

  bool inWindow(DateTime? at) =>
      at != null && !at.isBefore(windowStart) && !at.isAfter(now);

  final List<SalesmanScorecard> result = <SalesmanScorecard>[];
  for (final ScorecardSalesman salesman in salesmen) {
    final String uid = salesman.uid.trim();
    final String code = salesman.code.trim().toLowerCase();
    if (uid.isEmpty && code.isEmpty) continue;

    bool matches(String eventUid, String eventCode) {
      final String u = eventUid.trim();
      final String c = eventCode.trim().toLowerCase();
      return (uid.isNotEmpty && u == uid) || (code.isNotEmpty && c == code);
    }

    final List<StopExecutionEvent> events = <StopExecutionEvent>[];
    final List<double> adherenceScores = <double>[];
    for (final Map<String, dynamic> doc in progressDocs) {
      if (!matches(
        (doc['salesmanUid'] ?? '').toString(),
        (doc['salesmanCode'] ?? '').toString(),
      )) {
        continue;
      }
      final String planId = (doc['planId'] ?? '').toString().trim();
      final List<StopExecutionEvent> docEvents = mapProgressDocToEvents(
        doc,
        stopDocuments:
            stopArrivalDocsByPlanId[planId] ?? const <Map<String, dynamic>>[],
      );
      events.addAll(docEvents);
      final List<String>? planned = plannedStopIdsByPlanId[planId];
      if (planned != null && planned.isNotEmpty) {
        final AdherenceResult adherence = deriveAdherence(planned, docEvents);
        if (adherence.hasScore) adherenceScores.add(adherence.score!);
      }
    }

    int completed = 0;
    int skipped = 0;
    final List<int> weeklyCompleted = List<int>.filled(weekCount, 0);
    final List<int> weeklyDecided = List<int>.filled(weekCount, 0);
    for (final StopExecutionEvent event in events) {
      final String status = event.normalizedStatus;
      final bool isCompleted = status == 'completed';
      final bool isSkipped = status == 'skipped';
      if (!isCompleted && !isSkipped) continue;
      if (isCompleted) completed++;
      if (isSkipped) skipped++;
      final DateTime? at = isCompleted ? event.completedAt : event.skippedAt;
      if (!inWindow(at)) continue;
      final int weeksAgo = now.difference(at!).inDays ~/ 7;
      final int slot = weekCount - 1 - weeksAgo;
      if (slot < 0 || slot >= weekCount) continue;
      weeklyDecided[slot]++;
      if (isCompleted) weeklyCompleted[slot]++;
    }
    final int decided = completed + skipped;

    double serviceSum = 0.0;
    int serviceSamples = 0;
    for (final ServiceTimeStat stat in deriveServiceTimes(events).values) {
      if (!stat.hasEstimate) continue;
      serviceSum += stat.meanServiceMinutes! * stat.sampleCount;
      serviceSamples += stat.sampleCount;
    }

    int ordersInWindow = 0;
    for (final ScorecardOrderEvent order in orders) {
      if (matches(order.salesmanUid, order.salesmanCode) &&
          inWindow(order.at)) {
        ordersInWindow++;
      }
    }

    int outcomesRecorded = 0;
    int outcomesLinked = 0;
    int qualitySum = 0;
    for (final ScorecardOutcomeEvent outcome in outcomes) {
      if (!matches(outcome.salesmanUid, outcome.salesmanCode)) continue;
      if (!inWindow(outcome.at)) continue;
      outcomesRecorded++;
      if (outcome.hasIssueRef) outcomesLinked++;
      qualitySum += outcome.qualityScore;
    }

    int resolvedInsights = 0;
    for (final ScorecardInsightEvent insight in insights) {
      if (insight.isResolved &&
          matches(insight.salesmanUid, insight.salesmanCode)) {
        resolvedInsights++;
      }
    }

    final bool sufficient = decided >= minDecidedVisitsForScore;
    final double? completionRate = sufficient ? completed / decided : null;
    final double? skipRate = sufficient ? skipped / decided : null;
    final double? meanAdherence = adherenceScores.isEmpty
        ? null
        : adherenceScores.reduce((double a, double b) => a + b) /
              adherenceScores.length;
    final double? meanService = serviceSamples == 0
        ? null
        : serviceSum / serviceSamples;
    final double? conversion = (sufficient && completed > 0)
        ? ordersInWindow / completed
        : null;
    final double? meanQuality = outcomesRecorded == 0
        ? null
        : qualitySum / outcomesRecorded;

    result.add(
      SalesmanScorecard(
        salesmanUid: salesman.uid.trim(),
        salesmanCode: salesman.code.trim(),
        salesmanName: salesman.name.trim(),
        decidedStops: decided,
        completedStops: completed,
        skippedStops: skipped,
        completionRate: completionRate,
        skipRate: skipRate,
        meanAdherence: sufficient ? meanAdherence : null,
        adherencePlanCount: adherenceScores.length,
        meanServiceMinutes: meanService,
        serviceSampleCount: serviceSamples,
        ordersInWindow: ordersInWindow,
        ordersPerCompletedVisit: conversion,
        outcomesRecorded: outcomesRecorded,
        outcomesLinkedToIssue: outcomesLinked,
        meanOutcomeQuality: meanQuality,
        resolvedInsightCount: resolvedInsights,
        weeklyCompleted: List<int>.unmodifiable(weeklyCompleted),
        trend: sufficient
            ? _deriveTrend(weeklyCompleted, weeklyDecided)
            : ScorecardTrend.insufficient,
        hasSufficientData: sufficient,
        coachingPrompts: sufficient
            ? _derivePrompts(
                decided: decided,
                completed: completed,
                completionRate: completionRate!,
                skipRate: skipRate!,
                meanAdherence: meanAdherence,
                conversion: conversion,
                ordersInWindow: ordersInWindow,
                outcomesRecorded: outcomesRecorded,
                meanOutcomeQuality: meanQuality,
              )
            : const <CoachingPrompt>[],
      ),
    );
  }

  result.sort((SalesmanScorecard a, SalesmanScorecard b) {
    final int byName = a.salesmanName.toLowerCase().compareTo(
      b.salesmanName.toLowerCase(),
    );
    return byName != 0 ? byName : a.salesmanUid.compareTo(b.salesmanUid);
  });
  return result;
}

ScorecardTrend _deriveTrend(
  List<int> weeklyCompleted,
  List<int> weeklyDecided,
) {
  final List<int> activeSlots = <int>[
    for (int i = 0; i < weeklyDecided.length; i++)
      if (weeklyDecided[i] > 0) i,
  ];
  if (activeSlots.length < 2) return ScorecardTrend.insufficient;
  final int latest = activeSlots.last;
  double earlierSum = 0;
  for (final int slot in activeSlots) {
    if (slot != latest) earlierSum += weeklyCompleted[slot];
  }
  final double earlierMean = earlierSum / (activeSlots.length - 1);
  final double latestCompleted = weeklyCompleted[latest].toDouble();
  if (earlierMean == 0) {
    return latestCompleted > 0
        ? ScorecardTrend.improving
        : ScorecardTrend.steady;
  }
  final double ratio = latestCompleted / earlierMean;
  if (ratio >= trendImproveRatio) return ScorecardTrend.improving;
  if (ratio <= trendDeclineRatio) return ScorecardTrend.declining;
  return ScorecardTrend.steady;
}

String _percent(double value) => '${(value * 100).round()}%';

List<CoachingPrompt> _derivePrompts({
  required int decided,
  required int completed,
  required double completionRate,
  required double skipRate,
  required double? meanAdherence,
  required double? conversion,
  required int ordersInWindow,
  required int outcomesRecorded,
  required double? meanOutcomeQuality,
}) {
  final List<CoachingPrompt> prompts = <CoachingPrompt>[];
  if (decided >= skipRateMinDecided && skipRate >= highSkipRateFloor) {
    prompts.add(
      CoachingPrompt(
        code: 'high_skip_rate',
        message:
            '${_percent(skipRate)} of $decided decided visits were skipped — '
            'review the recorded skip reasons together.',
      ),
    );
  }
  if (meanAdherence != null && meanAdherence < lowAdherenceCeiling) {
    prompts.add(
      CoachingPrompt(
        code: 'low_adherence',
        message:
            'Executed visit order matches the plan ${_percent(meanAdherence)} '
            'of the time — walk through the planned sequence before the day '
            'starts.',
      ),
    );
  }
  if (completed >= conversionMinCompleted &&
      conversion != null &&
      conversion < lowConversionCeiling) {
    prompts.add(
      CoachingPrompt(
        code: 'low_conversion',
        message:
            '$ordersInWindow order(s) across $completed completed visits — '
            'review which retailers should be carrying an order at visit end.',
      ),
    );
  }
  if (decided >= noOutcomesMinDecided && outcomesRecorded == 0) {
    prompts.add(
      const CoachingPrompt(
        code: 'no_outcomes',
        message:
            'No conversation outcomes recorded this period — outcomes are how '
            'insight follow-ups get closed.',
      ),
    );
  }
  if (outcomesRecorded >= outcomeQualityMinCount &&
      meanOutcomeQuality != null &&
      meanOutcomeQuality < lowOutcomeQualityCeiling) {
    prompts.add(
      CoachingPrompt(
        code: 'low_outcome_quality',
        message:
            'Recorded outcomes average ${meanOutcomeQuality.round()}/100 '
            'quality — add a reason and a short note when closing.',
      ),
    );
  }
  if (prompts.isEmpty && completionRate >= onTrackCompletionFloor) {
    prompts.add(
      CoachingPrompt(
        code: 'on_track',
        message:
            '${_percent(completionRate)} completion with no coaching flags — '
            'on track this period.',
      ),
    );
  }
  return prompts;
}
