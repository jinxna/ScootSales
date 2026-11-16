import 'package:flutter/foundation.dart';

import '../../utils/fuzzy_text.dart';
import 'catalogue_column.dart';

enum CatalogueDensity { compact, comfortable }

class CataloguePreset<T> {
  const CataloguePreset({
    required this.id,
    required this.label,
    required this.test,
  });

  final String id;
  final String label;
  final bool Function(T row) test;
}

class CatalogueViewState<T> extends ChangeNotifier {
  String query = '';
  final Map<String, Set<String>> filters = <String, Set<String>>{};
  String? sortColumnId;
  bool sortAscending = true;
  Set<String> hiddenColumnIds = <String>{};
  CatalogueDensity density = CatalogueDensity.compact;
  String presetId = 'all';
  final Set<String> selectedIds = <String>{};

  String? activeId;

  bool showingCloseMatches = false;

  bool get hasActiveFilters =>
      presetId != 'all' || filters.values.any((Set<String> v) => v.isNotEmpty);

  void setQuery(String value) {
    final String next = value.trim().toLowerCase();
    if (next == query) return;
    query = next;
    notifyListeners();
  }

  void setFilter(String key, Set<String> values) {
    if (values.isEmpty) {
      filters.remove(key);
    } else {
      filters[key] = Set<String>.of(values);
    }
    notifyListeners();
  }

  void clearFilters() {
    filters.clear();
    presetId = 'all';
    notifyListeners();
  }

  void setPreset(String id) {
    presetId = id;
    notifyListeners();
  }

  void cycleSort(String columnId) {
    if (sortColumnId != columnId) {
      sortColumnId = columnId;
      sortAscending = true;
    } else if (sortAscending) {
      sortAscending = false;
    } else {
      sortColumnId = null;
      sortAscending = true;
    }
    notifyListeners();
  }

  void setDensity(CatalogueDensity value) {
    if (density == value) return;
    density = value;
    notifyListeners();
  }

  void setHiddenColumns(Set<String> ids) {
    hiddenColumnIds = Set<String>.of(ids);
    notifyListeners();
  }

  void toggleSelected(String id) {
    if (!selectedIds.remove(id)) selectedIds.add(id);
    notifyListeners();
  }

  void setSelection(Iterable<String> ids) {
    selectedIds
      ..clear()
      ..addAll(ids);
    notifyListeners();
  }

  void clearSelection() {
    if (selectedIds.isEmpty) return;
    selectedIds.clear();
    notifyListeners();
  }

  void setActive(String? id) {
    if (activeId == id) return;
    activeId = id;
    notifyListeners();
  }

  void moveActive(List<String> ids, int delta) {
    if (ids.isEmpty) return;
    final int at = activeId == null ? -1 : ids.indexOf(activeId!);
    final int next = at < 0
        ? (delta > 0 ? 0 : ids.length - 1)
        : (at + delta).clamp(0, ids.length - 1);
    setActive(ids[next]);
  }

  List<T> apply(
    List<T> rows, {
    required String Function(T row) idOf,
    required String Function(T row) searchBlob,
    required Map<String, String Function(T row)> filterValue,
    required List<CatalogueColumn<T>> columns,
    Comparator<T>? defaultSort,
    List<CataloguePreset<T>> presets = const [],
  }) {
    CataloguePreset<T>? preset;
    for (final CataloguePreset<T> p in presets) {
      if (p.id == presetId) preset = p;
    }
    bool passesFilters(T row) {
      if (preset != null && !preset.test(row)) return false;
      for (final MapEntry<String, Set<String>> f in filters.entries) {
        final String Function(T)? read = filterValue[f.key];
        if (read != null &&
            f.value.isNotEmpty &&
            !f.value.contains(read(row))) {
          return false;
        }
      }
      return true;
    }

    final List<T> filtered = rows.where(passesFilters).toList();
    List<T> out = query.isEmpty
        ? filtered
        : filtered.where((T row) => searchBlob(row).contains(query)).toList();
    showingCloseMatches = false;
    if (query.isNotEmpty && out.isEmpty) {
      out = filtered
          .where((T row) => fuzzyTextMatches(searchBlob(row), query))
          .toList();
      showingCloseMatches = out.isNotEmpty;
    }

    CatalogueColumn<T>? sortColumn;
    for (final CatalogueColumn<T> c in columns) {
      if (c.id == sortColumnId) sortColumn = c;
    }
    if (sortColumn?.sortKey != null) {
      final Comparable<Object> Function(T) key = sortColumn!.sortKey!;
      out.sort((T a, T b) {
        final int c = _compare(key(a), key(b));
        return sortAscending ? c : -c;
      });
    } else if (defaultSort != null) {
      out.sort(defaultSort);
    }

    final Set<String> visible = out.map(idOf).toSet();
    selectedIds.removeWhere((String id) => !visible.contains(id));
    if (activeId != null && !visible.contains(activeId)) activeId = null;
    return out;
  }

  static int _compare(Comparable<Object> a, Comparable<Object> b) {
    try {
      return a.compareTo(b);
    } catch (_) {
      return a.toString().compareTo(b.toString());
    }
  }
}
