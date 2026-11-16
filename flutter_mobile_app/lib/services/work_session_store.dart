import 'dart:async';
import 'dart:convert';

import 'project_local_store.dart';

import '../models/work_session.dart';

class WorkSessionStore {
  const WorkSessionStore({this.projectId});

  final String? projectId;
  ProjectLocalStore get _store => ProjectLocalStore(projectId: projectId);
  WorkSessionStore _pin() => WorkSessionStore(projectId: _store.projectId);

  static final Map<String, Future<void>> _uidWriteTails =
      <String, Future<void>>{};

  String _key(String uid) => 'work_session_v1_${uid.trim()}';

  Future<WorkSession?> read(String uid) async {
    if (projectId == null) return _pin().read(uid);
    return _withUidLock<WorkSession?>(uid, () => _readUnlocked(uid));
  }

  Future<void> write(WorkSession session) {
    if (projectId == null) return _pin().write(session);
    return _withUidLock<void>(session.uid, () async {
      WorkSession value = session;
      final WorkSession? current = await _readUnlocked(session.uid);
      if (current != null &&
          current.sessionId == session.sessionId &&
          current.generation == session.generation &&
          current.lastRouteStopEventSequence >
              session.lastRouteStopEventSequence) {
        value = session.copyWith(
          lastRouteStopEventSequence: current.lastRouteStopEventSequence,
        );
      }
      await _writeUnlocked(value);
    });
  }

  Future<WorkSession> nextRouteStopEventSequence({
    required String uid,
    required String sessionId,
    required int generation,
  }) {
    if (projectId == null) {
      return _pin().nextRouteStopEventSequence(
        uid: uid,
        sessionId: sessionId,
        generation: generation,
      );
    }
    return _withUidLock<WorkSession>(uid, () async {
      final WorkSession? current = await _readUnlocked(uid);
      if (current == null ||
          current.sessionId != sessionId ||
          current.generation != generation ||
          !current.isAcknowledged ||
          current.endPendingSync) {
        throw StateError('The acknowledged work session is no longer active.');
      }
      final WorkSession advanced = current.copyWith(
        lastRouteStopEventSequence: current.lastRouteStopEventSequence + 1,
      );
      await _writeUnlocked(advanced);
      return advanced;
    });
  }

  Future<WorkSession?> _readUnlocked(String uid) async {
    final String ownerUid = uid.trim();
    if (ownerUid.isEmpty) throw ArgumentError.value(uid, 'uid');
    final String? encoded = await _store.read(
      ownerUid,
      'work_session',
      legacyKey: _key(ownerUid),
    );
    if (encoded == null) return null;
    final WorkSession? session = _decode(encoded, ownerUid);
    if (session == null) {
      final key = _store.key(ownerUid, 'work_session');
      await ProjectLocalStore.recoverLegacyKey(key);
      final raw = await _store.read(ownerUid, 'work_session');
      if (raw != null) {
        throw StateError(
          'Invalid work session must be recovered before replacement.',
        );
      }
    }
    return session;
  }

  static const String quarantinePrefix = 'work_session_quarantine_v1_';

  WorkSession? _decode(String encoded, String uid) {
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      final WorkSession? session = WorkSession.tryParse(
        Map<String, dynamic>.from(decoded),
        uid,
      );
      return session == null || session.sessionId.isEmpty ? null : session;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> _writeUnlocked(WorkSession session) async {
    await _store.write(
      session.uid,
      'work_session',
      jsonEncode(session.toMap()),
    );
  }

  Future<T> _withUidLock<T>(String uid, Future<T> Function() action) async {
    final String key = _store.key(uid, 'work_session_lock');
    if (key.isEmpty) throw ArgumentError.value(uid, 'uid');
    final Future<void> previous = _uidWriteTails[key] ?? Future<void>.value();
    final Completer<void> release = Completer<void>();
    final Future<void> tail = previous
        .then<void>((_) {}, onError: (Object _) {})
        .then<void>((_) => release.future);
    _uidWriteTails[key] = tail;
    await previous.then<void>((_) {}, onError: (Object _) {});
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_uidWriteTails[key], tail)) _uidWriteTails.remove(key);
    }
  }
}
