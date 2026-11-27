import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../models/ai_insight.dart';
import '../../../models/ai_run_record.dart';
import '../../../models/user_profile.dart';
import '../../../models/weekly_ai_summary.dart';
import '../../../services/ai_insight_service.dart';
import '../../../services/weekly_ai_report_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/insight_accuracy.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../widgets/cms_panel.dart';
import '../../../utils/money_format.dart';
import '../../../widgets/slow_loading.dart';

class WeeklyAiSummaryPanel extends StatefulWidget {
  const WeeklyAiSummaryPanel({
    super.key,
    required this.currentUser,
    this.embedded = false,
  });

  final UserProfile currentUser;
  final bool embedded;

  @override
  State<WeeklyAiSummaryPanel> createState() => _WeeklyAiSummaryPanelState();
}

class _WeeklyAiSummaryPanelState extends State<WeeklyAiSummaryPanel> {
  final WeeklyAiReportService _service = WeeklyAiReportService();
  final AiInsightService _insightService = AiInsightService();
  late Stream<List<WeeklyAiSummary>> _summaries;
  late Stream<List<AiRunRecord>> _runs;
  late Stream<List<AiInsight>> _insights;

  @override
  void initState() {
    super.initState();
    _resetStreams();
  }

  @override
  void didUpdateWidget(WeeklyAiSummaryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.uid != widget.currentUser.uid ||
        oldWidget.currentUser.role != widget.currentUser.role ||
        oldWidget.currentUser.branchId != widget.currentUser.branchId ||
        oldWidget.currentUser.assignedSalesmanCodes.join('|') !=
            widget.currentUser.assignedSalesmanCodes.join('|')) {
      _resetStreams();
    }
  }

  void _resetStreams() {
    _summaries = _service.watchSummaries(widget.currentUser);
    _runs = _service.watchRuns(widget.currentUser);
    _insights = _insightService.watchInsights(widget.currentUser);
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = StreamBuilder<List<WeeklyAiSummary>>(
      stream: _summaries,
      builder: (BuildContext context, AsyncSnapshot<List<WeeklyAiSummary>> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const SlowLoading();
        }
        if (snapshot.hasError) {
          return _Message(
            title: 'Weekly summaries could not be loaded',
            subtitle: _summaryReadError(snapshot.error),
          );
        }
        final List<WeeklyAiSummary> rows =
            snapshot.data ?? const <WeeklyAiSummary>[];
        if (rows.isEmpty) {
          return Column(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.all(12),
                child: AiFreshnessChip(
                  hasData: false,
                  timestamps: <DateTime?>[],
                ),
              ),
              _Message(
                title: 'No weekly summary yet',
                subtitle: widget.currentUser.isSupervisor
                    ? 'No generated weekly summary is available for your assigned salespeople yet.'
                    : widget.currentUser.isBranchManager
                    ? 'No generated weekly summary is available for your branch yet.'
                    : 'No weekly summary has been generated yet.',
              ),
            ],
          );
        }
        final DateTime? latestWeek = rows.first.weekStart;
        final List<WeeklyAiSummary> latest = rows
            .where((WeeklyAiSummary row) => _sameDay(row.weekStart, latestWeek))
            .toList(growable: false);
        final WeeklyAiRollup rollup = WeeklyAiRollup.fromSummaries(latest);
        return ListView(
          padding: const EdgeInsets.all(14),
          children: <Widget>[
            AiFreshnessChip(
              hasData: latest.isNotEmpty,
              timestamps: latest.map((WeeklyAiSummary row) => row.freshnessAt),
              hasMissingTimestamp: latest.any(
                (WeeklyAiSummary row) => row.freshnessAt == null,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Week of ${_formatDate(rollup.weekStart)}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: context.dso.ink,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: <Widget>[
                _Metric(
                  label: 'Unresolved insights',
                  value: '${rollup.unresolvedCount}',
                  danger: rollup.unresolvedCount > 0,
                ),
                _Metric(
                  label: 'High priority',
                  value: '${rollup.highPriorityCount}',
                  danger: rollup.highPriorityCount > 0,
                ),
                _Metric(
                  label: 'Value at risk',
                  value: formatRm(rollup.valueAtRiskRm),
                ),
                _Metric(
                  label: 'Resolved / ignored',
                  value: '${rollup.resolvedCount} / ${rollup.ignoredCount}',
                ),
                _Metric(
                  label: 'Forecast MAE',
                  value: rollup.evaluatedForecastCount == 0
                      ? 'Not evaluated'
                      : rollup.meanAbsoluteError.toStringAsFixed(2),
                ),
                _Metric(
                  label: 'Forecast MAPE',
                  value: rollup.meanAbsolutePercentageError == null
                      ? 'Not available'
                      : '${rollup.meanAbsolutePercentageError!.toStringAsFixed(1)}%',
                  danger: (rollup.meanAbsolutePercentageError ?? 0) > 35,
                ),
              ],
            ),
            const SizedBox(height: 14),
            StreamBuilder<List<AiInsight>>(
              stream: _insights,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<AiInsight>> insightSnapshot,
                  ) {
                    final List<AiInsight> insights =
                        insightSnapshot.data ?? const <AiInsight>[];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        AiFreshnessChip(
                          hasData: insights.isNotEmpty,
                          timestamps: insights.map(
                            (AiInsight insight) => insight.freshnessAt,
                          ),
                          hasMissingTimestamp: insights.any(
                            (AiInsight insight) => insight.freshnessAt == null,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _InsightAccuracySection(
                          accuracy: deriveInsightAccuracy(insights),
                          hasError: insightSnapshot.hasError,
                          loading:
                              insightSnapshot.connectionState ==
                                  ConnectionState.waiting &&
                              !insightSnapshot.hasData,
                        ),
                      ],
                    );
                  },
            ),
            const SizedBox(height: 14),
            _History(rows: rows),
            if (widget.currentUser.isAdmin) ...<Widget>[
              const SizedBox(height: 14),
              StreamBuilder<List<AiRunRecord>>(
                stream: _runs,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<AiRunRecord>> runSnapshot,
                    ) {
                      return _RunHistory(
                        rows: runSnapshot.data ?? const <AiRunRecord>[],
                        hasError: runSnapshot.hasError,
                      );
                    },
              ),
            ],
          ],
        );
      },
    );
    if (widget.embedded) return content;
    return CmsPanel(title: 'Weekly Summary & Accuracy', child: content);
  }
}

