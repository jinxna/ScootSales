import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../app/workspace_runtime.dart';
import '../utils/order_data_utils.dart';
import 'forecast_snapshot_storage.dart';

class ForecastSnapshot {
  const ForecastSnapshot({
    required this.rows,
    required this.source,
    required this.generatedAt,
  });

  static const int schemaVersion = 1;
  static const int maxRows = 1000;
  static const int maxBytes = 512 * 1024;
  static const int maxSourceLength = 160;

  final List<Map<String, dynamic>> rows;
  final String source;
  final DateTime generatedAt;

  static ForecastSnapshot? fromRows(
    Iterable<Map<String, dynamic>> rawRows, {
    required String source,
    DateTime? generatedAt,
  }) {
    final String safeSource = source.trim();
    if (safeSource.isEmpty || safeSource.length > maxSourceLength) return null;
    if (_hasDemoToken(safeSource)) return null;

    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> raw in rawRows) {
      final Map<String, dynamic>? normalised = _normaliseRow(raw);
      if (normalised == null || isDemoRow(normalised)) continue;
      rows.add(normalised);
      if (rows.length == maxRows) break;
    }
    if (rows.isEmpty) return null;

    final DateTime timestamp = (generatedAt ?? DateTime.now()).toUtc();
    if (timestamp.year < 2000 || timestamp.year > 2200) return null;

    final List<Map<String, dynamic>> fitting = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> row in rows) {
      final List<Map<String, dynamic>> candidate = <Map<String, dynamic>>[
        ...fitting,
        row,
      ];
      final ForecastSnapshot snapshot = ForecastSnapshot(
        rows: candidate,
        source: safeSource,
        generatedAt: timestamp,
      );
      if (_encodedSize(snapshot.toMap()) > maxBytes) break;
      fitting.add(row);
    }
    if (fitting.isEmpty) return null;
    return ForecastSnapshot(
      rows: List<Map<String, dynamic>>.unmodifiable(fitting),
      source: safeSource,
      generatedAt: timestamp,
    );
  }

  static ForecastSnapshot? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> map = <String, dynamic>{
      for (final MapEntry<Object?, Object?> entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    if (map['schemaVersion'] != schemaVersion) return null;
    final Object? rawSource = map['source'];
    final Object? rawGeneratedAt = map['generatedAt'];
    final Object? rawRows = map['rows'];
    if (rawSource is! String || rawGeneratedAt is! String || rawRows is! List) {
      return null;
    }
    final DateTime? generatedAt = DateTime.tryParse(rawGeneratedAt);
    if (generatedAt == null) return null;
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final Object? rawRow in rawRows.take(maxRows)) {
      if (rawRow is! Map) return null;
      final Map<String, dynamic>? row = _normaliseRow(<String, dynamic>{
        for (final MapEntry<Object?, Object?> entry in rawRow.entries)
          if (entry.key is String) entry.key as String: entry.value,
      });
      if (row == null || isDemoRow(row)) return null;
      rows.add(row);
    }
    if (rows.isEmpty) return null;
    final ForecastSnapshot snapshot = ForecastSnapshot(
      rows: List<Map<String, dynamic>>.unmodifiable(rows),
      source: rawSource.trim(),
      generatedAt: generatedAt.toUtc(),
    );
    if (snapshot.source.isEmpty ||
        snapshot.source.length > maxSourceLength ||
        _hasDemoToken(snapshot.source) ||
        snapshot.generatedAt.year < 2000 ||
        snapshot.generatedAt.year > 2200 ||
        _encodedSize(snapshot.toMap()) > maxBytes) {
      return null;
    }
    return snapshot;
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'schemaVersion': schemaVersion,
    'source': source,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'rows': rows,
  };

  static Map<String, dynamic>? _normaliseRow(Map<String, dynamic> raw) {
    final Map<String, dynamic> result = <String, dynamic>{};
    for (final MapEntry<String, dynamic> entry in raw.entries) {
      final Object? value = _jsonSafe(entry.value);
      if (value != null || entry.value == null) result[entry.key] = value;
    }
    return result.isEmpty ? null : result;
  }

  static Object? _jsonSafe(Object? value, {int depth = 0}) {
    if (depth > 8) return null;
    if (value == null || value is String || value is bool) return value;
    if (value is num) return value.isFinite ? value : null;
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Timestamp) return value.toDate().toUtc().toIso8601String();
    if (value is Map) {
      final Map<String, dynamic> map = <String, dynamic>{};
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        if (entry.key is! String) continue;
        final Object? safe = _jsonSafe(entry.value, depth: depth + 1);
        if (safe != null || entry.value == null) {
          map[entry.key as String] = safe;
        }
      }
      return map;
    }
    if (value is Iterable) {
      return value
          .take(maxRows)
          .map((Object? item) => _jsonSafe(item, depth: depth + 1))
          .toList(growable: false);
    }
    return null;
  }

  static int _encodedSize(Map<String, dynamic> map) {
    try {
      return utf8.encode(jsonEncode(map)).length;
    } catch (_) {
      return maxBytes + 1;
    }
  }

  static bool _hasDemoToken(String source) =>
      isDemoRow(<String, dynamic>{'source': source});
}

class ForecastSnapshotCache {
  ForecastSnapshotCache({
    ForecastSnapshotStorage? storage,
    this.storageKey = storageKeyPrefix,
  }) : _storage = storage ?? createForecastSnapshotStorage();

  static const String storageKeyPrefix = 'fypa.forecast_snapshot.v1';

  final ForecastSnapshotStorage _storage;
  final String storageKey;

  static String storageKeyForScope(String scope) {
    final String normalised = scope.trim().toLowerCase();
    final String safe = normalised
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    final String bounded = safe.isEmpty
        ? 'unknown'
        : safe.substring(0, safe.length.clamp(1, 96));
    final String? workspace = WorkspaceRuntime.current?.workspace;
    return workspace == null
        ? '$storageKeyPrefix.$bounded'
        : '$storageKeyPrefix.$workspace.$bounded';
  }

  static void clearAll([ForecastSnapshotStorage? storage]) {
    try {
      final ForecastSnapshotStorage target =
          storage ?? createForecastSnapshotStorage();
      for (final String key in target.keys().toList()) {
        if (key == storageKeyPrefix || key.startsWith('$storageKeyPrefix.')) {
          target.remove(key);
        }
      }
    } catch (_) {
    }
  }

  ForecastSnapshot? read() {
    try {
      final String? encoded = _storage.read(storageKey);
      if (encoded == null || encoded.length > ForecastSnapshot.maxBytes * 2) {
        return null;
      }
      final ForecastSnapshot? snapshot = ForecastSnapshot.fromMap(
        jsonDecode(encoded),
      );
      if (snapshot == null) _storage.remove(storageKey);
      return snapshot;
    } catch (_) {
      try {
        _storage.remove(storageKey);
      } catch (_) {
      }
      return null;
    }
  }

  bool save({
    required Iterable<Map<String, dynamic>> rows,
    required String source,
    DateTime? generatedAt,
  }) {
    final ForecastSnapshot? snapshot = ForecastSnapshot.fromRows(
      rows,
      source: source,
      generatedAt: generatedAt,
    );
    if (snapshot == null) return false;
    try {
      final String encoded = jsonEncode(snapshot.toMap());
      if (utf8.encode(encoded).length > ForecastSnapshot.maxBytes) return false;
      _storage.write(storageKey, encoded);
      return true;
    } catch (_) {
      return false;
    }
  }

  void clear() {
    try {
      _storage.remove(storageKey);
    } catch (_) {
    }
  }
}
