import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';

class AuditLogService {
  AuditLogService._();

  static final AuditLogService instance = AuditLogService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> record({
    required String action,
    required String entityType,
    required String entityId,
    required String summary,
    UserProfile? actor,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    try {
      final User? authUser = FirebaseAuth.instance.currentUser;
      if (authUser == null) return;
      final String email = authUser.email?.trim() ?? '';
      final String name = _firstText(<String?>[actor?.name, email]);
      final String role = _firstText(<String?>[
        await _signedInRole(authUser.uid),
        actor?.role,
      ]);
      await _db.collection('system_audit_logs').add(<String, dynamic>{
        'action': action.trim(),
        'entityType': entityType.trim(),
        'entityId': entityId.trim(),
        'summary': summary.trim(),
        'actorUid': authUser.uid,
        'actorEmail': email,
        'actorName': name,
        'actorRole': role,
        'metadata': metadata,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (error) {
      debugPrint('Audit log row was not written: $error');
    }
  }

  Future<String?> _signedInRole(String uid) async {
    final DocumentSnapshot<Map<String, dynamic>> access = await _db
        .collection('user_access')
        .doc(uid)
        .get();
    final Map<String, dynamic>? data = access.data();
    final Object? role = data?['role'];
    return data?['accessVersion'] == 2 && role != null
        ? UserProfile.normalizeRole(role)
        : null;
  }

  static String _firstText(List<String?> values) {
    for (final String? value in values) {
      final String text = value?.trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }
}
