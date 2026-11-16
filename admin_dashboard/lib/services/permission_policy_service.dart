import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../app/permission_policy.dart';
import '../app_runtime.dart';
import '../models/user_profile.dart';

class PermissionPolicyService {
  PermissionPolicyService._();

  static final PermissionPolicyService instance = PermissionPolicyService._();

  static const String collectionName = 'system_access_config';
  static const String documentId = 'permission_matrix';
  static const String auditCollection = 'system_audit_logs';
  static const String auditAction = 'permission_matrix_updated';

  final ValueNotifier<PermissionPolicy> policy =
      ValueNotifier<PermissionPolicy>(PermissionPolicy.baseline());

  String lastError = '';

  bool readDenied = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subscription;

  bool get loadedFromDocument => policy.value.sourceFromDocument;

  bool cachedAllows(String role, String moduleId, PermissionAction action) =>
      policy.value.allows(role, moduleId, action);

  bool cachedAllowsWrite(String role, String moduleId) =>
      PermissionModuleRegistry.writeActions.any(
        (PermissionAction action) => cachedAllows(role, moduleId, action),
      );

  void startSession({String role = PermissionModuleRegistry.roleAdmin}) {
    if (_subscription != null || !AppRuntime.firebaseReady) return;
    if ((FirebaseAuth.instance.currentUser?.uid ?? '').isEmpty) return;
    final bool delegate = PermissionModuleRegistry.delegatedRoles.contains(
      role,
    );
    final DocumentReference<Map<String, dynamic>> source = delegate
        ? _firestore
              .collection(PermissionModuleRegistry.grantsCollection)
              .doc(role)
        : _document;
    _subscription = source.snapshots().listen(
      (DocumentSnapshot<Map<String, dynamic>> snapshot) {
        policy.value = delegate
            ? PermissionPolicy.forActorRole(role, snapshot.data())
            : PermissionPolicy.fromDocument(snapshot.data());
        lastError = '';
        readDenied = false;
      },
      onError: (Object error) {
        _recordReadError(error);
        _subscription?.cancel();
        _subscription = null;
      },
    );
  }

  void endSession() {
    _subscription?.cancel();
    _subscription = null;
    policy.value = PermissionPolicy.baseline();
  }

  Future<void> load() async {
    if (!AppRuntime.firebaseReady) return;
    try {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await _document
          .get();
      policy.value = PermissionPolicy.fromDocument(snapshot.data());
      lastError = '';
      readDenied = false;
    } catch (error) {
      _recordReadError(error);
    }
  }

  void _recordReadError(Object error) {
    readDenied =
        error is FirebaseException && error.code == 'permission-denied';
    lastError = readDenied ? '' : error.toString();
  }

  static String auditDocumentIdFor(int revision) {
    final Random random = Random.secure();
    final String suffix = List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'permission_matrix_r${revision}_$suffix';
  }

  Future<void> save({
    required PermissionPolicy next,
    required UserProfile actor,
  }) async {
    if (!AppRuntime.firebaseReady) {
      throw StateError('Shared data connection is not ready.');
    }
    final String actorUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (actorUid.isEmpty) {
      throw StateError('A signed-in administrator is required.');
    }
    final PermissionPolicy previous = policy.value;
    final Map<String, bool> changes = next.diffAgainst(previous);
    final List<String> granted = <String>[
      for (final MapEntry<String, bool> c in changes.entries)
        if (c.value) c.key,
    ]..sort();
    final List<String> revoked = <String>[
      for (final MapEntry<String, bool> c in changes.entries)
        if (!c.value) c.key,
    ]..sort();
    final int nextRevision = next.revision + 1;
    final String auditId = auditDocumentIdFor(nextRevision);
    final WriteBatch batch = _firestore.batch();
    batch.set(_document, <String, dynamic>{
      ...next.toDocumentPayload(
        updatedByUid: actorUid,
        auditDocumentId: auditId,
      ),
      'updatedByEmail': actor.email,
      'updatedByName': actor.name,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    for (final String role in PermissionModuleRegistry.delegatedRoles) {
      batch.set(
        _firestore.collection(PermissionModuleRegistry.grantsCollection).doc(role),
        <String, dynamic>{
          'role': role,
          'grants': next.delegatedGrantsFor(role),
          'revision': nextRevision,
          'shape': PermissionModuleRegistry.mirrorShape,
          'updatedByUid': actorUid,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );
    }
    batch.set(
      _firestore.collection(auditCollection).doc(auditId),
      <String, dynamic>{
        'action': auditAction,
        'entityType': collectionName,
        'entityId': documentId,
        'summary':
            'Updated role permissions. Granted: '
            '${granted.isEmpty ? 'none' : granted.join(', ')}. Revoked: '
            '${revoked.isEmpty ? 'none' : revoked.join(', ')}.',
        'actorUid': actorUid,
        'actorEmail': FirebaseAuth.instance.currentUser?.email ?? '',
        'actorName': actor.name,
        'actorRole': actor.role,
        'metadata': <String, dynamic>{
          'granted': granted,
          'revoked': revoked,
          'previousRevision': previous.revision,
          'nextRevision': nextRevision,
        },
        'createdAt': FieldValue.serverTimestamp(),
      },
    );
    await batch.commit();
    policy.value = next.withRevision(nextRevision);
    lastError = '';
  }

  DocumentReference<Map<String, dynamic>> get _document =>
      _firestore.collection(collectionName).doc(documentId);

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
}
