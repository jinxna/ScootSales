import 'package:flutter/material.dart';

import '../../../models/action_centre_item.dart';
import '../../../models/user_profile.dart';
import '../../../services/action_centre_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/exception_control_tower.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../widgets/cms_panel.dart';
import '../../../widgets/slow_loading.dart';

typedef ExceptionTowerLoader = Future<ActionCentreLoadResult> Function();

class ExceptionControlTowerPanel extends StatefulWidget {
  const ExceptionControlTowerPanel({
    super.key,
    required this.currentUser,
    this.onNavigateRequested,
    this.loader,
  });

  final UserProfile currentUser;
  final ValueChanged<String>? onNavigateRequested;
  final ExceptionTowerLoader? loader;

  @override
  State<ExceptionControlTowerPanel> createState() =>
      _ExceptionControlTowerPanelState();
}

class _ExceptionControlTowerPanelState
    extends State<ExceptionControlTowerPanel> {
  late Future<ActionCentreLoadResult> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(ExceptionControlTowerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.docId != widget.currentUser.docId ||
        oldWidget.loader != widget.loader) {
      _reload();
    }
  }

  void _reload({bool refresh = false}) {
    _future =
        widget.loader?.call() ??
        ActionCentreService().loadAllItemsWithHealth(
          currentUser: widget.currentUser,
          refresh: refresh,
        );
  }

  @override
  Widget build(BuildContext context) {
    return CmsPanel(
      title: 'Exception Control Tower',
      trailing: TextButton.icon(
        onPressed: () => setState(() => _reload(refresh: true)),
        icon: const Icon(Icons.refresh, size: 17),
        label: const Text('Refresh'),
      ),
      child: SizedBox(
        width: double.infinity,
        child: FutureBuilder<ActionCentreLoadResult>(
          future: _future,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<ActionCentreLoadResult> snapshot,
              ) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: SlowLoading(),
                  );
                }
                if (snapshot.hasError) {
                  return _TowerMessage(
                    icon: Icons.cloud_off_outlined,
                    title: 'Decision queues unavailable',
                    subtitle:
                        'The bounded operational reads could not be completed. Existing modules remain available.',
                    action: FilledButton.icon(
                      onPressed: () => setState(() => _reload(refresh: true)),
                      icon: const Icon(Icons.refresh, size: 17),
                      label: const Text('Retry'),
                    ),
                  );
                }
                final ActionCentreLoadResult result =
                    snapshot.data ??
                    const ActionCentreLoadResult(
                      items: <ActionCentreItem>[],
                      failedSources: <String>[],
                    );
                final List<ExceptionQueue> queues = buildExceptionQueues(
                  result.items,
                );
                return LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double availableWidth = constraints.maxWidth > 32
                        ? constraints.maxWidth - 32
                        : constraints.maxWidth;
                    final int columns = exceptionTowerColumnCount(
                      availableWidth,
                    );
                    final double width = columns == 1
                        ? availableWidth
                        : (availableWidth - (columns - 1) * 12) / columns;
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Five role-scoped queues show what needs a decision now. Open an item for the existing detailed workflow.',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (result.failedSources.isNotEmpty ||
                              result.cutShortSources.isNotEmpty) ...<Widget>[
                            _PartialDataWarning(
                              sources: result.failedSources,
                              cutShort: result.cutShortSources,
                            ),
                            const SizedBox(height: 14),
                          ],
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: <Widget>[
                              for (final ExceptionQueue queue in queues)
                                SizedBox(
                                  width: width,
                                  child: _QueueCard(
                                    queue: queue,
                                    onOpen: widget.onNavigateRequested,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
        ),
      ),
    );
  }
}

class _PartialDataWarning extends StatelessWidget {
  const _PartialDataWarning({required this.sources, required this.cutShort});
  final List<String> sources;
  final List<String> cutShort;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.dso.warningSoft,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: context.dso.warning.withValues(alpha: 0.4)),
    ),
    child: Text(
      'Partial data: ${<String>[if (sources.isNotEmpty) '${sources.join(', ')} could not be read', ...cutShort].join('; ')}. Queue counts may be incomplete.',
      style: TextStyle(color: context.dso.warningText, fontSize: 12.5),
    ),
  );
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.queue, required this.onOpen});

  final ExceptionQueue queue;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ActionCentreItem? first = queue.items.isEmpty
        ? null
        : queue.items.first;
    final bool urgent = queue.highCount > 0;
    return Container(
      constraints: const BoxConstraints(minHeight: 170),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: urgent
              ? context.dso.danger.withValues(alpha: 0.4)
              : context.dso.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  exceptionQueueTitle(queue.kind),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _CountBadge(count: queue.items.length, urgent: urgent),
            ],
          ),
          const SizedBox(height: 8),
          if (first == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  exceptionQueueEmptyText(queue.kind),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else ...<Widget>[
            Text(
              first.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              first.reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.3,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (first.source == 'rule_based_forecast') ...<Widget>[
              const SizedBox(height: 6),
              AiFreshnessChip(
                hasData: true,
                timestamps: <DateTime?>[first.freshnessAt],
                hasMissingTimestamp: first.freshnessAt == null,
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Next: ${first.recommendedAction}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.3,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${first.priority} · ${first.confidence} confidence',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(44, 34),
                  ),
                  onPressed: first.relatedPageKey.isEmpty || onOpen == null
                      ? null
                      : () => onOpen!(first.relatedPageKey),
                  child: const Text('Open'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.urgent});
  final int count;
  final bool urgent;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: urgent ? context.dso.dangerSoft : context.dso.surfaceSoft,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      '$count',
      style: TextStyle(
        fontWeight: FontWeight.w800,
        color: urgent ? context.dso.dangerText : context.dso.body,
      ),
    ),
  );
}

class _TowerMessage extends StatelessWidget {
  const _TowerMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 38, color: context.dso.muted),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(subtitle, textAlign: TextAlign.center),
        const SizedBox(height: 14),
        action,
      ],
    ),
  );
}
