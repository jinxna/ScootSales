import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

import '../app/lifecycle_notice.dart' as notices;
import '../app/workspace_runtime.dart';
import '../models/user_profile.dart';
import '../repositories/cms_repository.dart';
import '../security/canonical_profile_identity.dart';
import '../theme/theme_controller.dart';
import '../utils/firestore_value_equality.dart';
import '../utils/user_management_utils.dart';
import 'auth_service.dart';
import 'permission_policy_service.dart';

class DashboardAccessSession extends ChangeNotifier {
  User? user;
  bool authReady = false;
  int revision = 0;
  AsyncSnapshot<UserProfile?> profile =
      const AsyncSnapshot<UserProfile?>.waiting();
  String? lifecycleState;
  DateTime? lifecycleGraceEndsAt;
  DateTime? lifecycleRetentionEndsAt;
  bool lifecycleResolved = false;
  String roleChangeNotice = '';

  bool get lifecyclePending => !lifecycleResolved;

  bool get workspaceRestricted =>
      lifecycleResolved &&
      lifecycleState != null &&
      !WorkspaceRuntime.openStatuses.contains(lifecycleState);

  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _accessSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _profileSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _lifecycleSubscription;
  DocumentSnapshot<Map<String, dynamic>>? _access;
  DocumentSnapshot<Map<String, dynamic>>? _linkedProfile;
  String? _profileId;
  bool _profileRequired = false;
  bool _accessReady = false;
  bool _profileReady = false;
  bool _hadAccess = false;
  bool _disposed = false;
  bool _failed = false;
  bool _softPending = false;
  int _session = 0;
  int _resolution = 0;
  Future<void> _cacheReset = Future<void>.value();

  void start() {
    _authSubscription = AuthService.instance.authStateChanges().listen(
      (User? next) {
        if (authReady && user?.uid == next?.uid) return;
        DsoThemeController.instance.useAccount(next?.uid);
        _hadAccess = false;
        roleChangeNotice = '';
        user = next;
        authReady = true;
        retry();
      },
      onError: (Object error, StackTrace stack) {
        authReady = true;
        _fail(error, stack);
      },
    );
  }

