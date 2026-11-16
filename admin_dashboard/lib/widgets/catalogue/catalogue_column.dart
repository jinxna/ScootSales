import 'package:flutter/widgets.dart';

class CatalogueColumn<T> {
  const CatalogueColumn({
    required this.id,
    required this.label,
    required this.cell,
    this.width = 120,
    this.flex = 0,
    this.sortKey,
    this.numeric = false,
    this.hideable = true,
    this.interactive = false,
    this.visibleByDefault = true,
    this.hideBelowWidth,
    this.csv,
  });

  final String id;
  final String label;

  final double width;

  final int flex;
  final Widget Function(BuildContext context, T row) cell;

  final Comparable<Object> Function(T row)? sortKey;

  final bool numeric;
  final bool hideable;
  final bool interactive;
  final bool visibleByDefault;

  final double? hideBelowWidth;

  final String Function(T row)? csv;

  String csvValue(T row) =>
      csv != null ? csv!(row) : (sortKey?.call(row).toString() ?? '');
}
