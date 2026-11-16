import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/forecast_snapshot_storage.dart';
import 'dso_theme.dart';

class DsoThemeController extends ValueNotifier<DsoAppearance> {
  DsoThemeController._() : super(const DsoAppearance());

  static final DsoThemeController instance = DsoThemeController._();

  final ForecastSnapshotStorage _storage = createForecastSnapshotStorage();
  String? _uid;

  static String storageKeyFor(String uid) => 'scoot.admin.appearance.$uid';

  void useAccount(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    value = uid == null ? const DsoAppearance() : _read(uid);
  }

  void setAccent(Color accent) {
    _update(value.copyWith(accent: accent));
  }

  void setMode(DsoThemeMode mode) {
    _update(value.copyWith(mode: mode));
  }

  void setDensity(DsoDensity density) {
    _update(value.copyWith(density: density));
  }

  void _update(DsoAppearance next) {
    value = next;
    final String? uid = _uid;
    if (uid == null) return;
    try {
      _storage.write(
        storageKeyFor(uid),
        jsonEncode(<String, Object>{
          'accent': next.accent.toARGB32(),
          'mode': next.mode.name,
          'density': next.density.name,
        }),
      );
    } catch (_) {}
  }

  DsoAppearance _read(String uid) {
    const DsoAppearance fallback = DsoAppearance();
    try {
      final String? raw = _storage.read(storageKeyFor(uid));
      if (raw == null) return fallback;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return fallback;
      final Object? accent = decoded['accent'];
      return DsoAppearance(
        accent: accent is int ? Color(accent) : fallback.accent,
        mode: DsoThemeMode.values.asNameMap()[decoded['mode']] ?? fallback.mode,
        density:
            DsoDensity.values.asNameMap()[decoded['density']] ??
            fallback.density,
      );
    } catch (_) {
      return fallback;
    }
  }
}
