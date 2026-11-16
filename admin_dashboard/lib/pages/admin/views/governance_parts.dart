import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

const List<String> purgeableCollections = <String>[
  'visit_logs',
  'live_tracking',
  'notifications',
];

class GovernanceLoadFailed extends StatelessWidget {
  const GovernanceLoadFailed({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ScootCard(
      child: ScootErrorState(
        title: 'The schedule could not load',
        onRetry: onRetry,
      ),
    );
  }
}

class GovernanceLoading extends StatelessWidget {
  const GovernanceLoading({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ScootCard(
      child: ScootLoadingState(
        onRetry: onRetry,
        skeleton: const ScootSkeletonLines(
          widthFactors: <double>[0.4, 0.9, 0.6],
        ),
      ),
    );
  }
}

class OrderRetentionCard extends StatelessWidget {
  const OrderRetentionCard({
    super.key,
    required this.retentionMonths,
    required this.enabled,
    required this.busy,
    required this.lastRun,
    required this.removed,
    required this.keptCount,
    required this.lastRunFailed,
    required this.canPurge,
    required this.onMonths,
    required this.onEnabled,
    required this.onSave,
    required this.onRunNow,
  });

  final int retentionMonths;
  final bool enabled;
  final bool busy;
  final String lastRun;
  final int removed;
  final int keptCount;
  final bool lastRunFailed;
  final bool canPurge;
  final ValueChanged<int> onMonths;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onSave;
  final VoidCallback onRunNow;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return ScootCard(
      title: 'Order retention',
      trailing: ScootBadge(
        label: enabled ? 'Automatic purge on' : 'Automatic purge off',
        tone: enabled ? ScootTone.success : ScootTone.neutral,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Orders are saved to CSV before deletion. Pending orders stay. The purge runs once a day when a developer opens this page.',
            style: ScootType.body.copyWith(color: c.muted),
          ),
          const SizedBox(height: 14),
          if (lastRunFailed) ...<Widget>[
            ScootNotice(
              tone: ScootTone.warning,
              title: 'Purge stopped early',
              message:
                  'Saved backups and finished deletions stay. Orders kept: $keptCount.',
            ),
            const SizedBox(height: 14),
          ],
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<int>(
                  key: ValueKey<int>(retentionMonths),
                  initialValue: retentionMonths,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Keep final orders for',
                  ),
                  items: const <DropdownMenuItem<int>>[
                    DropdownMenuItem(value: 3, child: Text('3 months')),
                    DropdownMenuItem(value: 6, child: Text('6 months')),
                    DropdownMenuItem(value: 12, child: Text('12 months')),
                    DropdownMenuItem(value: 84, child: Text('7 years')),
                  ],
                  onChanged: busy
                      ? null
                      : (int? value) {
                          if (value != null) onMonths(value);
                        },
                ),
              ),
              if (canPurge)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Switch(value: enabled, onChanged: busy ? null : onEnabled),
                    const SizedBox(width: 8),
                    const Text('Automatic purge'),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Last run: $lastRun · Orders removed: $removed',
            style: ScootType.small.copyWith(color: c.muted),
          ),
          if (keptCount > 0 && !lastRunFailed)
            Text(
              'Orders kept: $keptCount (changed, missing, or too large to back up).',
              style: ScootType.small.copyWith(color: c.muted),
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              FilledButton(
                onPressed: busy ? null : onSave,
                child: const Text('Save'),
              ),
              if (canPurge)
                OutlinedButton(
                  onPressed: busy ? null : onRunNow,
                  child: const Text('Run purge now…'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class DangerZoneCard extends StatelessWidget {
  const DangerZoneCard({
    super.key,
    required this.busy,
    required this.collection,
    required this.csvPreview,
    required this.onCollection,
    required this.onWipeLocations,
    required this.onPurge,
  });

  final bool busy;
  final String collection;
  final String csvPreview;
  final ValueChanged<String> onCollection;
  final VoidCallback onWipeLocations;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final ButtonStyle danger = OutlinedButton.styleFrom(
      foregroundColor: c.danger.foreground,
      side: BorderSide(color: c.danger.border),
    );
    return Container(
      decoration: BoxDecoration(
        borderRadius: ScootRadius.cardAll,
        border: Border.all(color: c.danger.border),
      ),
      child: ScootCard(
        title: 'Danger zone',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Export and wipe live locations',
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
            const SizedBox(height: 4),
            Text(
              'Saves live positions to CSV, then deletes them now.',
              style: ScootType.body.copyWith(color: c.muted),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              style: danger,
              onPressed: busy ? null : onWipeLocations,
              child: const Text('Export and wipe…'),
            ),
            const Divider(height: 32),
            Text(
              'Purge one collection',
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
            const SizedBox(height: 4),
            Text(
              'Saves the collection to purge_exports as CSV, then deletes every document.',
              style: ScootType.body.copyWith(color: c.muted),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey<String>(collection),
                    initialValue: collection,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Collection'),
                    items: <DropdownMenuItem<String>>[
                      for (final String name in purgeableCollections)
                        DropdownMenuItem<String>(
                          value: name,
                          child: Text(name),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (String? value) {
                            if (value != null) onCollection(value);
                          },
                  ),
                ),
                OutlinedButton(
                  style: danger,
                  onPressed: busy ? null : onPurge,
                  child: Text(busy ? 'Working…' : 'Export and purge…'),
                ),
              ],
            ),
            if (csvPreview.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              SelectableText(csvPreview, style: ScootType.mono),
            ],
          ],
        ),
      ),
    );
  }
}

class AdminAccessRow {
  const AdminAccessRow({
    required this.docId,
    required this.name,
    required this.email,
    required this.enabled,
    required this.raw,
  });

