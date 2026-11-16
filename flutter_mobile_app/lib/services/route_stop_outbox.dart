import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'project_local_store.dart';

import '../models/route_stop_lifecycle_event.dart';
import '../models/work_session.dart';

class RouteStopOutbox {
  RouteStopOutbox({String? projectId})
    : _store = ProjectLocalStore(projectId: projectId);

  final ProjectLocalStore _store;
  static const String quarantineKey = 'route_stop_outbox_quarantine_v1';

  static final Map<String, Future<void>> _sessionTails =
      <String, Future<void>>{};
  static Future<void> _storeTail = Future<void>.value();

  Future<T> serializeSession<T>(
    WorkSession session,
    Future<T> Function() action,
  ) async {
    final String key =
        '${_store.projectId}|${session.uid}|${session.sessionId}|${session.generation}';
    final Future<void> previous = _sessionTails[key] ?? Future<void>.value();
    final Completer<void> release = Completer<void>();
    final Future<void> tail = previous
        .then<void>((_) {}, onError: (Object _) {})
        .then<void>((_) => release.future);
    _sessionTails[key] = tail;
    await previous.then<void>((_) {}, onError: (Object _) {});
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_sessionTails[key], tail)) _sessionTails.remove(key);
    }
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final Future<T> result = _storeTail.then<T>((_) => action());
    _storeTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> put(RouteStopLifecycleEvent event) => _locked<void>(() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String key = _eventKey(event);
    final List<RouteStopLifecycleEvent> rows = await _readKey(
      preferences,
      key,
      event.uid,
    );
    final int existing = rows.indexWhere(
      (RouteStopLifecycleEvent row) => row.eventId == event.eventId,
    );
    if (existing < 0) {
      rows.add(event);
    } else {
      rows[existing] = event;
    }
    await _write(preferences, key, rows);
  });

  Future<List<RouteStopLifecycleEvent>> readForUid(
    String uid, {
    String? planId,
  }) {
    final String ownerUid = uid.trim();
    if (ownerUid.isEmpty) throw ArgumentError.value(uid, 'uid');
    return _locked<List<RouteStopLifecycleEvent>>(() async {
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      final String prefix = 'route_stop_outbox_v2_${_keyPart(ownerUid)}_';
      final String scopedPrefix = _store.prefix(ownerUid);
      final List<String> keys = preferences
          .getKeys()
          .where(
            (String value) =>
                value.startsWith(prefix) ||
                value.startsWith('$scopedPrefix$prefix'),
          )
          .toList();
      final List<RouteStopLifecycleEvent> rows = <RouteStopLifecycleEvent>[];
      for (final String key in keys) {
        rows.addAll(
          await _readKey(
            preferences,
            key.startsWith(scopedPrefix)
                ? key.substring(scopedPrefix.length)
                : key,
            ownerUid,
          ),
        );
      }
      return rows
          .where(
            (RouteStopLifecycleEvent event) =>
                planId == null || event.planId == planId,
          )
          .toList(growable: false)
        ..sort(
          (RouteStopLifecycleEvent left, RouteStopLifecycleEvent right) =>
              left.workSessionGeneration != right.workSessionGeneration
              ? left.workSessionGeneration.compareTo(
                  right.workSessionGeneration,
                )
              : left.sessionEventSequence.compareTo(right.sessionEventSequence),
        );
    });
  }

  Future<void> remove(RouteStopLifecycleEvent event) => _locked<void>(() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String key = _eventKey(event);
    final List<RouteStopLifecycleEvent> rows = await _readKey(
      preferences,
      key,
      event.uid,
    );
    rows.removeWhere(
      (RouteStopLifecycleEvent row) => row.eventId == event.eventId,
    );
    if (rows.isEmpty) {
      await _store.remove(event.uid, key);
    } else {
      await _write(preferences, key, rows);
    }
  });

  Future<void> removeAll(Iterable<RouteStopLifecycleEvent> events) =>
      _locked<void>(() async {
        final SharedPreferences preferences =
            await SharedPreferences.getInstance();
        for (final MapEntry<String, List<RouteStopLifecycleEvent>> group
            in _groupByKey(events).entries) {
          final String ownerUid = group.value.first.uid;
          final Set<String> ids = group.value
              .map((RouteStopLifecycleEvent event) => event.eventId)
              .toSet();
          final List<RouteStopLifecycleEvent> rows = await _readKey(
            preferences,
            group.key,
            ownerUid,
          );
          rows.removeWhere(
            (RouteStopLifecycleEvent row) => ids.contains(row.eventId),
          );
          if (rows.isEmpty) {
            await _store.remove(ownerUid, group.key);
          } else {
            await _write(preferences, group.key, rows);
          }
        }
      });

  Future<void> updateAll(Iterable<RouteStopLifecycleEvent> events) =>
      _locked<void>(() async {
        final SharedPreferences preferences =
            await SharedPreferences.getInstance();
        for (final MapEntry<String, List<RouteStopLifecycleEvent>> group
            in _groupByKey(events).entries) {
          final List<RouteStopLifecycleEvent> rows = await _readKey(
            preferences,
            group.key,
            group.value.first.uid,
          );
          bool changed = false;
          for (final RouteStopLifecycleEvent event in group.value) {
            final int existing = rows.indexWhere(
              (RouteStopLifecycleEvent row) => row.eventId == event.eventId,
            );
            if (existing < 0) continue;
            rows[existing] = event;
            changed = true;
          }
          if (changed) await _write(preferences, group.key, rows);
        }
      });

  Map<String, List<RouteStopLifecycleEvent>> _groupByKey(
    Iterable<RouteStopLifecycleEvent> events,
  ) {
    final Map<String, List<RouteStopLifecycleEvent>> groups =
        <String, List<RouteStopLifecycleEvent>>{};
    for (final RouteStopLifecycleEvent event in events) {
      groups
          .putIfAbsent(_eventKey(event), () => <RouteStopLifecycleEvent>[])
          .add(event);
    }
    return groups;
  }

  Future<void> update(RouteStopLifecycleEvent event) => _locked<void>(() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String key = _eventKey(event);
    final List<RouteStopLifecycleEvent> rows = await _readKey(
      preferences,
      key,
      event.uid,
    );
    final int existing = rows.indexWhere(
      (RouteStopLifecycleEvent row) => row.eventId == event.eventId,
    );
    if (existing < 0) return;
    rows[existing] = event;
    await _write(preferences, key, rows);
  });

  String _eventKey(RouteStopLifecycleEvent event) => _key(
    event.uid,
    event.planId,
    event.workSessionId,
    event.workSessionGeneration,
  );

  String _key(String uid, String planId, String sessionId, int generation) =>
      'route_stop_outbox_v2_${_keyPart(uid)}_${_keyPart(planId)}_'
      '${_keyPart(sessionId)}_$generation';

  String _keyPart(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  Future<List<RouteStopLifecycleEvent>> _readKey(
    SharedPreferences preferences,
    String key,
    String ownerUid,
  ) async {
    final String? encoded = await _store.read(
      ownerUid,
      key.startsWith(_store.prefix(ownerUid))
          ? key.substring(_store.prefix(ownerUid).length)
          : key,
      legacyKey: key.startsWith(_store.prefix(ownerUid)) ? null : key,
    );
    if (encoded == null) return <RouteStopLifecycleEvent>[];
    Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! List) {
      if (await _quarantine(preferences, key, encoded, ownerUid)) {
        await _store.remove(ownerUid, key);
      }
      return <RouteStopLifecycleEvent>[];
    }
    final List<RouteStopLifecycleEvent> rows = <RouteStopLifecycleEvent>[];
    final List<Object?> rejected = <Object?>[];
    for (final Object? item in decoded) {
      final RouteStopLifecycleEvent? event = RouteStopLifecycleEvent.tryParse(
        item,
      );
      if (event == null || event.uid != ownerUid) {
        rejected.add(item);
      } else {
        rows.add(event);
      }
    }
    if (rejected.isNotEmpty &&
        await _quarantine(preferences, key, jsonEncode(rejected), ownerUid)) {
      if (rows.isEmpty) {
        await _store.remove(ownerUid, key);
      } else {
        await _write(preferences, key, rows);
      }
    }
    return rows;
  }

  Future<bool> _quarantine(
    SharedPreferences preferences,
    String key,
    String raw,
    String ownerUid,
  ) async {
    await ProjectLocalStore.recoverLegacyKey(_store.key(ownerUid, key));
    await preferences.reload();
    if (preferences.containsKey(_store.key(ownerUid, key))) {
      throw StateError(
        'Invalid queued work could not be preserved for recovery.',
      );
    }
    return true;
  }

  Future<void> _write(
    SharedPreferences preferences,
    String key,
    List<RouteStopLifecycleEvent> rows,
  ) async {
    if (rows.isEmpty) return;
    await _store.write(
      rows.first.uid,
      key,
      jsonEncode(rows.map((event) => event.toJson()).toList(growable: false)),
    );
  }
}
