library;

import 'money_format.dart';

enum LifecycleEventKind {
  raised,
  evidenceWindow,
  outcomeRecorded,
  followUpFlagged,
  suppressed,
  humanClosed,
}

class LifecycleOutcome {
  const LifecycleOutcome({
    required this.reasonCode,
    this.salesmanCode = '',
    this.qualityScore = 0,
    this.at,
    this.isDemo = false,
  });

  final String reasonCode;
  final String salesmanCode;
  final int qualityScore;
  final DateTime? at;
  final bool isDemo;
}

class InsightLifecycleEvent {
  const InsightLifecycleEvent({
    required this.kind,
    required this.title,
    this.detail = '',
    this.at,
  });

  final LifecycleEventKind kind;
  final String title;
  final String detail;

  final DateTime? at;
}

List<InsightLifecycleEvent> buildInsightLifecycle({
  DateTime? raisedAt,
  DateTime? lastObservedWeekStart,
  required String status,
  required String autoState,
  DateTime? autoSuppressedAt,
  String autoSuppressionReason = '',
  required double valueAtRiskRm,
  required List<LifecycleOutcome> outcomes,
}) {
  final String safeStatus = status.trim().toLowerCase();
  final String safeAutoState = autoState.trim().toLowerCase();
  final List<InsightLifecycleEvent> events = <InsightLifecycleEvent>[];

  events.add(
    InsightLifecycleEvent(
      kind: LifecycleEventKind.raised,
      title: 'Insight raised',
      detail: valueAtRiskRm > 0
          ? '${formatRm(valueAtRiskRm)} flagged at risk'
          : '',
      at: raisedAt,
    ),
  );

  if (lastObservedWeekStart != null) {
    events.add(
      InsightLifecycleEvent(
        kind: LifecycleEventKind.evidenceWindow,
        title: 'Latest sales evidence',
        detail: 'Computed from the sales week starting here',
        at: lastObservedWeekStart,
      ),
    );
  }

  final List<LifecycleOutcome> ordered = List<LifecycleOutcome>.from(outcomes)
    ..sort((LifecycleOutcome left, LifecycleOutcome right) {
      final DateTime leftAt = left.at ?? DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime rightAt =
          right.at ?? DateTime.fromMillisecondsSinceEpoch(0);
      return leftAt.compareTo(rightAt);
    });
  for (final LifecycleOutcome outcome in ordered) {
    final String reason = outcome.reasonCode.trim().toLowerCase();
    events.add(
      InsightLifecycleEvent(
        kind: LifecycleEventKind.outcomeRecorded,
        title: 'Outcome recorded: ${lifecycleReasonLabel(reason)}',
        detail: <String>[
          if (outcome.salesmanCode.trim().isNotEmpty)
            'by ${outcome.salesmanCode.trim()}',
          if (outcome.qualityScore > 0) 'quality ${outcome.qualityScore}',
          if (outcome.isDemo) 'demo data',
        ].join(' • '),
        at: outcome.at,
      ),
    );
  }

  final LifecycleOutcome? latest = ordered.isEmpty ? null : ordered.last;
  if (safeAutoState == 'suppressed') {
    final String reason = autoSuppressionReason.trim().isNotEmpty
        ? autoSuppressionReason
        : (latest?.reasonCode ?? '');
    events.add(
      InsightLifecycleEvent(
        kind: LifecycleEventKind.suppressed,
        title: 'Issue resolved by the loop',
        detail: <String>[
          if (reason.trim().isNotEmpty)
            'Outcome "${lifecycleReasonLabel(reason)}" closed the issue',
          if (valueAtRiskRm > 0)
            '${formatRm(valueAtRiskRm)} no longer counted at risk',
        ].join(' • '),
        at: autoSuppressedAt ?? latest?.at,
      ),
    );
  } else if (safeAutoState == 'follow_up') {
    events.add(
      InsightLifecycleEvent(
        kind: LifecycleEventKind.followUpFlagged,
        title: 'Follow-up flagged',
        detail: latest == null
            ? 'Waiting on a revisit'
            : 'Latest outcome "${lifecycleReasonLabel(latest.reasonCode)}" needs a revisit',
        at: latest?.at,
      ),
    );
  }

  if (safeStatus == 'resolved' || safeStatus == 'dismissed') {
    events.add(
      InsightLifecycleEvent(
        kind: LifecycleEventKind.humanClosed,
        title: 'Marked $safeStatus by the team',
      ),
    );
  }

  return List<InsightLifecycleEvent>.unmodifiable(events);
}

String lifecycleReasonLabel(String reasonCode) {
  return reasonCode
      .trim()
      .toLowerCase()
      .split('_')
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) =>
            '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}
