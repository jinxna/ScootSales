import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../dev/emulator_saved_sign_in.dart';
import 'staff_api_client.dart';
import 'staff_browser.dart';

const String _apiKey = String.fromEnvironment(
  'STAFF_FIREBASE_API_KEY',
  defaultValue: 'staff-local-key',
);
const String _appId = String.fromEnvironment(
  'STAFF_FIREBASE_APP_ID',
  defaultValue: '1:1:web:staff',
);
const String _projectId = String.fromEnvironment(
  'STAFF_FIREBASE_PROJECT_ID',
  defaultValue: 'demo-scoot-platform',
);
const String _authDomain = String.fromEnvironment('STAFF_FIREBASE_AUTH_DOMAIN');
const String _senderId = String.fromEnvironment(
  'STAFF_FIREBASE_MESSAGING_SENDER_ID',
  defaultValue: '1',
);
const bool _useEmulator = bool.fromEnvironment('USE_FIREBASE_EMULATOR');
const String _emulatorHost = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: '127.0.0.1',
);
const int _authEmulatorPort = int.fromEnvironment(
  'FIREBASE_AUTH_EMULATOR_PORT',
  defaultValue: 9099,
);

const String _sessionKey = 'staffSession';
const String _deviceKey = 'staffDevice';
const String _trustedDeviceKey = 'staffTrustedDevice';
const String _appName = 'staff';
const int staffPasswordMin = 12;
const int staffPasswordMax = 128;
const String _googleNotStaff =
    'This Google account is not a Control Centre account. Ask an owner to '
    'invite you. Accept the invitation first. Then you can use Google.';

enum StaffAuthStep { starting, signedOut, code, signedIn }

class StaffAuth extends ChangeNotifier {
  FirebaseAuth? _auth;
  StaffApiClient? api;
  StaffAuthStep step = StaffAuthStep.starting;
  String email = '';
  String? maskedTo, notice, error, signedInRole, signedInName;
  String? passwordNoticeEmail;
  int backupCodesLeft = 0;
  bool busy = false, sending = false, codeNotSent = false;
  String? _sessionId;
  final Completer<FirebaseAuth> _ready = Completer<FirebaseAuth>();
  AuthCredential? _pendingGoogle;
  String? _pendingGoogleEmail;

  bool get canUseBackupCode => backupCodesLeft > 0 || codeNotSent;

  bool get hasPassword =>
      _auth?.currentUser?.providerData.any(
        (UserInfo info) => info.providerId == 'password',
      ) ??
      false;

  Stream<User?> get userChanges => Stream<FirebaseAuth>.fromFuture(
    _ready.future,
  ).asyncExpand((FirebaseAuth auth) => auth.authStateChanges());

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

  Future<Map<String, String>> headers() async {
    final User? user = _auth?.currentUser;
    return <String, String>{
      'X-Staff-Device': deviceId,
      if (user != null) 'Authorization': 'Bearer ${await user.getIdToken()}',
      if (_sessionId != null) 'X-Staff-Session': _sessionId!,
    };
  }

  String? _trustedTokenFor(String address) {
    final String? raw = localRead(_trustedDeviceKey);
    if (raw == null) return null;
    try {
      final Object? record = jsonDecode(raw);
      if (record is! Map) return null;
      final Object? token = record['token'];
      final DateTime? expires = DateTime.tryParse(
        '${record['expiresAt']}',
      )?.toUtc();
      if (token is! String ||
          token.isEmpty ||
          expires == null ||
          !expires.isAfter(DateTime.now().toUtc()) ||
          '${record['email']}' != address.trim().toLowerCase()) {
        return null;
      }
      return token;
    } catch (_) {
      return null;
    }
  }

  void forgetDevice() => localRemove(_trustedDeviceKey);

  Future<void> _keepSession(
    StaffSignedIn result, {
    required bool remember,
  }) async {
    _sessionId = result.sessionId;
    if (remember) {
      localWrite(_sessionKey, result.sessionId);
      sessionRemove(_sessionKey);
    } else {
      sessionWrite(_sessionKey, result.sessionId);
      localRemove(_sessionKey);
    }
    try {
      await _auth?.setPersistence(
        remember ? Persistence.LOCAL : Persistence.SESSION,
      );
    } catch (_) {}
    signedInRole = result.role;
    signedInName = result.name;
    backupCodesLeft = result.backupCodesLeft;
    notice = result.usedBackupCode
        ? 'You used a backup code. ${result.backupCodesLeft} left.'
        : null;
    step = StaffAuthStep.signedIn;
    busy = false;
    notifyListeners();
  }

