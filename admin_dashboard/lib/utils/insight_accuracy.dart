library;

import '../models/ai_insight.dart';

class InsightAccuracy {
  const InsightAccuracy({
    required this.raisedCount,
    required this.fieldCheckedCount,
    required this.loopClosedCount,
    required this.followUpPendingCount,
    required this.uncheckedCount,
    required this.humanClosedCount,
    required this.demoCount,
  });

  final int raisedCount;

  final int fieldCheckedCount;

  final int loopClosedCount;

  final int followUpPendingCount;

  final int uncheckedCount;

  final int humanClosedCount;
  final int demoCount;

  bool get isEmpty => raisedCount == 0;

  double get checkRate =>
      raisedCount == 0 ? 0 : fieldCheckedCount / raisedCount;

  double get closeRate => raisedCount == 0 ? 0 : loopClosedCount / raisedCount;

  static const InsightAccuracy empty = InsightAccuracy(
    raisedCount: 0,
    fieldCheckedCount: 0,
    loopClosedCount: 0,
    followUpPendingCount: 0,
    uncheckedCount: 0,
    humanClosedCount: 0,
    demoCount: 0,
  );
}

InsightAccuracy deriveInsightAccuracy(Iterable<AiInsight> insights) {
  int raised = 0;
  int checked = 0;
  int loopClosed = 0;
  int followUp = 0;
  int unchecked = 0;
  int humanClosed = 0;
  int demo = 0;
  for (final AiInsight insight in insights) {
    raised++;
    if (insight.isDemo) demo++;
    if (insight.outcomeCount > 0) {
      checked++;
    } else {
      unchecked++;
    }
    if (insight.autoState == 'suppressed') loopClosed++;
    if (insight.needsFollowUp) followUp++;
    if (insight.status == 'resolved' || insight.status == 'dismissed') {
      humanClosed++;
    }
  }
  if (raised == 0) return InsightAccuracy.empty;
  return InsightAccuracy(
    raisedCount: raised,
    fieldCheckedCount: checked,
    loopClosedCount: loopClosed,
    followUpPendingCount: followUp,
    uncheckedCount: unchecked,
    humanClosedCount: humanClosed,
    demoCount: demo,
  );
}