String _summaryReadError(Object? error) {
  if (error is FirebaseException) {
    switch (error.code) {
      case 'permission-denied':
        return 'Your account is not allowed to view these summaries. Ask an administrator if you need access.';
      case 'failed-precondition':
        return 'Weekly summaries are not ready yet. Try again in a few minutes.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'The summaries could not be loaded because the connection was interrupted. Try again.';
    }
  }
  return 'Weekly summaries could not be loaded. Check your connection and try again.';
}

class _InsightAccuracySection extends StatelessWidget {
  const _InsightAccuracySection({
    required this.accuracy,
    required this.hasError,
    required this.loading,
  });

  final InsightAccuracy accuracy;
  final bool hasError;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (hasError) {
      child = const Text('Insight accuracy could not be loaded.');
    } else if (loading) {
      child = const Text('Loading insights…');
    } else if (accuracy.isEmpty) {
      child = const Text('No insights currently visible for your scope.');
    } else {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: <Widget>[
              _Metric(
                label: 'Insights raised',
                value: '${accuracy.raisedCount}',
              ),
              _Metric(
                label: 'Field-checked',
                value:
                    '${accuracy.fieldCheckedCount} (${(accuracy.checkRate * 100).round()}%)',
              ),
              _Metric(
                label: 'Closed by outcomes',
                value:
                    '${accuracy.loopClosedCount} (${(accuracy.closeRate * 100).round()}%)',
              ),
              _Metric(
                label: 'Follow-up pending',
                value: '${accuracy.followUpPendingCount}',
                danger: accuracy.followUpPendingCount > 0,
              ),
              _Metric(
                label: 'Not yet checked',
                value: '${accuracy.uncheckedCount}',
                danger: accuracy.uncheckedCount > 0,
              ),
              _Metric(
                label: 'Closed by team',
                value: '${accuracy.humanClosedCount}',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Based on the ${accuracy.raisedCount} insight(s) currently visible. '
            'Field checks are the only ground truth the system records.',
            style: TextStyle(fontSize: 11, color: context.dso.muted),
          ),
        ],
      );
    }
    return _Section(title: 'Insight accuracy', child: child);
  }
}

class _History extends StatelessWidget {
  const _History({required this.rows});

  final List<WeeklyAiSummary> rows;

