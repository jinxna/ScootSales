import 'package:flutter/material.dart';

import '../common/states.dart';
import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';

enum ScootLoadPhase { loading, ready, error }

class ScootTableColumn<T> {
  const ScootTableColumn({
    required this.label,
    required this.cell,
    this.flex = 1,
    this.width,
    this.numeric = false,
  });

  final String label;
  final Widget Function(BuildContext context, T row) cell;
  final int flex;
  final double? width;
  final bool numeric;
}

class ScootDataTable<T> extends StatelessWidget {
  const ScootDataTable({
    super.key,
    required this.columns,
    required this.rows,
    required this.phase,
    required this.onRetry,
    required this.emptyTitle,
    this.emptyMessage,
    this.emptyAction,
    this.hasMore = false,
    this.loadingMore = false,
    this.onLoadMore,
    this.isSelected,
    this.onRowTap,
    this.rowLabel,
    this.countLabel,
    this.live = false,
    this.skeletonRows = 8,
    this.pageSize = ScootPaging.pageSize,
    this.pagesLoaded = 1,
    this.stillLoadingAfter = ScootTiming.stillLoadingAfter,
    this.minTableWidth = phoneWidth,
  });

  final List<ScootTableColumn<T>> columns;
  final List<T> rows;
  final ScootLoadPhase phase;
  final VoidCallback onRetry;
  final String emptyTitle;
  final String? emptyMessage;
  final Widget? emptyAction;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback? onLoadMore;
  final bool Function(T row)? isSelected;
  final ValueChanged<T>? onRowTap;
  final String Function(T row)? rowLabel;
  final String? countLabel;
  final bool live;
  final int skeletonRows;
  final int pageSize;
  final int pagesLoaded;
  final Duration stillLoadingAfter;
  final double minTableWidth;

  static const double phoneWidth = 600;

  Widget _cell(ScootTableColumn<T> column, Widget child) {
    final Widget aligned = Align(
      alignment: column.numeric ? Alignment.centerRight : Alignment.centerLeft,
      child: child,
    );
    final Widget padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: aligned,
    );
    if (column.width != null) {
      return SizedBox(width: column.width, child: padded);
    }
    return Expanded(flex: column.flex, child: padded);
  }

  List<T> get _shown {
    final int limit = pageSize * pagesLoaded;
    return rows.length <= limit ? rows : rows.sublist(0, limit);
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool bounded = constraints.hasBoundedHeight;
        final bool phone =
            constraints.maxWidth < phoneWidth ||
            constraints.maxWidth < minTableWidth;
        final Widget body = _body(context, c, bounded, phone);
        return Column(
          mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!phone) _header(c),
            if (bounded) Expanded(child: body) else body,
            if (phase == ScootLoadPhase.ready && rows.isNotEmpty)
              _footer(c, _shown.length),
          ],
        );
      },
    );
  }

  Widget _header(ScootColors c) {
    return Semantics(
      container: true,
      label: 'Column headers',
      explicitChildNodes: true,
      child: Container(
        height: ScootSize.tableHeader,
        decoration: BoxDecoration(
          color: c.tableHead,
          border: Border(bottom: BorderSide(color: c.hair)),
        ),
        child: Row(
          children: <Widget>[
            for (final ScootTableColumn<T> column in columns)
              _cell(
                column,
                Semantics(
                  header: true,
                  child: Text(
                    column.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.tableHead.copyWith(color: c.tableHeadText),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ScootColors c, bool bounded, bool phone) {
    switch (phase) {
      case ScootLoadPhase.loading:
        return ClipRect(
          child: ScootLoadingState(
            onRetry: onRetry,
            stillLoadingAfter: stillLoadingAfter,
            semanticLabel: 'Loading rows',
            skeleton: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < skeletonRows; i++)
                  _skeletonRow(c, i, phone),
              ],
            ),
          ),
        );
      case ScootLoadPhase.error:
        return Center(child: ScootErrorState(onRetry: onRetry));
      case ScootLoadPhase.ready:
        if (rows.isEmpty) {
          return Center(
            child: ScootEmptyState(
              title: emptyTitle,
              message: emptyMessage,
              action: emptyAction,
            ),
          );
        }
        final List<T> shown = _shown;
        return ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: !bounded,
          physics: bounded ? null : const NeverScrollableScrollPhysics(),
          itemCount: shown.length,
          itemExtent: phone ? null : ScootSize.tableRow,
          itemBuilder: (BuildContext context, int index) =>
              _row(context, c, shown[index], index, phone),
        );
    }
  }

  Widget _skeletonRow(ScootColors c, int index, bool phone) {
    const List<double> widths = <double>[0.8, 0.6, 0.9, 0.5, 0.7];
    Widget bar(int i) => FractionallySizedBox(
      widthFactor: widths[(i + index) % widths.length],
      child: const ScootSkeleton(height: 12),
    );
    return Container(
      height: ScootSize.tableRow,
      decoration: BoxDecoration(
        border: index == 0 ? null : Border(top: BorderSide(color: c.hair)),
      ),
      child: Row(
        children: <Widget>[
          if (phone)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Align(alignment: Alignment.centerLeft, child: bar(0)),
              ),
            )
          else
            for (int i = 0; i < columns.length; i++) _cell(columns[i], bar(i)),
        ],
      ),
    );
  }

  Widget _phoneFields(BuildContext context, ScootColors c, T row) {
    final TextStyle style = ScootType.body.copyWith(color: c.ink);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final ScootTableColumn<T> column in columns)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 104,
                    child: Text(
                      column.label,
                      style: ScootType.tableHead.copyWith(
                        color: c.tableHeadText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: DefaultTextStyle.merge(
                        style: column.numeric
                            ? style.copyWith(fontFeatures: ScootType.tabular)
                            : style,
                        child: column.cell(context, row),
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

  Widget _row(
    BuildContext context,
    ScootColors c,
    T row,
    int index,
    bool phone,
  ) {
    final bool selected = isSelected?.call(row) ?? false;
    final TextStyle style = ScootType.body.copyWith(color: c.ink);
    final Widget cells = phone
        ? _phoneFields(context, c, row)
        : Row(
            children: <Widget>[
              for (final ScootTableColumn<T> column in columns)
                _cell(
                  column,
                  DefaultTextStyle.merge(
                    style: column.numeric
                        ? style.copyWith(fontFeatures: ScootType.tabular)
                        : style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: column.cell(context, row),
                  ),
                ),
            ],
          );
    return Semantics(
      selected: selected,
      button: onRowTap != null,
      label: rowLabel?.call(row),
      child: Material(
        color: selected ? c.brandTint : c.card,
        child: InkWell(
          onTap: onRowTap == null ? null : () => onRowTap!(row),
          hoverColor: c.hair,
          focusColor: c.brandTint,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                top: index == 0 ? BorderSide.none : BorderSide(color: c.hair),
                left: BorderSide(
                  color: selected ? c.brand : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: cells,
          ),
        ),
      ),
    );
  }

  Widget _footer(ScootColors c, int shownCount) {
    final String count = countLabel ?? '$shownCount rows';
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.hair)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '$count · $pageSize per page${live ? ' · live' : ''}',
              style: ScootType.small.copyWith(color: c.muted),
            ),
          ),
          if (hasMore)
            OutlinedButton.icon(
              onPressed: loadingMore ? null : onLoadMore,
              icon: loadingMore
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(ScootIcons.expandMore, size: 18),
              label: Text(loadingMore ? 'Loading' : 'Load $pageSize more'),
            ),
        ],
      ),
    );
  }
}
