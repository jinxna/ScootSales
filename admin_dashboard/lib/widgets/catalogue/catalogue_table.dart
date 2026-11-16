import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scoot_design/scoot_design.dart';

import '../../theme/dso_theme.dart';
import '../horizontal_scroll_cue.dart';
import 'catalogue_column.dart';
import 'catalogue_view_state.dart';

class CatalogueRowAction<T> {
  const CatalogueRowAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final void Function(T row) onPressed;
  final bool destructive;
}

sealed class _Item<T> {
  const _Item();
}

class _GroupItem<T> extends _Item<T> {
  const _GroupItem(this.title, this.count);
  final String title;
  final int count;
}

class _RowItem<T> extends _Item<T> {
  const _RowItem(this.row);
  final T row;
}

class CatalogueTable<T> extends StatefulWidget {
  const CatalogueTable({
    super.key,
    required this.rows,
    required this.idOf,
    required this.labelOf,
    required this.columns,
    required this.state,
    this.onOpen,
    this.rowActions,
    this.groupOf,
    this.selectable = true,
    this.semanticsLabelPrefix = 'Row',
  });

  final List<T> rows;
  final String Function(T row) idOf;

  final String Function(T row) labelOf;
  final List<CatalogueColumn<T>> columns;
  final CatalogueViewState<T> state;
  final ValueChanged<T>? onOpen;
  final List<CatalogueRowAction<T>> Function(T row)? rowActions;

  final String Function(T row)? groupOf;
  final bool selectable;
  final String semanticsLabelPrefix;

  @override
  State<CatalogueTable<T>> createState() => _CatalogueTableState<T>();
}

class _CatalogueTableState<T> extends State<CatalogueTable<T>> {
  static const double _checkWidth = 44;
  static const double _actionsWidth = 128;
  static const double _groupHeight = 32;
  static const double _headerHeight = ScootSize.tableHeader;

  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  String? _hoveredId;
  String? _lastActive;

