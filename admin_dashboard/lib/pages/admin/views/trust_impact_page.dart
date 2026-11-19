import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../models/user_profile.dart';
import '../../../services/trust_impact_service.dart';
import '../../../utils/trust_impact.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../../../widgets/page_states.dart';
import '../../../widgets/scorecard_section.dart';

class TrustImpactPage extends StatefulWidget {
  const TrustImpactPage({super.key, required this.currentUser});
  final UserProfile currentUser;

  @override
  State<TrustImpactPage> createState() => _TrustImpactPageState();
}

class _TrustImpactPageState extends State<TrustImpactPage> {
  late Future<TrustImpactLoadResult> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _future = TrustImpactService().load(widget.currentUser);

  @override
  void didUpdateWidget(TrustImpactPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.docId != widget.currentUser.docId) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TrustImpactLoadResult>(
      future: _future,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<TrustImpactLoadResult> snapshot,
          ) {
            final TrustImpactLoadResult? result = snapshot.data;
            return TrustImpactView(
              loading:
                  snapshot.connectionState == ConnectionState.waiting &&
                  result == null,
              error: snapshot.hasError || (result == null && !snapshot.hasData)
                  ? (snapshot.error ?? StateError('no data'))
                  : null,
              report: result?.report,
              failedSources: result?.failedSources ?? const <String>[],
              summaries:
                  result?.latestSummaries ?? const <Map<String, dynamic>>[],
              salespersonNames:
                  result?.salespersonNames ?? const <String, String>{},
              onRefresh: () => setState(_reload),
              freshness: result == null
                  ? null
                  : AiFreshnessChip(
                      hasData: result.hasAiData,
                      timestamps: result.aiTimestamps,
                      hasMissingTimestamp: result.hasMissingAiTimestamp,
                    ),
            );
          },
    );
  }
}

class TrustImpactView extends StatelessWidget {
  const TrustImpactView({
    super.key,
    required this.loading,
    required this.onRefresh,
    this.error,
    this.report,
    this.failedSources = const <String>[],
    this.summaries = const <Map<String, dynamic>>[],
    this.salespersonNames = const <String, String>{},
    this.freshness,
  });

  final List<Map<String, dynamic>> summaries;
  final Map<String, String> salespersonNames;

  final bool loading;
  final Object? error;
  final TrustImpactReport? report;
  final List<String> failedSources;
  final VoidCallback onRefresh;
  final Widget? freshness;

