import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

class VisitRowData {
  const VisitRowData({
    required this.retailer,
    required this.salesperson,
    required this.arrived,
    required this.left,
    required this.assignedRoute,
    required this.status,
  });

  final String retailer;
  final String salesperson;
  final DateTime? arrived;
  final DateTime? left;
  final bool assignedRoute;
  final String status;
}

class FollowUpRowData {
  const FollowUpRowData({
    required this.retailer,
    required this.salesperson,
    required this.lastVisit,
    required this.lastOrder,
    required this.reason,
    required this.action,
    required this.overdue,
  });

  final String retailer;
  final String salesperson;
  final String lastVisit;
  final String lastOrder;
  final String reason;
  final String action;
  final bool overdue;
}

DateTime _kl(DateTime value) => value.toUtc().add(const Duration(hours: 8));

String _two(int value) => value.toString().padLeft(2, '0');

const List<String> _months = <String>[
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

String visitClock(DateTime? value, {bool withDate = false}) {
  if (value == null) return '-';
  final DateTime kl = _kl(value);
  final String clock = '${_two(kl.hour)}:${_two(kl.minute)}';
  return withDate ? '${kl.day} ${_months[kl.month - 1]} $clock' : clock;
}

String visitOnSite(DateTime? arrived, DateTime? left) {
  if (arrived == null || left == null) return '-';
  final int minutes = left.difference(arrived).inMinutes;
  if (minutes < 0) return '-';
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${_two(minutes % 60)} min';
}

class VisitsTableCard extends StatelessWidget {
  const VisitsTableCard({
    super.key,
    required this.phase,
    required this.rows,
    required this.onRetry,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.summary,
    required this.showDate,
    this.emptyAction,
    this.pagesLoaded = 1,
    this.hasMore = false,
    this.onLoadMore,
  });

  final ScootLoadPhase phase;
  final List<VisitRowData> rows;
  final VoidCallback onRetry;
  final String emptyTitle;
  final String emptyMessage;
  final String summary;
  final bool showDate;
  final Widget? emptyAction;
  final int pagesLoaded;
  final bool hasMore;
  final VoidCallback? onLoadMore;

  List<ScootTableColumn<VisitRowData>> _columns() {
    return <ScootTableColumn<VisitRowData>>[
      ScootTableColumn<VisitRowData>(
        label: 'Retailer',
        flex: 4,
        cell: (BuildContext context, VisitRowData row) => Tooltip(
          message: row.retailer,
          child: Text(
            row.retailer,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ScootType.bodyStrong,
          ),
        ),
      ),
      ScootTableColumn<VisitRowData>(
        label: 'Salesperson',
        flex: 3,
        cell: (BuildContext context, VisitRowData row) => Tooltip(
          message: row.salesperson,
          child: Text(
            row.salesperson,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      ScootTableColumn<VisitRowData>(
        label: 'Arrived',
        flex: 2,
        cell: (BuildContext context, VisitRowData row) =>
            Text(visitClock(row.arrived, withDate: showDate)),
      ),
      ScootTableColumn<VisitRowData>(
        label: 'Left',
        flex: 2,
        cell: (BuildContext context, VisitRowData row) => Text(
          row.left == null ? '-' : visitClock(row.left, withDate: showDate),
        ),
      ),
      ScootTableColumn<VisitRowData>(
        label: 'On site',
        flex: 2,
        cell: (BuildContext context, VisitRowData row) =>
            Text(visitOnSite(row.arrived, row.left)),
      ),
      ScootTableColumn<VisitRowData>(
        label: 'Source',
        flex: 2,
        cell: (BuildContext context, VisitRowData row) =>
            Text(row.assignedRoute ? 'Assigned route' : 'Phone visit'),
      ),
      ScootTableColumn<VisitRowData>(
        label: 'Status',
        flex: 2,
        cell: (BuildContext context, VisitRowData row) =>
            _statusBadge(row.status),
      ),
    ];
  }

  Widget _statusBadge(String status) {
    switch (status) {
      case 'completed':
        return const ScootBadge(
          label: 'Completed',
          tone: ScootTone.success,
          icon: ScootIcons.check,
        );
      case 'skipped':
        return const ScootBadge(
          label: 'Skipped',
          tone: ScootTone.warning,
          icon: ScootIcons.remove,
        );
      default:
        return const ScootBadge(
          label: 'In progress',
          tone: ScootTone.info,
          icon: ScootIcons.clock,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      clipBehavior: Clip.antiAlias,
      child: ScootDataTable<VisitRowData>(
        columns: _columns(),
        rows: rows,
        phase: phase,
        onRetry: onRetry,
        emptyTitle: emptyTitle,
        emptyMessage: emptyMessage,
        emptyAction: emptyAction,
        countLabel: summary,
        pagesLoaded: pagesLoaded,
        hasMore: hasMore,
        onLoadMore: onLoadMore,
        live: true,
        minTableWidth: 900,
        rowLabel: (VisitRowData row) =>
            '${row.retailer}, ${row.salesperson}, ${row.status}',
      ),
    );
  }
}

class FollowUpListCard extends StatelessWidget {
  const FollowUpListCard({
    super.key,
    required this.phase,
    required this.items,
    required this.onRetry,
    this.unavailableMessage,
  });

  final ScootLoadPhase phase;
  final List<FollowUpRowData> items;
  final VoidCallback onRetry;
  final String? unavailableMessage;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    Widget body;
    if (unavailableMessage != null) {
      body = Padding(
        padding: const EdgeInsets.all(ScootSpace.lg),
        child: ScootNotice(
          key: const ValueKey<String>('follow-up-unavailable'),
          tone: ScootTone.warning,
          title: 'Follow-up unavailable',
          message: unavailableMessage!,
          actionLabel: 'Retry',
          onAction: onRetry,
        ),
      );
    } else if (phase == ScootLoadPhase.loading) {
      body = SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(ScootSpace.lg),
        child: ScootLoadingState(
          onRetry: onRetry,
          semanticLabel: 'Loading follow-up',
          skeleton: Column(
            children: <Widget>[
              for (int i = 0; i < 5; i++)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: ScootSkeleton(height: 56, radius: 10),
                ),
            ],
          ),
        ),
      );
    } else if (items.isEmpty) {
      body = const Center(
        child: ScootEmptyState(
          icon: ScootIcons.check,
          title: 'No retailer follow-up needed',
          message: 'Retailers with older visit or order activity appear here.',
        ),
      );
    } else {
      body = ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: c.hair),
        itemBuilder: (BuildContext context, int index) {
          final FollowUpRowData item = items[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ScootLongText(
                        item.retailer,
                        maxLines: 1,
                        style: ScootType.bodyStrong.copyWith(color: c.ink),
                      ),
                      ScootLongText(
                        '${item.reason} Last visit ${item.lastVisit}, last order ${item.lastOrder}.',
                        style: ScootType.small.copyWith(color: c.muted),
                      ),
                      Text(
                        '${item.salesperson} · ${item.action}',
                        style: ScootType.small.copyWith(color: c.text2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (item.overdue)
                  const ScootBadge.attention(label: 'Overdue')
                else
                  const ScootBadge(label: 'Follow-up', tone: ScootTone.info),
              ],
            ),
          );
        },
      );
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: body,
    );
  }
}