  final String docId;
  final String name;
  final String email;
  final bool enabled;
  final Map<String, dynamic> raw;
}

class AdminAccessCard extends StatelessWidget {
  const AdminAccessCard({
    super.key,
    required this.phase,
    required this.rows,
    required this.canChange,
    required this.onToggle,
    required this.onRetry,
  });

  final ScootLoadPhase phase;
  final List<AdminAccessRow> rows;
  final bool canChange;
  final void Function(AdminAccessRow row, bool enabled) onToggle;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Widget body;
    switch (phase) {
      case ScootLoadPhase.loading:
        body = ScootLoadingState(
          onRetry: onRetry,
          skeleton: const ScootSkeletonLines(
            widthFactors: <double>[0.6, 0.5, 0.7],
          ),
        );
      case ScootLoadPhase.error:
        body = ScootErrorState(
          title: 'Admin accounts could not load',
          onRetry: onRetry,
        );
      case ScootLoadPhase.ready:
        body = rows.isEmpty
            ? const ScootEmptyState(
                icon: ScootIcons.person,
                title: 'No admin accounts found',
              )
            : Column(
                children: <Widget>[
                  for (final AdminAccessRow row in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                ScootLongText(
                                  row.name,
                                  maxLines: 1,
                                  style: ScootType.bodyStrong.copyWith(
                                    color: c.ink,
                                  ),
                                ),
                                if (row.email.isNotEmpty)
                                  ScootLongText(
                                    row.email,
                                    maxLines: 1,
                                    style: ScootType.small.copyWith(
                                      color: c.muted,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          ScootBadge(
                            label: row.enabled ? 'Enabled' : 'Disabled',
                            tone: row.enabled
                                ? ScootTone.success
                                : ScootTone.neutral,
                          ),
                          Switch(
                            value: row.enabled,
                            onChanged: canChange
                                ? (bool value) => onToggle(row, value)
                                : null,
                          ),
                        ],
                      ),
                    ),
                ],
              );
    }
    return ScootCard(title: 'Admin access', child: body);
  }
}