  Future<void> start() async {
    try {
      final String? remembered = localRead(_sessionKey);
      _sessionId = remembered ?? sessionRead(_sessionKey);
      final Object? saved = _useEmulator
          ? await setAsideSessionSignIn(apiKey: _apiKey, appName: _appName)
          : null;
      final FirebaseApp app = await Firebase.initializeApp(
        name: _appName,
        options: FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
          authDomain: _authDomain.isEmpty
              ? '$_projectId.firebaseapp.com'
              : _authDomain,
        ),
      );
      final FirebaseAuth auth = FirebaseAuth.instanceFor(app: app);
      if (_useEmulator) {
        await auth.useAuthEmulator(_emulatorHost, _authEmulatorPort);
        await restoreSavedSignIn(
          auth,
          saved,
          apiKey: _apiKey,
          host: _emulatorHost,
          port: _authEmulatorPort,
        );
      }
      await auth.setPersistence(
        remembered != null ? Persistence.LOCAL : Persistence.SESSION,
      );
      _auth = auth;
      _ready.complete(auth);
      final User? restored = await auth.authStateChanges().first;
      if (restored != null && _sessionId != null) {
        email = restored.email ?? '';
        step = StaffAuthStep.signedIn;
      } else {
        _sessionId = null;
        sessionRemove(_sessionKey);
        localRemove(_sessionKey);
        step = StaffAuthStep.signedOut;
      }
    } catch (_) {
      step = StaffAuthStep.signedOut;
      error = 'Sign-in could not start. Reload the page.';
    }
    notifyListeners();
  }

  void _fail(String message) {
    busy = false;
    error = message;
    notifyListeners();
  }

  String _authMessage(FirebaseAuthException e) => switch (e.code) {
    'invalid-credential' ||
    'wrong-password' ||
    'user-not-found' ||
    'invalid-email' => 'The email or password is not right.',
    'user-disabled' => 'This account is turned off. Ask an owner.',
    'too-many-requests' => 'Too many tries. Wait a few minutes and try again.',
    _ => 'Sign-in failed. Try again.',
  };

  Future<void> signIn(String address, String password) async {
    if (busy) return;
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      final UserCredential credential = await _auth!.signInWithEmailAndPassword(
        email: address.trim(),
        password: password,
      );
      email = credential.user?.email ?? address.trim();
      await _linkPendingGoogle(credential.user);
    } on FirebaseAuthException catch (e) {
      _fail(_authMessage(e));
      return;
    } catch (_) {
      _fail('Sign-in failed. Try again.');
      return;
    }
    await continueSignIn();
  }

  @visibleForTesting
  Future<void> continueSignIn() async {
    final String? token = _trustedTokenFor(email);
    if (token == null) {
      await requestCode();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final StaffSignedIn result = await api!.signInTrusted(token);
      await _keepSession(result, remember: true);
      return;
    } on StaffApiException catch (e) {
      if (e.statusCode == 403) {
        await _backToSignIn(e.message);
        return;
      }
      if (e.statusCode == 401) forgetDevice();
    } catch (_) {}
    await requestCode();
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
      notice =
          'Google is now linked. Next time you can use Continue with Google.';
    } catch (_) {}
  }

  Future<void> signInWithGoogle() async {
    if (busy) return;
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    final UserCredential credential;
    try {
      credential = await _auth!.signInWithPopup(GoogleAuthProvider());
    } on FirebaseAuthException catch (e) {
      if (e.code == 'popup-closed-by-user' ||
          e.code == 'cancelled-popup-request') {
        busy = false;
        notifyListeners();
        return;
      }
      if (e.code == 'account-exists-with-different-credential' &&
          e.credential != null) {
        _pendingGoogle = e.credential;
        _pendingGoogleEmail = e.email?.toLowerCase();
        _fail(
          'This email already has a password. Sign in with your email and '
          'password once. Then Google is linked to your account.',
        );
        return;
      }
      _fail(_authMessage(e));
      return;
    } catch (_) {
      _fail('Google sign-in failed. Try again.');
      return;
    }
    if (credential.additionalUserInfo?.isNewUser ?? false) {
      try {
        await credential.user?.delete();
      } catch (_) {}
      await _forget();
      _fail(_googleNotStaff);
      return;
    }
    email = credential.user?.email ?? '';
    final bool hasPassword =
        credential.user?.providerData.any(
          (UserInfo p) => p.providerId == 'password',
        ) ??
        true;
    final String seenKey = 'passwordNoticeSeen:${credential.user?.uid}';
    final bool showNotice =
        !hasPassword && email.isNotEmpty && localRead(seenKey) == null;
    await continueSignIn();
    if (showNotice && error == null) {
      localWrite(seenKey, '1');
      passwordNoticeEmail = email;
      notice =
          'Google sign-in replaced your password. Set a new password with a '
          'reset link sent to $email.';
      notifyListeners();
    }
  }

  Future<String?> changePassword(String current, String next) async {
    final User? user = _auth?.currentUser;
    final String? address = user?.email;
    if (user == null || address == null) return 'Sign in again first.';
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: address, password: current),
      );
    } on FirebaseAuthException catch (e) {
      return switch (e.code) {
        'invalid-credential' ||
        'wrong-password' ||
        'user-mismatch' => 'Your current password is not right.',
        'too-many-requests' =>
          'Too many tries. Wait a few minutes and try again.',
        _ => 'The password was not changed. Try again.',
      };
    } catch (_) {
      return 'The password was not changed. Try again.';
    }
    try {
      await user.updatePassword(next);
    } on FirebaseAuthException catch (e) {
      return e.code == 'weak-password'
          ? 'Choose a stronger password.'
          : 'The password was not changed. Try again.';
    } catch (_) {
      return 'The password was not changed. Try again.';
    }
    bool othersEnded = true;
    try {
      await api?.endAllStaffSessions();
      forgetDevice();
    } catch (_) {
      othersEnded = false;
    }
    await _forget();
    step = StaffAuthStep.signedOut;
    error = null;
    notice = othersEnded
        ? 'Your password is changed. Sign in with the new password.'
        : 'Your password is changed. Other devices could not be signed out. '
              'Sign in, then use Sign out of all devices.';
    notifyListeners();
    return null;
  }

  Future<String> sendSetPasswordLink() async {
    try {
      await api!.requestPasswordReset(email);
    } on StaffApiException catch (failure) {
      if (failure.statusCode == 429) return failure.message;
      return 'The link was not sent. Try again.';
    } catch (_) {
      return 'The link was not sent. Try again.';
    }
    return 'We sent a link to $email. Open it to set a password.';
  }

  Future<void> requestCode() async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final StaffCodeSent sent = await api!.requestSignInCode();
      maskedTo = sent.sentTo;
      sending = sent.isSending;
      backupCodesLeft = sent.backupCodesLeft;
      codeNotSent = false;
      step = StaffAuthStep.code;
      busy = false;
      notifyListeners();
    } on StaffApiException catch (e) {
      if (e.statusCode == 401) {
        await _backToSignIn(e.message);
      } else if (e.statusCode == 403) {
        await _backToSignIn(e.message);
      } else {
        codeNotSent = true;
        step = StaffAuthStep.code;
        _fail(e.message);
      }
    }
  }

  Future<void> verify({
    String? code,
    String? backupCode,
    bool remember = false,
  }) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final StaffSignedIn result = await api!.verifySignIn(
        code: code,
        backupCode: backupCode,
        remember: remember,
      );
      final String? token = remember ? result.deviceToken : null;
      final String? expires = result.deviceTokenExpiresAt;
      if (token != null && expires != null) {
        localWrite(
          _trustedDeviceKey,
          jsonEncode(<String, String>{
            'email': email.trim().toLowerCase(),
            'token': token,
            'expiresAt': expires,
          }),
        );
      }
      await _keepSession(result, remember: token != null && expires != null);
    } on StaffApiException catch (e) {
      if (e.statusCode == 401 && e.message.contains('password')) {
        await _backToSignIn(e.message);
      } else if (e.statusCode == 403) {
        await _backToSignIn(e.message);
      } else {
        _fail(e.message);
      }
    }
  }

  Future<void> _backToSignIn(String message) async {
    await _forget();
    step = StaffAuthStep.signedOut;
    busy = false;
    error = message;
    notifyListeners();
  }

  Future<void> _forget() async {
    _sessionId = null;
    sessionRemove(_sessionKey);
    localRemove(_sessionKey);
    try {
      await _auth?.signOut();
      await _auth?.setPersistence(Persistence.SESSION);
    } catch (_) {}
  }

  void sessionLost() {
    if (step != StaffAuthStep.signedIn) return;
    step = StaffAuthStep.signedOut;
    error = 'Your session ended. Sign in again.';
    notifyListeners();
    unawaited(_forget());
  }

  Future<void> signOut() async {
    try {
      await api?.endStaffSession('current');
    } catch (_) {}
    await _forget();
    step = StaffAuthStep.signedOut;
    error = null;
    notice = null;
    notifyListeners();
  }

  Future<void> signOutIdle(int minutes) async {
    await signOut();
    notice =
        'You were signed out after $minutes minutes without activity. Sign in again.';
    notifyListeners();
  }

  Future<void> cancelCode() async {
    await _forget();
    step = StaffAuthStep.signedOut;
    error = null;
    notifyListeners();
  }

  Future<void> forgotPassword(String address) async {
    if (address.trim().isEmpty) {
      _fail('Enter your email first.');
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    String? limited;
    try {
      await api!.requestPasswordReset(address.trim());
    } on StaffApiException catch (failure) {
      if (failure.statusCode == 429) limited = failure.message;
    } catch (_) {}
    busy = false;
    if (limited != null) {
      error = limited;
    } else {
      notice = 'If that email is staff, a reset link is on its way.';
    }
    notifyListeners();
  }
}