  double get _rowHeight =>
      widget.state.density == CatalogueDensity.compact ? 56 : 64;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void didUpdateWidget(CatalogueTable<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onState);
      widget.state.addListener(_onState);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    final String? active = widget.state.activeId;
    if (active != null && active != _lastActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(active));
    }
    _lastActive = active;
  }

  void _reveal(String id) {
    if (!_vertical.hasClients) return;
    final List<_Item<T>> items = _items();
    double top = 0;
    for (final _Item<T> item in items) {
      final double h = item is _GroupItem<T> ? _groupHeight : _rowHeight;
      if (item is _RowItem<T> && widget.idOf(item.row) == id) {
        final double viewport = _vertical.position.viewportDimension;
        final double offset = _vertical.offset;
        if (top < offset) {
          _vertical.jumpTo(top);
        } else if (top + h > offset + viewport) {
          _vertical.jumpTo(top + h - viewport);
        }
        return;
      }
      top += h;
    }
  }

  List<_Item<T>> _items() {
    final bool grouped =
        widget.groupOf != null && widget.state.sortColumnId == null;
    if (!grouped) {
      return widget.rows.map<_Item<T>>((T r) => _RowItem<T>(r)).toList();
    }
    final Map<String, int> counts = <String, int>{};
    for (final T row in widget.rows) {
      counts.update(widget.groupOf!(row), (int n) => n + 1, ifAbsent: () => 1);
    }
    final List<_Item<T>> out = <_Item<T>>[];
    String? current;
    for (final T row in widget.rows) {
      final String group = widget.groupOf!(row);
      if (group != current) {
        current = group;
        out.add(_GroupItem<T>(group, counts[group]!));
      }
      out.add(_RowItem<T>(row));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if (box.maxWidth < 720) return _stacked(context);
        final List<CatalogueColumn<T>> cols = widget.columns
            .where(
              (CatalogueColumn<T> c) =>
                  !widget.state.hiddenColumnIds.contains(c.id) &&
                  (c.hideBelowWidth == null ||
                      box.maxWidth >= c.hideBelowWidth!),
            )
            .toList();
        final double lead = widget.selectable ? _checkWidth : 12;
        final double minTotal =
            lead +
            _actionsWidth +
            cols.fold<double>(
              0,
              (double s, CatalogueColumn<T> c) => s + c.width,
            );
        final double tableWidth = math.max(minTotal, box.maxWidth);
        final int flexTotal = cols.fold<int>(
          0,
          (int s, CatalogueColumn<T> c) => s + c.flex,
        );
        final double spare = tableWidth - minTotal;
        final List<double> widths = <double>[
          for (final CatalogueColumn<T> c in cols)
            c.width + (flexTotal == 0 ? 0 : spare * c.flex / flexTotal),
        ];
        final List<_Item<T>> items = _items();
        return HorizontalScrollCue(
          controller: _horizontal,
          child: SizedBox(
            width: tableWidth,
            height: box.maxHeight,
            child: Column(
              children: <Widget>[
                _header(context, cols, widths, lead),
                Expanded(
                  child: Scrollbar(
                    controller: _vertical,
                    child: ListView.builder(
                      controller: _vertical,
                      padding: EdgeInsets.zero,
                      itemCount: items.length,
                      itemBuilder: (BuildContext context, int i) {
                        final _Item<T> item = items[i];
                        if (item is _GroupItem<T>) {
                          return _group(context, item);
                        }
                        return _row(
                          context,
                          (item as _RowItem<T>).row,
                          cols,
                          widths,
                          lead,
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(
    BuildContext context,
    List<CatalogueColumn<T>> cols,
    List<double> widths,
    double lead,
  ) {
    final Set<String> selected = widget.state.selectedIds;
    final bool all =
        widget.rows.isNotEmpty && selected.length == widget.rows.length;
    final ScootColors c = ScootColors.of(context);
    return Container(
      height: _headerHeight,
      decoration: BoxDecoration(
        color: c.tableHead,
        border: Border(bottom: BorderSide(color: c.hair)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox(width: lead + (cols.isEmpty ? 0 : widths[0])),
              ScrollsBehindStickyColumn(
                child: Row(
                  children: <Widget>[
                    for (int i = 1; i < cols.length; i++)
                      SizedBox(
                        width: widths[i],
                        child: _headerCell(context, cols[i]),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: _actionsWidth),
            ],
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: StickyColumnCell(
              background: c.tableHead,
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: lead,
                    child: widget.selectable
                        ? Center(
                            child: Semantics(
                              label: 'Select all rows',
                              child: Checkbox(
                                tristate: true,
                                value: all
                                    ? true
                                    : (selected.isEmpty ? false : null),
                                onChanged: (_) => widget.state.setSelection(
                                  all
                                      ? <String>[]
                                      : widget.rows.map(widget.idOf),
                                ),
                              ),
                            ),
                          )
                        : null,
                  ),
                  if (cols.isNotEmpty)
                    SizedBox(
                      width: widths[0],
                      child: _headerCell(context, cols[0]),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerCell(BuildContext context, CatalogueColumn<T> c) {
    final DsoColors dso = context.dso;
    final bool sorted = widget.state.sortColumnId == c.id;
    final Widget label = Row(
      mainAxisAlignment: c.numeric
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: Text(
            c.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ScootType.tableHead.copyWith(
              color: sorted
                  ? ScootColors.of(context).ink
                  : ScootColors.of(context).tableHeadText,
            ),
          ),
        ),
        if (sorted)
          Icon(
            widget.state.sortAscending
                ? ScootIcons.expandLess
                : ScootIcons.expandMore,
            size: 14,
            color: dso.ink,
          ),
      ],
    );
    if (c.sortKey == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: label,
      );
    }
    return Semantics(
      button: true,
      label: 'Sort by ${c.label}',
      excludeSemantics: true,
      onTap: () => widget.state.cycleSort(c.id),
      child: InkWell(
        onTap: () => widget.state.cycleSort(c.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(
            alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
            child: label,
          ),
        ),
      ),
    );
  }

  Widget _group(BuildContext context, _GroupItem<T> item) {
    return Container(
      height: _groupHeight,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: ScootColors.of(context).tableHead,
      child: Text(
        '${item.title.isEmpty ? 'No group' : item.title} · ${item.count}',
        style: ScootType.tableHead.copyWith(
          color: ScootColors.of(context).tableHeadText,
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    T row,
    List<CatalogueColumn<T>> cols,
    List<double> widths,
    double lead,
  ) {
    final DsoColors dso = context.dso;
    final String id = widget.idOf(row);
    final bool selected = widget.state.selectedIds.contains(id);
    final bool active = widget.state.activeId == id;
    final bool showActions = _hoveredId == id || active;
    final List<CatalogueRowAction<T>> actions =
        widget.rowActions?.call(row) ?? <CatalogueRowAction<T>>[];
    final String label = widget.labelOf(row);
    final ScootColors c = ScootColors.of(context);
    final Color bg = selected ? c.brandTint : (showActions ? c.hair : c.card);
    Widget cell(int i) => SizedBox(
      width: widths[i],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: cols[i].numeric
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: DefaultTextStyle.merge(
            style: ScootType.body.copyWith(
              color: c.ink,
              fontFeatures: cols[i].numeric ? ScootType.tabular : null,
            ),
            child: cols[i].interactive
                ? cols[i].cell(context, row)
                : ExcludeSemantics(child: cols[i].cell(context, row)),
          ),
        ),
      ),
    );
    void open() {
      widget.state.setActive(id);
      widget.onOpen!(row);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredId = id),
      onExit: (_) {
        if (_hoveredId == id) setState(() => _hoveredId = null);
      },
      child: Container(
        height: _rowHeight,
        decoration: BoxDecoration(
          color: bg,
          border: Border(bottom: BorderSide(color: c.hair)),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Semantics(
                    button: widget.onOpen != null,
                    label: '${widget.semanticsLabelPrefix} $label',
                    onTap: widget.onOpen == null ? null : open,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onTap: widget.onOpen == null ? null : open,
                      child: Row(
                        children: <Widget>[
                          SizedBox(
                            width: lead + (cols.isEmpty ? 0 : widths[0]),
                          ),
                          ScrollsBehindStickyColumn(
                            child: Row(
                              children: <Widget>[
                                for (int j = 1; j < cols.length; j++) cell(j),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: StickyColumnCell(
                      background: bg,
                      child: Stack(
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              SizedBox(
                                width: lead,
                                child: widget.selectable
                                    ? Center(
                                        child: Semantics(
                                          label: 'Select $label',
                                          child: Checkbox(
                                            value: selected,
                                            onChanged: (_) =>
                                                widget.state.toggleSelected(id),
                                          ),
                                        ),
                                      )
                                    : null,
                              ),
                              if (cols.isNotEmpty)
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  excludeFromSemantics: true,
                                  onTap: widget.onOpen == null ? null : open,
                                  child: SizedBox(
                                    height: _rowHeight,
                                    child: cell(0),
                                  ),
                                ),
                            ],
                          ),
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: 3,
                            child: ColoredBox(
                              color: active ? c.brand : Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: _actionsWidth,
              child: showActions && actions.isNotEmpty
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        for (final CatalogueRowAction<T> a in actions)
                          IconButton(
                            tooltip: '${a.label} $label',
                            visualDensity: VisualDensity.compact,
                            iconSize: 18,
                            color: a.destructive ? dso.dangerText : dso.body,
                            onPressed: () => a.onPressed(row),
                            icon: Icon(a.icon),
                          ),
                      ],
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _stacked(BuildContext context) {
    final DsoColors dso = context.dso;
    final List<CatalogueColumn<T>> cols = widget.columns
        .where(
          (CatalogueColumn<T> c) =>
              !widget.state.hiddenColumnIds.contains(c.id),
        )
        .toList();
    final List<_Item<T>> items = _items();
    return ListView.builder(
      controller: _vertical,
      itemCount: items.length,
      itemBuilder: (BuildContext context, int i) {
        final _Item<T> item = items[i];
        if (item is _GroupItem<T>) return _group(context, item);
        final T row = (item as _RowItem<T>).row;
        final String label = widget.labelOf(row);
        final List<CatalogueRowAction<T>> actions =
            widget.rowActions?.call(row) ?? <CatalogueRowAction<T>>[];
        final List<CatalogueColumn<T>> middle = cols
            .skip(1)
            .take(math.max(0, math.min(2, cols.length - 2)))
            .toList();
        final VoidCallback? open = widget.onOpen == null
            ? null
            : () => widget.onOpen!(row);
        return Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: dso.hairline)),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Semantics(
                  button: open != null,
                  label: '${widget.semanticsLabelPrefix} $label',
                  excludeSemantics: true,
                  onTap: open,
                  child: InkWell(
                    onTap: open,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              DefaultTextStyle.merge(
                                style: TextStyle(fontSize: 14, color: dso.ink),
                                child: cols.first.cell(context, row),
                              ),
                              const SizedBox(height: 2),
                              Wrap(
                                spacing: 12,
                                children: <Widget>[
                                  for (final CatalogueColumn<T> c in middle)
                                    DefaultTextStyle.merge(
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: dso.muted,
                                      ),
                                      child: c.cell(context, row),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (cols.length > 1) cols.last.cell(context, row),
                      ],
                    ),
                  ),
                ),
              ),
              if (actions.isNotEmpty)
                PopupMenuButton<CatalogueRowAction<T>>(
                  tooltip: 'Actions for $label',
                  icon: const Icon(ScootIcons.more, size: 20),
                  onSelected: (CatalogueRowAction<T> a) => a.onPressed(row),
                  itemBuilder: (BuildContext _) =>
                      <PopupMenuEntry<CatalogueRowAction<T>>>[
                        for (final CatalogueRowAction<T> a in actions)
                          PopupMenuItem<CatalogueRowAction<T>>(
                            value: a,
                            child: Text(a.label),
                          ),
                      ],
                ),
            ],
          ),
        );
      },
    );
  }
}