  static const int smallSample = 20;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return SingleChildScrollView(
        child: ScootCard(
          child: ScootLoadingState(
            onRetry: onRefresh,
            skeleton: const ScootSkeletonLines(
              widthFactors: <double>[0.5, 0.9, 0.7, 0.8],
            ),
          ),
        ),
      );
    }
    final TrustImpactReport? data = report;
    if (error != null || data == null) {
      return ScootCard(
        child: PageErrorState(
          error: error,
          onRetry: onRefresh,
          title: 'Evidence could not load',
        ),
      );
    }
    final ScootColors c = ScootColors.of(context);
    final List<TrustMetric> withData = data.metrics
        .where((TrustMetric m) => m.sampleSize > 0)
        .toList();
    final List<TrustMetric> without = data.metrics
        .where((TrustMetric m) => m.sampleSize == 0)
        .toList();
    final bool small =
        withData.isNotEmpty &&
        withData.every((TrustMetric m) => m.sampleSize < smallSample);
    final int reasonTotal = data.abstentionReasons.entries
        .where(
          (MapEntry<String, int> e) =>
              !data.unavailableAbstentionReasons.contains(e.key),
        )
        .fold<int>(0, (int sum, MapEntry<String, int> e) => sum + e.value);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  data.latestEvidenceAt == null
                      ? 'Evidence time not available'
                      : 'Evidence from ${_stamp(data.latestEvidenceAt!)}',
                  style: ScootType.body.copyWith(color: c.muted),
                ),
              ),
              ?freshness,
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: onRefresh,
                icon: const Icon(ScootIcons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (failedSources.isNotEmpty) ...<Widget>[
            ScootNotice(
              tone: ScootTone.warning,
              title: 'Partial evidence',
              message:
                  'Could not read: ${failedSources.join(', ')}. The numbers leave those records out.',
            ),
            const SizedBox(height: 12),
          ],
          if (small) ...<Widget>[
            const ScootNotice(
              tone: ScootTone.warning,
              title: 'Small samples',
              message:
                  'These numbers come from very few records. Read them with care.',
            ),
            const SizedBox(height: 16),
          ],
          ScorecardSection(
            summaries: summaries,
            salespersonNames: salespersonNames,
            readFailed: failedSources.contains('weekly_ai_summaries'),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final int columns = constraints.maxWidth >= 1100
                  ? 3
                  : constraints.maxWidth >= 650
                  ? 2
                  : 1;
              final double width = columns == 1
                  ? constraints.maxWidth
                  : (constraints.maxWidth - (columns - 1) * 16) / columns;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: <Widget>[
                  for (final TrustMetric metric in withData)
                    SizedBox(
                      width: width,
                      child: _MetricCard(metric: metric),
                    ),
                ],
              );
            },
          ),
          if (withData.isEmpty)
            const ScootCard(
              child: ScootEmptyState(
                title: 'Not enough data yet',
                message: 'Numbers appear after suggestions turn into work.',
              ),
            ),
          if (without.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            ScootCard(
              title: 'Not enough data yet',
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  for (final TrustMetric metric in without)
                    Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: ScootLongText(
                              metric.label,
                              maxLines: 1,
                              style: ScootType.bodyStrong.copyWith(
                                color: c.ink,
                              ),
                            ),
                          ),
                          Text(
                            '0 evaluated',
                            style: ScootType.small.copyWith(color: c.muted),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          ScootCard(
            title: 'Why the system held back',
            trailing: Text(
              reasonTotal == 1 ? '1 case' : '$reasonTotal cases',
              style: ScootType.small.copyWith(color: c.muted),
            ),
            child: Column(
              children: <Widget>[
                for (final MapEntry<String, int> reason
                    in data.abstentionReasons.entries)
                  _ReasonBar(
                    label: reason.key,
                    count: reason.value,
                    total: reasonTotal,
                    unavailable: data.unavailableAbstentionReasons.contains(
                      reason.key,
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

String _stamp(DateTime value) {
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final DateTime local = value.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]} ${local.year}, '
      '${two(local.hour)}:${two(local.minute)}';
}

class _ReasonBar extends StatelessWidget {
  const _ReasonBar({
    required this.label,
    required this.count,
    required this.total,
    required this.unavailable,
  });

  final String label;
  final int count;
  final int total;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final double fraction = unavailable || total == 0 ? 0 : count / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: ScootLongText(
              label,
              maxLines: 2,
              style: ScootType.body.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: ClipRRect(
              borderRadius: ScootRadius.pillAll,
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: c.hair,
                color: c.brand,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              unavailable ? 'Unavailable' : '$count',
              textAlign: TextAlign.right,
              style: ScootType.bodyStrong.copyWith(
                color: unavailable ? c.muted : c.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric});
  final TrustMetric metric;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final int? numerator = metric.numerator;
    final String lead = numerator == null
        ? metric.value
        : '$numerator of ${metric.sampleSize}';
    return ScootCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ScootLongText(
            metric.label,
            maxLines: 2,
            style: ScootType.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: 8),
          Text(lead, style: ScootType.kpi.copyWith(color: c.ink)),
          const SizedBox(height: 4),
          Text(
            numerator == null
                ? '${metric.sampleSize} evaluated'
                : '${metric.value} · ${metric.sampleSize} evaluated',
            style: ScootType.small.copyWith(color: c.muted),
          ),
          const SizedBox(height: 8),
          ScootLongText(
            metric.explanation,
            maxLines: 3,
            style: ScootType.small.copyWith(color: c.text2),
          ),
        ],
      ),
    );
  }
}