  @override
  Widget build(BuildContext context) {
    final Map<String, List<WeeklyAiSummary>> grouped =
        <String, List<WeeklyAiSummary>>{};
    for (final WeeklyAiSummary row in rows) {
      grouped
          .putIfAbsent(_dayKey(row.weekStart), () => <WeeklyAiSummary>[])
          .add(row);
    }
    final List<WeeklyAiRollup> history = grouped.values
        .map(WeeklyAiRollup.fromSummaries)
        .take(12)
        .toList(growable: false);
    return _Section(
      title: 'Weekly history',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _MapeTrend(history: history),
          ...history.map(
            (WeeklyAiRollup row) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                _formatDate(row.weekStart),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${row.unresolvedCount} unresolved · '
                '${row.resolvedCount} resolved · '
                '${row.evaluatedForecastCount} forecasts evaluated · '
                '${row.meanAbsolutePercentageError == null ? 'MAPE not available' : 'MAPE ${row.meanAbsolutePercentageError!.toStringAsFixed(1)}%'}',
              ),
              trailing: Text(
                formatRm(row.valueAtRiskRm),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapeTrend extends StatelessWidget {
  const _MapeTrend({required this.history});

  final List<WeeklyAiRollup> history;

  @override
  Widget build(BuildContext context) {
    final List<WeeklyAiRollup> evaluated = history
        .where((WeeklyAiRollup row) => row.meanAbsolutePercentageError != null)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    if (evaluated.length < 2) return const SizedBox.shrink();
    final double maxMape = evaluated
        .map((WeeklyAiRollup row) => row.meanAbsolutePercentageError!)
        .reduce((double left, double right) => left > right ? left : right);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Forecast error trend (MAPE, oldest → newest)',
            style: TextStyle(fontSize: 11, color: context.dso.muted),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 42,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                for (final WeeklyAiRollup row in evaluated)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Tooltip(
                      message:
                          '${_formatDate(row.weekStart)}: '
                          '${row.meanAbsolutePercentageError!.toStringAsFixed(1)}% '
                          '(${row.percentageErrorCount} forecasts)',
                      child: Container(
                        width: 16,
                        height: maxMape <= 0
                            ? 4
                            : (4 +
                                  34 *
                                      (row.meanAbsolutePercentageError! /
                                          maxMape)),
                        decoration: BoxDecoration(
                          color: row.meanAbsolutePercentageError! > 35
                              ? const Color(0xFFF97066)
                              : const Color(0xFF3A7D5C),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RunHistory extends StatelessWidget {
  const _RunHistory({required this.rows, required this.hasError});

  final List<AiRunRecord> rows;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'AI run history',
      child: hasError
          ? const Text('Run history could not be loaded.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AiFreshnessChip(
                  hasData: rows.isNotEmpty,
                  timestamps: rows.expand(
                    (AiRunRecord row) => <DateTime?>[
                      row.generatedAt,
                      row.updatedAt,
                      row.finishedAt,
                      row.startedAt,
                    ],
                  ),
                  hasMissingTimestamp: rows.any(
                    (AiRunRecord row) =>
                        row.generatedAt == null &&
                        row.updatedAt == null &&
                        row.finishedAt == null &&
                        row.startedAt == null,
                  ),
                ),
                const SizedBox(height: 8),
                if (rows.isEmpty)
                  const Text('No AI runs recorded yet.')
                else
                  for (final AiRunRecord row in rows.take(8))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${row.status.toUpperCase()} · ${_formatMoment(row.startedAt)}',
                      ),
                      subtitle: Text(
                        '${row.patternCount} patterns · '
                        '${row.insightCount} insights · '
                        '${row.visitBriefCount} briefs · '
                        '${row.retailerSegmentCount} segments',
                      ),
                    ),
              ],
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: context.dso.body,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.danger = false,
  });

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: danger ? scheme.errorContainer : scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: danger ? scheme.error : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: danger ? context.dso.dangerText : context.dso.ink,
            ),
          ),
          Text(label, style: TextStyle(fontSize: 11, color: context.dso.muted)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.query_stats_outlined, size: 36),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(subtitle, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

bool _sameDay(DateTime? left, DateTime? right) =>
    _dayKey(left) == _dayKey(right);

String _dayKey(DateTime? value) =>
    value == null ? '' : '${value.year}-${value.month}-${value.day}';

String _formatDate(DateTime? value) {
  if (value == null) return 'Unknown week';
  return '${value.day.toString().padLeft(2, '0')}/'
      '${value.month.toString().padLeft(2, '0')}/${value.year}';
}

String _formatMoment(DateTime? value) {
  if (value == null) return 'Unknown time';
  final DateTime local = value.toLocal();
  return '${_formatDate(local)} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
