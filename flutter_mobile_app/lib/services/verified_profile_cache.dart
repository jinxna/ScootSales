import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_model.dart';

class VerifiedProfileReceipt {
  const VerifiedProfileReceipt({
    required this.projectId,
    required this.user,
    required this.verifiedAt,
  });

  static const int schemaVersion = 1;

  final String projectId;
  final UserModel user;
  final DateTime verifiedAt;

  bool isUsableFor({
    required String expectedProjectId,
    required String expectedUid,
    required DateTime now,
    required Duration maxAge,
  }) {
    final Duration age = now.difference(verifiedAt);
    return projectId == expectedProjectId.trim() &&
        user.uid.trim() == expectedUid.trim() &&
        user.hasActiveAccount &&
        user.hasSalespersonRole &&
        !age.isNegative &&
        age <= maxAge;
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'version': schemaVersion,
    'projectId': projectId,
    'uid': user.uid,
    'verifiedAtMs': verifiedAt.millisecondsSinceEpoch,
    'profile': <String, dynamic>{
      ...user.toMap(),
      if (user.photoUrl.startsWith('data:')) 'photoUrl': '',
    },
  };

  static VerifiedProfileReceipt? tryParse(Object? value) {
    if (value is! Map) return null;
    try {
      final Map<String, dynamic> data = Map<String, dynamic>.from(value);
      if (data['version'] != schemaVersion || data['profile'] is! Map) {
        return null;
      }
      final String projectId = (data['projectId'] ?? '').toString().trim();
      final String uid = (data['uid'] ?? '').toString().trim();
      final int? verifiedAtMs = data['verifiedAtMs'] is int
          ? data['verifiedAtMs'] as int
          : int.tryParse(data['verifiedAtMs']?.toString() ?? '');
      if (projectId.isEmpty || uid.isEmpty || verifiedAtMs == null) return null;
      final Map<String, dynamic> profile = Map<String, dynamic>.from(
        data['profile'] as Map,
      );
      final UserModel user = UserModel.fromMap(profile, uid);
      if (user.uid.trim() != uid) return null;
      return VerifiedProfileReceipt(
        projectId: projectId,
        user: user,
        verifiedAt: DateTime.fromMillisecondsSinceEpoch(
          verifiedAtMs,
          isUtc: true,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

class VerifiedProfileCache {
  VerifiedProfileCache({
    String? projectId,
    this.maxAge = const Duration(hours: 24),
  }) : projectId = (projectId ?? Firebase.app().options.projectId).trim();

  final String projectId;
  final Duration maxAge;

  Future<void> save(UserModel user, {DateTime? now}) async {
    if (user.uid.trim().isEmpty ||
        !user.hasActiveAccount ||
        !user.hasSalespersonRole) {
      throw ArgumentError('Only an active salesperson profile can be cached.');
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final VerifiedProfileReceipt receipt = VerifiedProfileReceipt(
      projectId: projectId,
      user: user,
      verifiedAt: now ?? DateTime.now(),
    );
    await prefs.setString(_key(user.uid), jsonEncode(receipt.toMap()));
  }

  Future<VerifiedProfileReceipt?> load(String uid, {DateTime? now}) async {
    final String cleanUid = uid.trim();
    if (cleanUid.isEmpty || projectId.isEmpty) return null;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key(cleanUid));
    if (raw == null || raw.isEmpty) return null;
    try {
      final VerifiedProfileReceipt? receipt = VerifiedProfileReceipt.tryParse(
        jsonDecode(raw),
      );
      if (receipt == null ||
          !receipt.isUsableFor(
            expectedProjectId: projectId,
            expectedUid: cleanUid,
            now: now ?? DateTime.now(),
            maxAge: maxAge,
          )) {
        return null;
      }
      return receipt;
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String uid) async {
    final String cleanUid = uid.trim();
    if (cleanUid.isEmpty) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(cleanUid));
  }

  String _key(String uid) {
    String encode(String value) =>
        base64Url.encode(utf8.encode(value.trim())).replaceAll('=', '');
    return 'verified_profile_v1.${encode(projectId)}.${encode(uid)}';
  }
}