  void retry() {
    final int session = ++_session;
    unawaited(_accessSubscription?.cancel());
    _accessSubscription = null;
    _detachProfile();
    _access = null;
    _accessReady = false;
    _failed = false;
    _invalidate();
    final User? current = user;
    _watchLifecycle(current != null);
    if (current == null) return;
    _accessSubscription = FirebaseFirestore.instance
        .collection('user_access')
        .doc(current.uid)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (DocumentSnapshot<Map<String, dynamic>> snapshot) {
            if (!_isCurrent(session)) return;
            if (snapshot.metadata.isFromCache ||
                snapshot.metadata.hasPendingWrites) {
              return;
            }
            final bool changed =
                !_accessReady ||
                _access?.exists != snapshot.exists ||
                !sameFirestoreValue(_access?.data(), snapshot.data());
            _access = snapshot;
            _accessReady = true;
            if (!changed) return;
            _markChanged();
            if (!snapshot.exists && _hadAccess) {
              _detachProfile();
              _complete(null);
              return;
            }
            _hadAccess = _hadAccess || snapshot.exists;
            final Map<String, dynamic>? data = snapshot.data();
            if (data != null) {
              final String linkedId =
                  CanonicalProfileIdentity.strictLinkedDocumentId(data);
              if (linkedId.isEmpty &&
                  (data.containsKey('userDocId') ||
                      data.containsKey('user_doc_id'))) {
                _detachProfile();
                _complete(null);
                return;
              }
              if (linkedId.isNotEmpty) {
                _watchProfile(
                  linkedId,
                  required: data['accessVersion'] != 2,
                  session: session,
                );
              } else if (data['accessVersion'] == null &&
                  !data.containsKey('userDocId') &&
                  !data.containsKey('user_doc_id')) {
                _watchProfile(current.uid, required: false, session: session);
              } else {
                _detachProfile();
              }
            }
            unawaited(_resolve(session));
          },
          onError: (Object error, StackTrace stack) {
            if (_isCurrent(session)) _fail(error, stack);
          },
        );
  }

  void _watchLifecycle(bool signedIn) {
    unawaited(_lifecycleSubscription?.cancel());
    _lifecycleSubscription = null;
    lifecycleState = null;
    lifecycleResolved = false;
    if (!signedIn) return;
    _lifecycleSubscription = FirebaseFirestore.instance
        .collection('config')
        .doc('lifecycle')
        .snapshots()
        .listen(
          (DocumentSnapshot<Map<String, dynamic>> snapshot) {
            final Object? state = snapshot.data()?['state'];
            final String? next = state is String ? state : null;
            final DateTime? grace = _momentOf(
              snapshot.data()?['graceEndsAt'],
            );
            final DateTime? retention = _momentOf(
              snapshot.data()?['retentionEndsAt'],
            );
            if (lifecycleResolved &&
                next == lifecycleState &&
                grace == lifecycleGraceEndsAt &&
                retention == lifecycleRetentionEndsAt) {
              return;
            }
            lifecycleState = next;
            lifecycleGraceEndsAt = grace;
            lifecycleRetentionEndsAt = retention;
            lifecycleResolved = true;
            if (!_disposed) notifyListeners();
          },
          onError: (Object _) {
            lifecycleResolved = true;
            if (!_disposed) notifyListeners();
          },
        );
  }

  static DateTime? _momentOf(Object? value) =>
      value is Timestamp ? value.toDate() : null;

  bool _isCurrent(int session) => !_disposed && !_failed && session == _session;

  void _watchProfile(
    String id, {
    required bool required,
    required int session,
  }) {
    if (_profileId == id) {
      _profileRequired = required;
      return;
    }
    _detachProfile();
    _profileId = id;
    _profileRequired = required;
    _profileSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(id)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (DocumentSnapshot<Map<String, dynamic>> snapshot) {
            if (!_isCurrent(session) || _profileId != id) return;
            if (snapshot.metadata.isFromCache ||
                snapshot.metadata.hasPendingWrites) {
              return;
            }
            final bool changed =
                !_profileReady ||
                _linkedProfile?.exists != snapshot.exists ||
                !sameFirestoreValue(_linkedProfile?.data(), snapshot.data());
            _linkedProfile = snapshot;
            _profileReady = true;
            if (!changed) return;
            _markChanged();
            unawaited(_resolve(session));
          },
          onError: (Object error, StackTrace stack) {
            if (!_isCurrent(session) || _profileId != id) return;
            if (_profileRequired) {
              _fail(error, stack);
              return;
            }
            _linkedProfile = null;
            _profileReady = true;
            _invalidate();
            unawaited(_resolve(session));
          },
        );
  }

  Future<void> _resolve(int session) async {
    if (!_isCurrent(session) ||
        !_accessReady ||
        (_profileId != null && !_profileReady)) {
      return;
    }
    if (_profileRequired && _linkedProfile?.exists != true) {
      _complete(null);
      return;
    }
    int resolution = ++_resolution;
    try {
      final UserProfile? resolved = await AuthService.instance
          .resolveUserProfile(
            user!,
            accessSnapshot: _access,
            linkedProfileSnapshot: _linkedProfile,
          );
      if (!_isCurrent(session) || resolution != _resolution) return;
      if (_access?.exists == false && _profileId == null && resolved != null) {
        _watchProfile(resolved.docId, required: true, session: session);
        return;
      }
      _settleSoft(resolved);
      resolution = _resolution;
      await _cacheReset;
      if (!_isCurrent(session) || resolution != _resolution) return;
      _complete(resolved);
    } catch (error, stack) {
      if (_isCurrent(session) && resolution == _resolution) _fail(error, stack);
    }
  }

  void _markChanged() {
    if (profile.hasData && profile.data != null) {
      _resolution++;
      _softPending = true;
      return;
    }
    _invalidate();
  }

  void _settleSoft(UserProfile? next) {
    if (!_softPending) return;
    _softPending = false;
    final UserProfile? before = profile.data;
    if (_sameAccessIdentity(before, next)) return;
    if (before != null && next != null && before.role != next.role) {
      roleChangeNotice = notices.roleChangeNotice(
        UserManagementUtils.roleLabel(before.role),
        UserManagementUtils.roleLabel(next.role),
      );
    }
    _invalidate();
  }

  void dismissRoleChangeNotice() {
    if (roleChangeNotice.isEmpty) return;
    roleChangeNotice = '';
    notifyListeners();
  }

  static bool _sameAccessIdentity(UserProfile? a, UserProfile? b) {
    if (a == null || b == null) return false;
    return a.docId == b.docId &&
        a.uid == b.uid &&
        a.email == b.email &&
        a.role == b.role &&
        a.employeeCode == b.employeeCode &&
        a.status == b.status &&
        a.branchId == b.branchId &&
        a.supervisorId == b.supervisorId &&
        a.assignedSalesmanCodes.join('|') == b.assignedSalesmanCodes.join('|');
  }

  void _invalidate() {
    _softPending = false;
    _resolution++;
    revision++;
    profile = const AsyncSnapshot<UserProfile?>.waiting();
    PermissionPolicyService.instance.endSession();
    _cacheReset = CmsRepository.resetAccessScope();
    notifyListeners();
  }

  void _complete(UserProfile? value) {
    _settleSoft(value);
    profile = AsyncSnapshot<UserProfile?>.withData(
      ConnectionState.active,
      value,
    );
    notifyListeners();
  }

  void _fail(Object error, StackTrace stack) {
    _failed = true;
    _invalidate();
    unawaited(_accessSubscription?.cancel());
    _accessSubscription = null;
    _detachProfile();
    profile = AsyncSnapshot<UserProfile?>.withError(
      ConnectionState.active,
      error,
      stack,
    );
    notifyListeners();
  }

  void _detachProfile() {
    unawaited(_profileSubscription?.cancel());
    _profileSubscription = null;
    _profileId = null;
    _linkedProfile = null;
    _profileReady = false;
    _profileRequired = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _session++;
    _resolution++;
    unawaited(_authSubscription?.cancel());
    unawaited(_accessSubscription?.cancel());
    unawaited(_lifecycleSubscription?.cancel());
    _detachProfile();
    super.dispose();
  }
}
