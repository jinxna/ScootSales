import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProjectLocalStore {
  ProjectLocalStore({String? projectId})
    : projectId = (projectId ?? Firebase.app().options.projectId).trim() {
    if (this.projectId.isEmpty) throw ArgumentError('Project ID is required.');
  }

  final String projectId;
  static int _identityRevision = 0;
  static int get runtimeRevision => _identityRevision;
  bool get isCurrentProject {
    try {
      return Firebase.app().options.projectId == projectId;
    } catch (_) {
      return false;
    }
  }

  static void invalidateIdentity() => _identityRevision++;

  bool Function() lease(String uid) {
    final revision = _identityRevision;
    return () {
      try {
        return revision == _identityRevision && isActive(uid);
      } catch (_) {
        return false;
      }
    };
  }

  static const recoveryPrefix = 'local_work_recovery_v1.';
  static final recoveryNotice = ValueNotifier<String>('');
  static final Map<String, Future<void>> _tails = {};

  static String encode(String value) =>
      base64Url.encode(utf8.encode(value.trim())).replaceAll('=', '');

  String prefix(String uid) =>
      'project_storage_v1.${encode(projectId)}.${encode(_uid(uid))}.';
  String key(String uid, String name) => '${prefix(uid)}$name';

  bool isActive(String uid) {
    try {
      return Firebase.app().options.projectId == projectId &&
          FirebaseAuth.instance.currentUser?.uid == uid.trim();
    } catch (_) {
      return false;
    }
  }

  static String _uid(String uid) {
    if (uid.trim().isEmpty) throw ArgumentError('Owner UID is required.');
    return uid.trim();
  }

  static Future<T> locked<T>(String key, Future<T> Function() action) async {
    final previous = _tails[key] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = previous.then((_) => release.future);
    _tails[key] = tail;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  }

  Future<String?> read(String uid, String name, {String? legacyKey}) async {
    final owner = _uid(uid);
    final destination = key(owner, name);
    if (legacyKey != null) {
      await locked('migration:$legacyKey', () async {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.get(legacyKey);
        if (raw == null) return;
        final legacy = _boundLegacy(raw, owner);
        if (legacy == null) {
          await _recover(prefs, legacyKey, raw);
          return;
        }
        if (legacy.$1.isEmpty) return;
        if (legacy.$1 != projectId) {
          _notice();
          return;
        }
        await locked(destination, () async {
          final encoded = _envelope(owner, legacy.$2);
          final existing = prefs.get(destination);
          if (existing != null && existing != encoded) {
            await _recover(prefs, legacyKey, raw);
            return;
          }
          try {
            if (existing == null &&
                !await prefs.setString(destination, encoded)) {
              await prefs.reload();
              _notice();
              return;
            }
            await prefs.reload();
            if (prefs.getString(destination) == encoded &&
                _same(prefs.get(legacyKey), raw)) {
              await prefs.remove(legacyKey);
            } else {
              _notice();
            }
          } catch (_) {
            _notice();
          }
        });
      });
    }
    return locked(destination, () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.get(destination);
      if (raw == null) return null;
      try {
        final decoded = raw is String ? jsonDecode(raw) : null;
        if (decoded is Map &&
            decoded['version'] == 1 &&
            decoded['projectId'] == projectId &&
            decoded['uid'] == owner &&
            decoded['data'] is String) {
          return decoded['data'] as String;
        }
      } catch (_) {
      }
      await _recover(prefs, destination, raw);
      return null;
    });
  }

  Future<void> write(String uid, String name, String data) {
    final owner = _uid(uid);
    final destination = key(owner, name);
    return locked(destination, () async {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.get(destination);
      if (existing != null && !_validEnvelope(existing, owner)) {
        await _recover(prefs, destination, existing);
        if (prefs.containsKey(destination)) {
          throw StateError('Saved work must be recovered before replacement.');
        }
      }
      final saved = await prefs.setString(destination, _envelope(owner, data));
      if (!saved) throw StateError('Work could not be saved on this device.');
    });
  }

  Future<void> remove(String uid, String name) =>
      locked(key(uid, name), () async {
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.remove(key(uid, name))) {
          throw StateError('Saved work could not be removed.');
        }
      });

  bool _validEnvelope(Object raw, String owner) {
    try {
      final value = raw is String ? jsonDecode(raw) : null;
      return value is Map &&
          value['version'] == 1 &&
          value['projectId'] == projectId &&
          value['uid'] == owner &&
          value['data'] is String;
    } catch (_) {
      return false;
    }
  }

  String _envelope(String uid, String data) => jsonEncode({
    'version': 1,
    'projectId': projectId,
    'uid': uid,
    'data': data,
  });

  (String, String)? _boundLegacy(Object raw, String uid) {
    final String untaggedProject = isActive(uid) ? projectId : '';
    try {
      if (raw is bool) return (untaggedProject, raw.toString());
      final decoded = raw is String ? jsonDecode(raw) : null;
      Object? ownerOf(Map row) =>
          row['uid'] ??
          row['salesmanUid'] ??
          (row['payload'] is Map ? row['payload']['salesmanUid'] : null);
      bool owned(Map row) => ownerOf(row) == uid;
      bool untaggedOwned(Object? row) =>
          row is Map &&
          !row.containsKey('projectId') &&
          (ownerOf(row) == null || owned(row));
      if (decoded is Map && untaggedOwned(decoded) ||
          decoded is List && decoded.every(untaggedOwned)) {
        return (untaggedProject, raw as String);
      }
      if (decoded is Map && decoded['projectId'] is String && owned(decoded)) {
        return (
          decoded['projectId'] as String,
          decoded['data'] is String ? decoded['data'] as String : raw as String,
        );
      }
      if (decoded is List &&
          decoded.isNotEmpty &&
          decoded.every(
            (row) => row is Map && row['projectId'] is String && owned(row),
          )) {
        final project = decoded.first['projectId'] as String;
        if (decoded.every((row) => row['projectId'] == project)) {
          return (project, raw as String);
        }
      }
    } catch (_) {
    }
    return null;
  }

  static bool _same(Object? left, Object? right) =>
      jsonEncode(left) == jsonEncode(right);

  static void _notice() {
    recoveryNotice.value =
        'Saved work needs company verification. It is kept on this device and will not sync automatically. Contact your administrator.';
  }

  static Future<void> refreshRecoveryNotice() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getKeys().any((key) => key.startsWith(recoveryPrefix))) _notice();
  }

  static Future<void> recoverLegacyKey(String source) => locked(
    'migration:$source',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.get(source);
      if (raw != null) {
        await _recover(prefs, source, raw);
        if (source.startsWith('project_storage_v1.') &&
            prefs.containsKey(source)) {
          throw StateError('Saved work must be recovered before replacement.');
        }
      }
    },
  );

  static Future<void> _recover(
    SharedPreferences prefs,
    String source,
    Object raw,
  ) async {
    _notice();
    final copy = jsonEncode({'sourceKey': source, 'raw': raw});
    final base = '$recoveryPrefix${encode(source)}';
    var destination = base;
    var revision = 0;
    while (prefs.containsKey(destination) && prefs.get(destination) != copy) {
      destination = '$base.${++revision}';
    }
    try {
      if (prefs.get(destination) != copy &&
          !await prefs.setString(destination, copy)) {
        return;
      }
      await prefs.reload();
      if (prefs.get(destination) == copy && _same(prefs.get(source), raw)) {
        await prefs.remove(source);
      }
    } catch (_) {
    }
  }
}
