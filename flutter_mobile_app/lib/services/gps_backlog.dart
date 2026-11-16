import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'project_local_store.dart';

class GpsBacklogFix {
  const GpsBacklogFix({
    required this.sessionId,
    required this.generation,
    required this.fixSequence,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.deviceCapturedAt,
  });

  final String sessionId;
  final int generation;
  final int fixSequence;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime deviceCapturedAt;

  String get key => '$sessionId|$generation|$fixSequence';

  String eventId(String uid) => 'session_${uid}_${sessionId}_$fixSequence';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'generation': generation,
    'fixSequence': fixSequence,
    'latitude': latitude,
    'longitude': longitude,
    'accuracyMeters': accuracyMeters,
    'deviceCapturedAt': deviceCapturedAt.toUtc().toIso8601String(),
  };

  static GpsBacklogFix? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? generation = raw['generation'];
    final Object? sequence = raw['fixSequence'];
    final Object? latitude = raw['latitude'];
    final Object? longitude = raw['longitude'];
    final Object? accuracy = raw['accuracyMeters'];
    final DateTime? capturedAt = DateTime.tryParse(
      (raw['deviceCapturedAt'] ?? '').toString(),
    )?.toUtc();
    final String sessionId = (raw['sessionId'] ?? '').toString();
    if (sessionId.isEmpty ||
        generation is! num ||
        sequence is! num ||
        latitude is! num ||
        longitude is! num ||
        accuracy is! num ||
        capturedAt == null) {
      return null;
    }
    return GpsBacklogFix(
      sessionId: sessionId,
      generation: generation.toInt(),
      fixSequence: sequence.toInt(),
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      accuracyMeters: accuracy.toDouble(),
      deviceCapturedAt: capturedAt,
    );
  }
}

class GpsBacklogStore {
  GpsBacklogStore({String? projectId})
    : _store = ProjectLocalStore(projectId: projectId);

  static const String storeName = 'gps_backlog_v2.';
  static const int maxFixesPerSession = 500;

  static Future<void> _tail = Future<void>.value();

  final ProjectLocalStore _store;
  final Map<String, Set<String>> _knownNames = <String, Set<String>>{};

