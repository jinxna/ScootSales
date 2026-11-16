import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

enum HealthStatus { attention, info, passed }

class HealthItem {
  const HealthItem({
    required this.title,
    required this.status,
    required this.description,
    this.fixKey = '',
  });

  final String title;
  final HealthStatus status;
  final String description;
  final String fixKey;
}

class SystemHealthView extends StatelessWidget {
  const SystemHealthView({
    super.key,
    required this.items,
    required this.loading,
    required this.onRun,
    this.lastRun,
    this.onOpenPage,
    this.extra,
  });

  final List<HealthItem> items;
  final bool loading;
  final VoidCallback onRun;
  final String? lastRun;
  final ValueChanged<String>? onOpenPage;
  final Widget? extra;

  List<HealthItem> _of(HealthStatus status) =>
      items.where((HealthItem i) => i.status == status).toList();

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final List<HealthItem> attention = _of(HealthStatus.attention);
    final List<HealthItem> info = _of(HealthStatus.info);
    final List<HealthItem> passed = _of(HealthStatus.passed);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  loading
                      ? 'Running checks…'
                      : lastRun == null
                      ? 'Read-only checks. Nothing here changes a record.'
                      : 'Last run $lastRun',
                  style: ScootType.body.copyWith(color: c.muted),
                ),
              ),
              OutlinedButton.icon(
                onPressed: loading ? null : onRun,
                icon: const Icon(ScootIcons.refresh, size: 18),
                label: const Text('Run again'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (loading)
            ScootCard(
              child: ScootLoadingState(
                onRetry: onRun,
                semanticLabel: 'Running checks',
                skeleton: const ScootSkeletonLines(
                  widthFactors: <double>[0.5, 0.9, 0.7, 0.8],
                ),
              ),
            )
          else ...<Widget>[
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: <Widget>[
                _CountTile(
                  label: 'Need attention',
                  count: attention.length,
                  tone: attention.isEmpty
                      ? ScootTone.neutral
                      : ScootTone.warning,
                ),
                _CountTile(
                  label: 'For information',
                  count: info.length,
                  tone: ScootTone.info,
                ),
                _CountTile(
                  label: 'Passed',
                  count: passed.length,
                  tone: ScootTone.success,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (extra != null) ...<Widget>[extra!, const SizedBox(height: 16)],
            if (attention.isEmpty && info.isEmpty && passed.isEmpty)
              const ScootCard(
                child: ScootEmptyState(
                  title: 'No checks to show',
                  message: 'Press Run again.',
                ),
              )
            else if (attention.isEmpty)
              const ScootNotice(
                tone: ScootTone.success,
                title: 'All clear',
                message: 'Every check passed.',
              ),
            for (final HealthItem item in attention)
              _ProblemCard(item: item, onOpenPage: onOpenPage),
            for (final HealthItem item in info)
              _ProblemCard(item: item, onOpenPage: onOpenPage),
            if (passed.isNotEmpty)
              ScootCard(
                title: 'Passed',
                trailing: Text(
                  '${passed.length} checks',
                  style: ScootType.small.copyWith(color: c.muted),
                ),
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    for (final HealthItem item in passed)
                      Container(
                        constraints: const BoxConstraints(minHeight: 44),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              ScootIcons.success,
                              size: 18,
                              color: c.success.foreground,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 2,
                              child: ScootLongText(
                                item.title,
                                maxLines: 1,
                                style: ScootType.bodyStrong.copyWith(
                                  color: c.ink,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: ScootLongText(
                                item.description,
                                maxLines: 1,
                                style: ScootType.body.copyWith(color: c.muted),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.label,
    required this.count,
    required this.tone,
  });

  final String label;
  final int count;
  final ScootTone tone;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      container: true,
      label: '$label $count',
      excludeSemantics: true,
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.card,
          border: Border.all(color: c.line),
          borderRadius: ScootRadius.cardAll,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: ScootType.small.copyWith(color: c.muted)),
            const SizedBox(height: 4),
            Text(
              '$count',
              style: ScootType.kpi.copyWith(color: c.tone(tone).foreground),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  const _ProblemCard({required this.item, required this.onOpenPage});

  final HealthItem item;
  final ValueChanged<String>? onOpenPage;

  @override
  Widget build(BuildContext context) {
    final bool warn = item.status == HealthStatus.attention;
    final ScootTone tone = warn ? ScootTone.warning : ScootTone.info;
    final bool canOpen = onOpenPage != null && item.fixKey.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ScootNotice(
        tone: tone,
        icon: warn ? ScootIcons.warning : ScootIcons.info,
        title: item.title,
        message: item.description,
        actionLabel: canOpen ? 'Open page' : null,
        onAction: canOpen ? () => onOpenPage!(item.fixKey) : null,
      ),
    );
  }
}
