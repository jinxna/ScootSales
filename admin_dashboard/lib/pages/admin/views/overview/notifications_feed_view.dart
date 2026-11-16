import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../widgets/filter_chip.dart';
import 'notification_feed_model.dart';
import 'overview_widgets.dart';

class NotificationsFeedView extends StatelessWidget {
  const NotificationsFeedView({
    super.key,
    required this.phase,
    required this.onRetry,
    required this.groups,
    required this.totalEntries,
    required this.categoryCounts,
    required this.category,
    required this.onCategory,
    required this.unreadLabel,
    required this.canMarkAllRead,
    required this.markingAllRead,
    required this.onMarkAllRead,
    required this.dateLabel,
    required this.dateActive,
    required this.onPickDate,
    required this.onClearDate,
    required this.failedSources,
    required this.readStateFailed,
    required this.onRetryReadState,
    required this.hasMore,
    required this.onLoadMore,
    required this.onOpen,
  });

  final ScootLoadPhase phase;
  final VoidCallback onRetry;
  final List<NotificationDayGroup> groups;
  final int totalEntries;
  final Map<NotificationCategory, int> categoryCounts;
  final NotificationCategory? category;
  final ValueChanged<NotificationCategory?> onCategory;
  final String unreadLabel;
  final bool canMarkAllRead;
  final bool markingAllRead;
  final VoidCallback onMarkAllRead;
  final String dateLabel;
  final bool dateActive;
  final VoidCallback onPickDate;
  final VoidCallback onClearDate;
  final Set<String> failedSources;
  final bool readStateFailed;
  final VoidCallback onRetryReadState;
  final bool hasMore;
  final VoidCallback onLoadMore;
  final ValueChanged<NotificationEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(ScootSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (phase == ScootLoadPhase.ready)
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  unreadLabel,
                  style: ScootType.body.copyWith(
                    color: ScootColors.of(context).muted,
                  ),
                ),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    OutlinedButton.icon(
                      key: const ValueKey<String>('notif-date'),
                      onPressed: onPickDate,
                      icon: const Icon(ScootIcons.calendar, size: 18),
                      label: Text(dateLabel),
                    ),
                    if (dateActive)
                      IconButton(
                        key: const ValueKey<String>('notif-clear-date'),
                        tooltip: 'Clear date filter',
                        onPressed: onClearDate,
                        icon: const Icon(ScootIcons.close),
                      ),
                    FilledButton.icon(
                      key: const ValueKey<String>('notif-read-all'),
                      onPressed: canMarkAllRead ? onMarkAllRead : null,
                      icon: Icon(
                        markingAllRead
                            ? ScootIcons.hourglass
                            : ScootIcons.check,
                        size: 18,
                      ),
                      label: Text(
                        markingAllRead ? 'Saving' : 'Mark all as read',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          if (failedSources.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            ScootNotice(
              key: const ValueKey<String>('partial-alerts-warning'),
              tone: ScootTone.warning,
              title: 'Partial data',
              message:
                  'Some sources could not be read (${(failedSources.toList()..sort()).join(', ')}). The list may be incomplete.',
              actionLabel: 'Retry',
              onAction: onRetry,
            ),
          ],
          if (readStateFailed) ...<Widget>[
            const SizedBox(height: 12),
            ScootNotice(
              key: const ValueKey<String>('read-state-warning'),
              tone: ScootTone.warning,
              title: 'Read status not saved',
              message:
                  'Could not save read status. Try again when you are online.',
              actionLabel: 'Retry',
              onAction: onRetryReadState,
            ),
          ],
          const SizedBox(height: ScootSpace.md),
          Expanded(child: _card(context)),
        ],
      ),
    );
  }

  Widget _card(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    switch (phase) {
      case ScootLoadPhase.loading:
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(ScootSpace.lg),
          child: ScootLoadingState(
            onRetry: onRetry,
            semanticLabel: 'Loading notifications',
            skeleton: Column(
              children: <Widget>[
                for (int i = 0; i < 6; i++)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: ScootSkeleton(height: 52, radius: 10),
                  ),
              ],
            ),
          ),
        );
      case ScootLoadPhase.error:
        return Center(
          child: ScootErrorState(
            title: 'Notifications unavailable',
            message: 'The latest notifications could not be loaded.',
            onRetry: onRetry,
          ),
        );
      case ScootLoadPhase.ready:
        if (totalEntries == 0 && !dateActive) {
          return const Center(
            child: ScootEmptyState(
              icon: ScootIcons.notifications,
              title: 'No notifications yet',
              message: 'Orders and arrivals from the phone appear here.',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _chips(context),
            Divider(height: 1, color: ScootColors.of(context).hair),
            Expanded(child: _list(context)),
          ],
        );
    }
  }

  Widget _chips(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          PageFilterChip(
            key: const ValueKey<String>('notif-chip-All'),
            label: 'All',
            count: totalEntries,
            selected: category == null,
            onTap: () => onCategory(null),
          ),
          for (final NotificationCategory item in NotificationCategory.values)
            if ((categoryCounts[item] ?? 0) > 0 || category == item)
              PageFilterChip(
                key: ValueKey<String>('notif-chip-${item.label}'),
                label: item.label,
                count: categoryCounts[item] ?? 0,
                selected: category == item,
                onTap: () => onCategory(category == item ? null : item),
              ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (groups.isEmpty) {
      return Center(
        child: ScootEmptyState(
          icon: ScootIcons.noEvent,
          title: category == null
              ? 'No activity on this date'
              : 'No ${category!.label.toLowerCase()} activity here',
          message: 'Choose another date or type above.',
        ),
      );
    }
    final List<Object> items = <Object>[
      for (final NotificationDayGroup group in groups) ...<Object>[
        group,
        ...group.entries,
      ],
      if (hasMore) 'more',
    ];
    return SelectionContainer.disabled(
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 8),
        itemCount: items.length,
        itemBuilder: (BuildContext context, int index) {
          final Object item = items[index];
          if (item is NotificationDayGroup) {
            return _DayHeader(label: item.label, count: item.entries.length);
          }
          if (item is NotificationEntry) {
            return NotificationRow(
              entry: item,
              onTap: item.orderDocumentId.isEmpty ? null : () => onOpen(item),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: OutlinedButton.icon(
                key: const ValueKey<String>('notif-load-more'),
                onPressed: onLoadMore,
                icon: const Icon(ScootIcons.expandMore, size: 18),
                label: const Text('Load 20 more'),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      header: true,
      child: Container(
        color: c.tableHead,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: <Widget>[
            Text(
              label,
              style: ScootType.tableHead.copyWith(color: c.tableHeadText),
            ),
            const SizedBox(width: 8),
            Text('$count', style: ScootType.small.copyWith(color: c.muted)),
          ],
        ),
      ),
    );
  }
}

class NotificationRow extends StatelessWidget {
  const NotificationRow({super.key, required this.entry, required this.onTap});

  final NotificationEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final String when = relativeTimeLabel(entry.time);
    final String title = entry.count > 1
        ? '${entry.title} ×${entry.count}'
        : entry.title;
    final Widget dot = Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: entry.unread ? c.brand : Colors.transparent,
        border: Border.all(color: entry.unread ? c.brand : c.line2, width: 1.5),
      ),
    );
    final Widget row = Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hair)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          dot,
          const SizedBox(width: 12),
          Icon(notificationIconFor(entry.type), size: 20, color: c.text2),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ScootLongText(
                  title,
                  style: (entry.unread ? ScootType.bodyStrong : ScootType.body)
                      .copyWith(color: c.ink),
                ),
                if (entry.detail.isNotEmpty)
                  ScootLongText(
                    entry.detail,
                    maxLines: 1,
                    style: ScootType.small.copyWith(color: c.muted),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(when, style: ScootType.small.copyWith(color: c.muted)),
          if (onTap != null) ...<Widget>[
            const SizedBox(width: 8),
            Icon(ScootIcons.chevronRight, size: 20, color: c.muted),
          ],
        ],
      ),
    );
    return Semantics(
      container: true,
      button: onTap != null,
      label:
          '${entry.unread ? 'Unread. ' : ''}$title. ${entry.detail}. $when. ${entry.category.label}',
      excludeSemantics: true,
      child: onTap == null
          ? row
          : InkWell(onTap: onTap, hoverColor: c.hair, child: row),
    );
  }
}
