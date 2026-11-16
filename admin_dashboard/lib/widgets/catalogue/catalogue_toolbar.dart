import 'package:flutter/material.dart';

import 'package:scoot_design/scoot_design.dart';

import '../../theme/dso_theme.dart';
import '../dso_filter_controls.dart';
import 'catalogue_column.dart';
import 'catalogue_view_state.dart';

class CatalogueFilterMenu {
  const CatalogueFilterMenu({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
}

class CatalogueToolbar<T> extends StatefulWidget {
  const CatalogueToolbar({
    super.key,
    required this.search,
    required this.searchHint,
    required this.filters,
    required this.presets,
    required this.presetId,
    required this.onPreset,
    required this.columns,
    required this.hiddenColumnIds,
    required this.onColumns,
    required this.density,
    required this.onDensity,
    this.searchFocus,
    this.onClearFilters,
    this.hasActiveFilters = false,
    this.resultSummary,
  });

  final TextEditingController search;
  final FocusNode? searchFocus;
  final String searchHint;
  final List<CatalogueFilterMenu> filters;
  final List<CataloguePreset<T>> presets;
  final String presetId;
  final ValueChanged<String> onPreset;
  final List<CatalogueColumn<T>> columns;
  final Set<String> hiddenColumnIds;
  final ValueChanged<Set<String>> onColumns;
  final CatalogueDensity density;
  final ValueChanged<CatalogueDensity> onDensity;
  final VoidCallback? onClearFilters;
  final bool hasActiveFilters;

  final String? resultSummary;

  @override
  CatalogueToolbarState<T> createState() => CatalogueToolbarState<T>();
}

class CatalogueToolbarState<T> extends State<CatalogueToolbar<T>> {
  final Map<String, MenuController> _menuControllers =
      <String, MenuController>{};

  MenuController _menuController(String key) =>
      _menuControllers.putIfAbsent(key, MenuController.new);

  bool closeMenus() {
    bool closed = false;
    for (final MenuController controller in _menuControllers.values) {
      if (controller.isOpen) {
        controller.close();
        closed = true;
      }
    }
    return closed;
  }

  @override
  Widget build(BuildContext context) {
    final CatalogueToolbar<T> toolbar = widget;
    final DsoColors dso = context.dso;
    final Widget searchField = DsoFilterSearchField(
      controller: toolbar.search,
      focusNode: toolbar.searchFocus,
      hintText: toolbar.searchHint,
      shortcutKey: '/',
      width: 368,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: DsoFilterMetrics.gap,
          runSpacing: DsoFilterMetrics.gap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            searchField,
            for (int i = 0; i < toolbar.filters.length; i++)
              _FilterButton(
                filter: toolbar.filters[i],
                controller: _menuController('filter-$i'),
              ),
            if (toolbar.hasActiveFilters && toolbar.onClearFilters != null)
              TextButton(
                onPressed: toolbar.onClearFilters,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, DsoFilterMetrics.height),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                    fontSize: DsoFilterMetrics.fontSize,
                  ),
                ),
                child: const Text('Clear search and filters'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            Widget heading(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                text,
                style: ScootType.tableHead.copyWith(
                  color: ScootColors.of(context).tableHeadText,
                ),
              ),
            );
            final List<CatalogueColumn<T>> hideable = toolbar.columns
                .where((CatalogueColumn<T> c) => c.hideable)
                .toList();
            final bool hasOptions =
                toolbar.presets.length > 1 || hideable.isNotEmpty;
            final Widget optionsMenu = _Menu(
              controller: _menuController('options'),
              label: 'View options',
              active:
                  toolbar.presetId != toolbar.presets.first.id ||
                  toolbar.hiddenColumnIds.isNotEmpty,
              leading: ScootIcons.layers,
              children: <Widget>[
                heading('View'),
                for (final CataloguePreset<T> p in toolbar.presets)
                  MenuItemButton(
                    leadingIcon: Icon(
                      p.id == toolbar.presetId ? ScootIcons.check : null,
                      size: 16,
                    ),
                    onPressed: () => toolbar.onPreset(p.id),
                    child: Text(p.label),
                  ),
                if (hideable.isNotEmpty) heading('Columns'),
                for (final CatalogueColumn<T> c in hideable)
                  CheckboxMenuButton(
                    closeOnActivate: false,
                    value: !toolbar.hiddenColumnIds.contains(c.id),
                    onChanged: (bool? on) {
                      final Set<String> next = Set<String>.of(
                        toolbar.hiddenColumnIds,
                      );
                      on == true ? next.remove(c.id) : next.add(c.id);
                      toolbar.onColumns(next);
                    },
                    child: Text(c.label),
                  ),
                heading('Row height'),
                for (final CatalogueDensity d in CatalogueDensity.values)
                  MenuItemButton(
                    leadingIcon: Icon(
                      d == toolbar.density ? ScootIcons.check : null,
                      size: 16,
                    ),
                    onPressed: () => toolbar.onDensity(d),
                    child: Text(
                      d == CatalogueDensity.compact ? 'Compact' : 'Comfortable',
                    ),
                  ),
              ],
            );
            final Widget? summaryText = toolbar.resultSummary == null
                ? null
                : Semantics(
                    container: true,
                    excludeSemantics: true,
                    label: toolbar.resultSummary,
                    child: Text(
                      toolbar.resultSummary!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: dso.muted),
                    ),
                  );
            final Widget keyboardHint = Tooltip(
              message:
                  '/ search   N new   Up / Down move   Enter open   '
                  'Space select   Esc close',
              child: Semantics(
                label: 'Keyboard shortcuts',
                child: Icon(
                  ScootIcons.help,
                  size: 18,
                  color: dso.subtle,
                ),
              ),
            );
            if (constraints.maxWidth >= 720) {
              return Row(
                children: <Widget>[
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        if (summaryText != null) ...<Widget>[
                          Flexible(child: summaryText),
                          const SizedBox(width: 6),
                        ],
                        keyboardHint,
                      ],
                    ),
                  ),
                  if (hasOptions) optionsMenu,
                ],
              );
            }
            return Wrap(
              spacing: DsoFilterMetrics.gap,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                ?summaryText,
                if (hasOptions) optionsMenu,
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({
    required this.controller,
    required this.label,
    required this.children,
    this.active = false,
    this.leading,
  });

  final MenuController controller;
  final String label;
  final bool active;
  final IconData? leading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: controller,
      menuChildren: children,
      builder:
          (BuildContext context, MenuController menuController, Widget? _) {
            return DsoFilterButton(
              label: label,
              active: active,
              icon: leading,
              onPressed: () => menuController.isOpen
                  ? menuController.close()
                  : menuController.open(),
            );
          },
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.filter, required this.controller});

  final CatalogueFilterMenu filter;
  final MenuController controller;

  @override
  Widget build(BuildContext context) {
    final int n = filter.selected.length;
    return _Menu(
      controller: controller,
      label: n == 0 ? filter.label : '${filter.label} · $n',
      active: n > 0,
      children: <Widget>[
        for (final String option in filter.options)
          CheckboxMenuButton(
            closeOnActivate: false,
            value: filter.selected.contains(option),
            onChanged: (bool? on) {
              final Set<String> next = Set<String>.of(filter.selected);
              on == true ? next.add(option) : next.remove(option);
              filter.onChanged(next);
            },
            child: Text(option),
          ),
      ],
    );
  }
}
