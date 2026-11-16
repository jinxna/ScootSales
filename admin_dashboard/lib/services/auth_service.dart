import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../app/workspace_runtime.dart';
import '../app_runtime.dart';
import '../control_centre/staff_browser.dart';
import '../models/user_profile.dart';
import '../security/canonical_profile_identity.dart';
import '../utils/login_throttle.dart';
import '../widgets/avatar_storage.dart';
import 'account_lockout_service.dart';
import 'forecast_snapshot_cache.dart';
import 'permission_policy_service.dart';
import 'platform_api_client.dart';

class AccountLockedException implements Exception {
  AccountLockedException({required this.email, required this.unlockAt});

  final String email;
  final DateTime unlockAt;

  Duration get remaining {
    final Duration delta = unlockAt.difference(DateTime.now());
    return delta.isNegative ? Duration.zero : delta;
  }

  @override
  String toString() =>
      'AccountLockedException(email: $email, unlockAt: $unlockAt)';
}

const String _deviceKey = 'scootDevice';

class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  final Map<String, LoginThrottle> _loginThrottles = <String, LoginThrottle>{};
  AuthCredential? _pendingGoogle;
  String? _pendingGoogleEmail;
  String? _signInNotice;
  String? passwordNoticeEmail;

  static const String googleNotInvitedMessage =
      'This Google account has no access to this company. Ask your admin to '
      'invite you. Use the invitation code first. Then you can use Google.';
  static const String googleNeedsPasswordMessage =
      'This email already has a password. Sign in with your email and password '
      'once. Then Google is linked to your account.';

  static const String googlePasswordRemovedMessage =
      'Google sign-in can replace the password of an account that was not '
      'verified. If you used a password before, set a new password now. A '
      'reset link can be sent to your email.';

  String? takeSignInNotice() {
    final String? notice = _signInNotice;
    _signInNotice = null;
    return notice;
  }

  Stream<User?> authStateChanges() {
    if (!AppRuntime.firebaseReady) {
      return Stream<User?>.value(null);
    }
    return _auth.authStateChanges();
  }

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    final String normalisedEmail = email.trim().toLowerCase();
    final LoginThrottle loginThrottle = _loginThrottles.putIfAbsent(
      normalisedEmail,
      LoginThrottle.new,
    );

    final DateTime now = DateTime.now();
    final DateTime? lockedUntil = loginThrottle.activeLockAt(now);
    if (lockedUntil != null) {
      final bool released = await AccountLockoutService.instance.isUnlocked(
        email: normalisedEmail,
        lockedUntil: lockedUntil,
      );
      if (released && loginThrottle.lockedUntil == lockedUntil) {
        loginThrottle.reset();
      }
      final DateTime? remainingLock = loginThrottle.activeLockAt(
        DateTime.now(),
      );
      if (remainingLock != null) {
        throw AccountLockedException(
          email: normalisedEmail,
          unlockAt: remainingLock,
        );
      }
    }

    try {
      final UserCredential credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      _loginThrottles.remove(normalisedEmail);
      await _linkPendingGoogle(credential.user);
      return credential;
    } on FirebaseAuthException catch (error) {
      if (!isCredentialFailureCode(error.code)) rethrow;

      final DateTime? lockedNow = loginThrottle.recordCredentialFailure(now);
      if (lockedNow != null) {
        throw AccountLockedException(
          email: normalisedEmail,
          unlockAt: lockedNow,
        );
      }
      rethrow;
    }
  }

  Future<void> _linkPendingGoogle(User? user) async {
    final AuthCredential? pending = _pendingGoogle;
    final String? pendingEmail = _pendingGoogleEmail;
    _pendingGoogle = null;
    _pendingGoogleEmail = null;
    if (pending == null || user == null) return;
    if ((user.email ?? '').toLowerCase() != pendingEmail) return;
    try {
      await user.linkWithCredential(pending);
    } catch (_) {}
  }

  Future<bool> signInWithGoogle() async {
    _signInNotice = null;
    final UserCredential credential;
    try {
      credential = await _auth.signInWithPopup(GoogleAuthProvider());
    } on FirebaseAuthException catch (error) {
      if (error.code == 'popup-closed-by-user' ||
          error.code == 'cancelled-popup-request') {
        return false;
      }
      if (error.code == 'account-exists-with-different-credential' &&
          error.credential != null) {
        _pendingGoogle = error.credential;
        _pendingGoogleEmail = error.email?.toLowerCase();
        throw StateError(googleNeedsPasswordMessage);
      }
      rethrow;
    }
    if (credential.additionalUserInfo?.isNewUser ?? false) {
      _signInNotice = googleNotInvitedMessage;
      try {
        await credential.user?.delete();
      } catch (_) {}
      await signOut();
      throw StateError(googleNotInvitedMessage);
    }
    final User? user = credential.user;
    final String address = user?.email ?? '';
    final bool hasPassword =
        user?.providerData.any((UserInfo p) => p.providerId == 'password') ??
        true;
    final String seenKey = 'passwordNoticeSeen:${user?.uid}';
    if (!hasPassword && address.isNotEmpty && localRead(seenKey) == null) {
      localWrite(seenKey, '1');
      passwordNoticeEmail = address;
      _signInNotice = googlePasswordRemovedMessage;
    }
    return true;
  }

  Future<void> notifyAdminOfLocalLock({
    required String email,
    required DateTime lockedUntil,
  }) async {
    final LoginThrottle? throttle = _loginThrottles[email.trim().toLowerCase()];
    if (throttle?.activeLockAt(DateTime.now()) != lockedUntil) {
      throw StateError('The local retry delay has expired.');
    }
    await AccountLockoutService.instance.notifyAdmin(
      email: email,
      lockedUntil: lockedUntil,
    );
  }

  Future<void> sendPasswordReset(String email) =>
      PlatformApiClient().requestPasswordReset(email.trim());

  String get deviceId {
    final String? known = localRead(_deviceKey);
    if (known != null && known.length >= 16) return known;
    final Random random = Random.secure();
    final String made = List<int>.generate(
      24,
      (_) => random.nextInt(256),
    ).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    localWrite(_deviceKey, made);
    return made;
  }

  void reportSignIn() {
    final PlatformApiClient client = PlatformApiClient();
    if (!client.isConnected || WorkspaceRuntime.current == null) return;
    unawaited(
      Future<void>(() => client.reportSignIn(deviceId)).catchError((_) {}),
    );
  }

  Future<void> signOut() async {
    ForecastSnapshotCache.clearAll();
    final String? signedOutUid = AppRuntime.firebaseReady
        ? _auth.currentUser?.uid
        : null;
    if (signedOutUid != null) UserAvatarStorage.clear(signedOutUid);
    if (!AppRuntime.firebaseReady) return;
    PermissionPolicyService.instance.endSession();
    await _auth.signOut();
  }

  Future<UserProfile?> resolveUserProfile(
    User user, {
    DocumentSnapshot<Map<String, dynamic>>? accessSnapshot,
    DocumentSnapshot<Map<String, dynamic>>? linkedProfileSnapshot,
  }) async {
    if (!AppRuntime.firebaseReady) return null;

    final DocumentSnapshot<Map<String, dynamic>> access =
        accessSnapshot ??
        await _firestore.collection('user_access').doc(user.uid).get();
    if (access.exists) {
      final Map<String, dynamic>? accessData = access.data();
      if (accessData == null) return null;
      if (accessData['accessVersion'] == 2) {
        final Map<String, dynamic>? identity =
            CanonicalProfileIdentity.strictV2Identity(
              accessData: accessData,
              authUid: user.uid,
              allowSuspended: true,
            );
        if (identity == null) return null;

        final String displayDocumentId =
            CanonicalProfileIdentity.strictLinkedDocumentId(accessData);
        Map<String, dynamic> displayData = <String, dynamic>{};
        if (displayDocumentId.isNotEmpty) {
          try {
            final DocumentSnapshot<Map<String, dynamic>> display =
                linkedProfileSnapshot ??
                await _firestore
                    .collection('users')
                    .doc(displayDocumentId)
                    .get();
            displayData = display.data() ?? <String, dynamic>{};
          } catch (_) {}
        }
        final String accessEmail = accessData['email'] is String
            ? accessData['email'] as String
            : '';
        return UserProfile.fromFirestore(
          displayDocumentId.isEmpty ? user.uid : displayDocumentId,
          <String, dynamic>{
            ...displayData,
            ...identity,
            'isActive': identity['status'] == UserProfile.statusActive,
            'uid': user.uid,
            'email': displayData['email'] is String
                ? displayData['email']
                : accessEmail,
          },
        );
      }
      if (accessData['accessVersion'] != null) return null;
      final String linkedDocumentId =
          CanonicalProfileIdentity.strictLinkedDocumentId(accessData);
      if (linkedDocumentId.isEmpty) {
        if (accessData.containsKey('userDocId') ||
            accessData.containsKey('user_doc_id')) {
          return null;
        }
        return _legacyUnlinkedProfile(
          user,
          accessData,
          displaySnapshot: linkedProfileSnapshot,
        );
      }
      final DocumentSnapshot<Map<String, dynamic>> canonical =
          linkedProfileSnapshot ??
          await _firestore.collection('users').doc(linkedDocumentId).get();

      if (!canonical.exists || canonical.data() == null) return null;

      final Map<String, dynamic> canonicalData = canonical.data()!;
      if (!CanonicalProfileIdentity.matches(
        accessData: accessData,
        canonicalData: canonicalData,
        authUid: user.uid,
        authEmail: user.email ?? '',
      )) {
        return null;
      }
      final bool active =
          CanonicalProfileIdentity.isActiveCanonical(canonicalData) &&
          CanonicalProfileIdentity.isActiveAccessIndex(accessData);
      return _profileFromDocument(canonical, user, forceSuspended: !active);
    }

    if (linkedProfileSnapshot != null) {
      final Map<String, dynamic>? data = linkedProfileSnapshot.data();
      if (!linkedProfileSnapshot.exists ||
          data == null ||
          !CanonicalProfileIdentity.matchesCanonicalProfile(
            canonicalData: data,
            authUid: user.uid,
            authEmail: user.email ?? '',
          )) {
        return null;
      }
      return _profileFromDocument(
        linkedProfileSnapshot,
        user,
        forceSuspended: !CanonicalProfileIdentity.isActiveCanonical(data),
      );
    }

    final DocumentSnapshot<Map<String, dynamic>> byUid = await _firestore
        .collection('users')
        .doc(user.uid)
        .get();
    if (byUid.exists && byUid.data() != null) {
      final Map<String, dynamic> profileData = byUid.data()!;
      if (!CanonicalProfileIdentity.matchesCanonicalProfile(
        canonicalData: profileData,
        authUid: user.uid,
        authEmail: user.email ?? '',
      )) {
        return null;
      }
      return _profileFromDocument(
        byUid,
        user,
        forceSuspended: !CanonicalProfileIdentity.isActiveCanonical(
          profileData,
        ),
      );
    }

    QueryDocumentSnapshot<Map<String, dynamic>>? match;
    try {
      final QuerySnapshot<Map<String, dynamic>> byUidField = await _firestore
          .collection('users')
          .where('uid', isEqualTo: user.uid)
          .limit(2)
          .get();
      if (byUidField.docs.length == 1) match = byUidField.docs.first;
      if (match == null && byUidField.docs.isEmpty) {
        final QuerySnapshot<Map<String, dynamic>> byEmail = await _firestore
            .collection('users')
            .where('email', isEqualTo: user.email)
            .limit(2)
            .get();
        if (byEmail.docs.length == 1) match = byEmail.docs.first;
      }
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        throw Exception(profileNeedsResaveMessage);
      }
      rethrow;
    }
    if (match == null) return null;
    final Map<String, dynamic> profileData = match.data();
    if (!CanonicalProfileIdentity.matchesCanonicalProfile(
      canonicalData: profileData,
      authUid: user.uid,
      authEmail: user.email ?? '',
    )) {
      return null;
    }
    return _profileFromDocument(
      match,
      user,
      forceSuspended: !CanonicalProfileIdentity.isActiveCanonical(profileData),
    );
  }

  static const String profileNeedsResaveMessage =
      'Could not load your profile. Ask an administrator to open User '
      'Management and re-save your account, then try again.';

  Future<UserProfile?> _legacyUnlinkedProfile(
    User user,
    Map<String, dynamic> accessData, {
    DocumentSnapshot<Map<String, dynamic>>? displaySnapshot,
  }) async {
    final Object? accessUid = accessData['uid'] ?? accessData['user_uid'];
    if (accessUid != null && accessUid.toString().trim() != user.uid) {
      return null;
    }
    Map<String, dynamic> displayData = <String, dynamic>{};
    try {
      final DocumentSnapshot<Map<String, dynamic>> display =
          displaySnapshot ??
          await _firestore.collection('users').doc(user.uid).get();
      displayData = display.data() ?? <String, dynamic>{};
    } catch (_) {}
    final bool active = CanonicalProfileIdentity.isActiveAccessIndex(
      accessData,
    );
    final bool hasRole =
        (accessData['role'] ?? accessData['user_group'] ?? '')
            .toString()
            .trim()
            .isNotEmpty ||
        (displayData['role'] ?? displayData['user_group'] ?? '')
            .toString()
            .trim()
            .isNotEmpty;
    if (!hasRole) return null;
    return UserProfile.fromFirestore(user.uid, <String, dynamic>{
      ...displayData,
      ...accessData,
      if (displayData['email'] is String) 'email': displayData['email'],
      'uid': user.uid,
      if (!active) 'status': UserProfile.statusSuspended,
      if (!active) 'isActive': false,
    });
  }

  UserProfile _profileFromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
    User user, {
    bool forceSuspended = false,
  }) {
    return UserProfile.fromFirestore(document.id, <String, dynamic>{
      ...?document.data(),
      'uid': user.uid,
      if (forceSuspended) 'status': UserProfile.statusSuspended,
      if (forceSuspended) 'isActive': false,
    });
  }

  String describeSignInError(Object error) {
    return _friendlyMessage(
      error,
      fallback: 'We could not sign you in right now. Please try again.',
    );
  }

  String describeUserManagementError(Object error) {
    return _friendlyMessage(
      error,
      fallback:
          'We could not save that user profile right now. Please try again.',
      managing: true,
    );
  }

  String _friendlyMessage(
    Object error, {
    required String fallback,
    bool managing = false,
  }) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'invalid-email':
          return managing
              ? 'That email address is not valid.'
              : 'Email or password is incorrect.';
        case 'invalid-credential':
        case 'wrong-password':
        case 'user-not-found':
          return 'Email or password is incorrect.';
        case 'too-many-requests':
          return 'Too many attempts were made. Please wait a moment and try again.';
        case 'network-request-failed':
          return 'Could not connect. Please check your internet connection.';
        case 'user-disabled':
          return 'This account has been disabled. Please contact the admin.';
        case 'email-already-in-use':
          return 'That email is already being used by another login account.';
        case 'weak-password':
          return 'That password is too weak. Use at least 6 characters.';
        case 'operation-not-allowed':
          return 'Sign-in by this method is not enabled for this project. '
              'Please contact your administrator.';
      }
    }

    if (error is FirebaseException) {
      switch (error.code) {
        case 'permission-denied':
          return 'You do not have permission to do that right now.';
        case 'unavailable':
          return 'The database is temporarily unavailable. Please try again.';
        case 'unauthenticated':
          return 'Your session has expired. Please sign in again.';
      }
    }

    if (error is StateError) return error.message;
    if (error.runtimeType.toString() == '_Exception') {
      final String message = error
          .toString()
          .replaceFirst('Exception: ', '')
          .trim();
      if (message.isNotEmpty && message.toLowerCase() != 'null') {
        return message;
      }
    }
    return fallback;
  }
}