  Future<T> _locked<T>(Future<T> Function() action) {
    final Future<T> result = _tail.then<T>((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<GpsBacklogFix>> readAll(String uid) =>
      _locked<List<GpsBacklogFix>>(() => _read(uid));

  Future<bool> hasAny(String uid) =>
      _locked<bool>(() async => (await _known(uid)).isNotEmpty);

  Future<void> add(String uid, GpsBacklogFix fix) => _locked<void>(() async {
    final Set<String> known = await _known(uid);
    final String name = _name(fix);
    await _store.write(uid, name, jsonEncode(fix.toJson()));
    known.add(name);
    final String sessionPrefix =
        '$storeName${fix.sessionId}.${fix.generation}.';
    final List<String> sameSession =
        known.where((String key) => key.startsWith(sessionPrefix)).toList()
          ..sort();
    if (sameSession.length > maxFixesPerSession) {
      for (final String stale in sameSession.take(
        sameSession.length - maxFixesPerSession,
      )) {
        await _store.remove(uid, stale);
        known.remove(stale);
      }
    }
  });

  Future<void> removeAll(String uid, Iterable<GpsBacklogFix> fixes) =>
      _locked<void>(() async {
        final Set<String> known = await _known(uid);
        for (final GpsBacklogFix fix in fixes) {
          final String name = _name(fix);
          if (known.remove(name)) await _store.remove(uid, name);
        }
      });

  Future<Set<String>> _known(String uid) async =>
      _knownNames[uid] ??= (await _names(uid)).toSet();

  Future<void> removeSequence(
    String uid, {
    required String sessionId,
    required int generation,
    required int fixSequence,
  }) => _locked<void>(() async {
    final String name = _nameOf(sessionId, generation, fixSequence);
    if ((await _known(uid)).remove(name)) await _store.remove(uid, name);
  });

  static String _name(GpsBacklogFix fix) =>
      _nameOf(fix.sessionId, fix.generation, fix.fixSequence);

  static String _nameOf(String sessionId, int generation, int fixSequence) =>
      '$storeName$sessionId.$generation.'
      '${fixSequence.toString().padLeft(12, '0')}';

  Future<List<String>> _names(String uid) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String owner = _store.prefix(uid);
    final String start = '$owner$storeName';
    return prefs
        .getKeys()
        .where((String key) => key.startsWith(start))
        .map((String key) => key.substring(owner.length))
        .toList()
      ..sort();
  }

  Future<List<GpsBacklogFix>> _read(String uid) async {
    final List<GpsBacklogFix> rows = <GpsBacklogFix>[];
    final List<String> names = await _names(uid);
    _knownNames[uid] = names.toSet();
    for (final String name in names) {
      final String? encoded = await _store.read(uid, name);
      if (encoded == null) continue;
      try {
        final GpsBacklogFix? fix = GpsBacklogFix.tryParse(jsonDecode(encoded));
        if (fix != null) rows.add(fix);
      } on FormatException {
        continue;
      }
    }
    return rows;
  }
}

class GpsLiveSnapshot {
  const GpsLiveSnapshot({
    required this.sessionId,
    required this.generation,
    required this.status,
    required this.lastFixSequence,
    this.deviceCapturedAt,
    this.startedAt,
    this.endedAt,
  });

  final String sessionId;
  final int generation;
  final String status;
  final int lastFixSequence;
  final DateTime? deviceCapturedAt;
  final DateTime? startedAt;
  final DateTime? endedAt;
}

class GpsBacklogPlan {
  const GpsBacklogPlan({
    required this.write,
    required this.drop,
    this.dropReasons = const <String, String>{},
  });

  final List<GpsBacklogFix> write;
  final List<GpsBacklogFix> drop;
  final Map<String, String> dropReasons;
}

const int gpsBacklogWritesPerFlush = 200;
const int gpsBacklogSequenceWindow = 500;
const Duration gpsBacklogMaxAge = Duration(days: 7, hours: -1);
const Duration gpsBacklogBeforeStart = Duration(minutes: 10);
const Duration gpsBacklogAfterEnd = Duration(minutes: 5);
const Duration gpsBacklogUploadWindowAfterEnd = Duration(
  hours: 23,
  minutes: 55,
);
const String gpsBacklogEarlierSessionReason =
    'it belongs to an earlier work session';
const String gpsBacklogServerRefusedReason = 'the server refused it';

final ValueNotifier<String> gpsBacklogNotice = ValueNotifier<String>('');

void reportDroppedGpsPoints(Iterable<String> reasons) {
  final List<String> shown = reasons.toList(growable: false);
  if (shown.isEmpty) return;
  final String why = shown.toSet().join('; ');
  gpsBacklogNotice.value =
      '${shown.length} saved location ${shown.length == 1 ? 'point was' : 'points were'} '
      'not sent because $why.';
}

GpsBacklogPlan planGpsBacklog(
  List<GpsBacklogFix> fixes,
  GpsLiveSnapshot? live,
  DateTime now,
) {
  final List<GpsBacklogFix> write = <GpsBacklogFix>[];
  final List<GpsBacklogFix> drop = <GpsBacklogFix>[];
  final Map<String, String> dropReasons = <String, String>{};
  final bool active = live?.status == 'active';
  final bool ended = live?.status == 'ended';
  void dropFix(GpsBacklogFix fix, String reason) {
    drop.add(fix);
    dropReasons[fix.key] = reason;
  }

  for (final GpsBacklogFix fix in fixes) {
    final DateTime captured = fix.deviceCapturedAt.toUtc();
    final DateTime? start = live?.startedAt;
    final DateTime? end = live?.endedAt;
    final DateTime? liveCaptured = live?.deviceCapturedAt;
    if (live == null || !(active || ended)) {
      dropFix(fix, 'the work session is not open on the server');
      continue;
    }
    if (fix.sessionId != live.sessionId || fix.generation != live.generation) {
      dropFix(fix, gpsBacklogEarlierSessionReason);
      continue;
    }
    if (captured.isBefore(now.subtract(gpsBacklogMaxAge))) {
      dropFix(fix, 'it is older than 7 days');
      continue;
    }
    if ((start != null &&
            captured.isBefore(start.subtract(gpsBacklogBeforeStart))) ||
        (ended &&
            end != null &&
            captured.isAfter(end.add(gpsBacklogAfterEnd)))) {
      dropFix(fix, 'it was recorded outside the work session time');
      continue;
    }
    if (ended &&
        end != null &&
        now.isAfter(end.add(gpsBacklogUploadWindowAfterEnd))) {
      dropFix(fix, 'the 24 hour upload window after work ended has passed');
      continue;
    }
    if (fix.fixSequence < live.lastFixSequence - gpsBacklogSequenceWindow) {
      dropFix(
        fix,
        'it is more than $gpsBacklogSequenceWindow points behind the latest point',
      );
      continue;
    }
    final bool belowLive =
        fix.fixSequence < live.lastFixSequence &&
        liveCaptured != null &&
        captured.isBefore(liveCaptured);
    if (belowLive) {
      write.add(fix);
    } else if (ended) {
      dropFix(fix, 'a newer point was already saved');
    }
  }
  write.sort(
    (GpsBacklogFix a, GpsBacklogFix b) =>
        a.fixSequence.compareTo(b.fixSequence),
  );
  return GpsBacklogPlan(
    write: write.take(gpsBacklogWritesPerFlush).toList(growable: false),
    drop: drop,
    dropReasons: dropReasons,
  );
}
