import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart' show Source;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/company_lifecycle.dart';
import '../models/user_model.dart';
import '../services/company_lifecycle_monitor.dart';
import '../services/firestore_service.dart';
import '../services/verified_profile_cache.dart';
import '../services/project_local_store.dart';
import '../services/cart_draft_cache.dart';
import '../services/guided_visit_session_store.dart';
import '../services/account_lockout_service.dart';
import '../utils/login_throttle.dart';
import '../utils/replenishment_prefill.dart';

enum AuthStatus {
  idle,
  loading,
  error,
  locked,
  missingProfile,
  suspended,
  offline,
  unavailable,
}

const String rememberedEmailKey = 'remembered_email';

const String kDeviceSignInDelayedText =
    'Sign-in is temporarily delayed on this device. Wait for the local delay or notify an admin, then try signing in again.';
const String kDeviceSignInLockedText =
    'Sign-in delayed after 3 failed attempts on this device. Wait 30 minutes or notify an admin, then try signing in again.';
const String kPasswordCheckDelayedText =
    'Too many wrong passwords. Wait 30 minutes and try again.';

Future<String?> checkPasswordWithDeviceThrottle({
  required String email,
  required Future<void> Function() verify,
  LoginThrottleStore? store,
}) async {
  final String identity = email.trim().toLowerCase();
  final LoginThrottleStore throttles = store ?? LoginThrottleStore();
  try {
    final LoginThrottle throttle = await throttles.load(identity);
    final DateTime? lockedUntil = throttle.activeLockAt(DateTime.now());
    if (lockedUntil != null) {
      if (await AccountLockoutService.instance.isUnlocked(
        email: identity,
        lockedUntil: lockedUntil,
      )) {
        await throttles.clear(identity, expectedLockedUntil: lockedUntil);
      }
      final LoginThrottle current = await throttles.load(identity);
      if (current.activeLockAt(DateTime.now()) != null) {
        return kPasswordCheckDelayedText;
      }
    }
    await verify();
    await throttles.clear(identity);
    return null;
  } on FirebaseAuthException catch (e) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
        final DateTime now = DateTime.now();
        final LoginThrottle throttle = await throttles.recordCredentialFailure(
          identity,
          now,
        );
        return throttle.activeLockAt(now) != null
            ? kPasswordCheckDelayedText
            : 'Incorrect password.';
      case 'network-request-failed':
      case 'network_error':
      case 'unavailable':
        return 'No connection. Reconnect and try again.';
      case 'too-many-requests':
        return 'Too many tries. Wait a few minutes and try again.';
      case 'user-disabled':
        return 'This account is turned off. Ask your admin.';
      default:
        return 'Could not check your password. Try again.';
    }
  } catch (_) {
    return 'Could not check your password. Try again.';
  }
}

class AuthProvider extends ChangeNotifier {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirestoreService _firestoreService = FirestoreService();
  final LoginThrottleStore _loginThrottleStore = LoginThrottleStore();
  String? _localLockEmail;
  DateTime? _localLockedUntil;

  String? get localLockEmail => _localLockEmail;
  DateTime? get localLockedUntil => _localLockedUntil;
  final VerifiedProfileCache _verifiedProfileCache = VerifiedProfileCache();

  UserModel? _user;
  AuthStatus _status = AuthStatus.idle;
  String _errorMessage = '';
  bool _isLoggedIn = false;
  bool _rememberMe = false;
  bool _initialising = true;
  int _profileRequest = 0;
  bool _credentialLoginInProgress = false;
  bool _profileRevalidationInFlight = false;

  int _sessionGeneration = 0;
  DateTime? _offlineVerifiedAt;
  Timer? _offlineRevalidationTimer;
  Timer? _onlineSessionRevalidationTimer;
  AuthStatus? _terminalAccessStatus;
  String _terminalAccessMessage = '';
  StreamSubscription<User?>? _authSubscription;
  bool get initialising => _initialising;

  UserModel? get user => _user;
  AuthStatus get status => _status;
  String get errorMessage => _errorMessage;
  bool get isLoggedIn => _isLoggedIn;
  bool get rememberMe => _rememberMe;
  bool get isOfflineVerified => _status == AuthStatus.offline;
  DateTime? get offlineVerifiedAt => _offlineVerifiedAt;

  AuthProvider() {
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _rememberMe = prefs.getBool('remember_me') ?? false;

    _authSubscription = _auth.authStateChanges().listen((
      User? firebaseUser,
    ) async {
      ProjectLocalStore.invalidateIdentity();
      CartDraftCache.resetRuntime(keepOwnerUid: firebaseUser?.uid);
      GuidedVisitSessionStore.resetRuntime();
      ReplenishmentPrefill.clear();
      if (firebaseUser != null) {
        if (_credentialLoginInProgress) return;
        await _loadUserProfile(firebaseUser);
        return;
      }
      _sessionGeneration++;
      _profileRequest++;
      _stopOfflineRevalidation();
      _stopOnlineSessionRevalidation();
      _isLoggedIn = false;
      _user = null;
      _offlineVerifiedAt = null;
      _initialising = false;
      final AuthStatus? terminalStatus = _terminalAccessStatus;
      final String terminalMessage = _terminalAccessMessage;
      _terminalAccessStatus = null;
      _terminalAccessMessage = '';
      if (terminalStatus != null) {
        _status = terminalStatus;
        _errorMessage = terminalMessage;
      } else if (_status != AuthStatus.error && _status != AuthStatus.locked) {
        _status = AuthStatus.idle;
        _errorMessage = '';
      }
      notifyListeners();
    });
  }

  Future<bool> _loadUserProfile(
    User firebaseUser, {
    bool preserveOfflineSession = false,
  }) async {
    final request = ++_profileRequest;
    final bool preserveCurrent =
        preserveOfflineSession &&
        isOfflineVerified &&
        _user?.uid.trim() == firebaseUser.uid.trim();
    if (!preserveCurrent) {
      _initialising = true;
      _isLoggedIn = false;
      _user = null;
      _offlineVerifiedAt = null;
      notifyListeners();
    }
    try {
      await CartDraftCache.initialise(uid: firebaseUser.uid);
      if (request != _profileRequest ||
          _auth.currentUser?.uid != firebaseUser.uid) {
        return false;
      }

      final Future<UserModel?> serverProfile = _firestoreService.getUser(
        firebaseUser.uid,
        source: Source.server,
      );
      serverProfile.ignore();
      VerifiedProfileReceipt? cachedReceipt;
      try {
        cachedReceipt = await _verifiedProfileCache.load(firebaseUser.uid);
      } catch (error) {
        debugPrint('Verified profile receipt could not be inspected: $error');
      }
      if (cachedReceipt != null && request == _profileRequest) {
        _applyVerifiedProfileReceipt(
          cachedReceipt,
          preserveOfflineSession: preserveOfflineSession,
        );
      }

      final userData = await serverProfile.timeout(
        cachedReceipt != null
            ? const Duration(seconds: 6)
            : const Duration(seconds: 20),
      );
      if (request != _profileRequest) return false;
      if (userData == null) {
        await _clearVerifiedProfile(firebaseUser.uid);
        if (request != _profileRequest) return false;
        _stopOfflineRevalidation();
        _stopOnlineSessionRevalidation();
        _isLoggedIn = false;
        _user = null;
        _offlineVerifiedAt = null;
        _status = AuthStatus.missingProfile;
        _errorMessage =
            'Your sign-in exists, but no salesperson profile has been assigned. Contact your administrator.';
        return false;
      }
      if (userData.uid.trim() != firebaseUser.uid.trim() ||
          !userData.hasSalespersonRole) {
        await _clearVerifiedProfile(firebaseUser.uid);
        if (request != _profileRequest) return false;
        _stopOfflineRevalidation();
        _stopOnlineSessionRevalidation();
        _isLoggedIn = false;
        _user = null;
        _offlineVerifiedAt = null;
        _status = AuthStatus.missingProfile;
        _errorMessage =
            'This sign-in is not linked to a valid salesperson profile.';
        return false;
      }
      if (!userData.hasActiveAccount) {
        await _clearVerifiedProfile(firebaseUser.uid);
        if (request != _profileRequest) return false;
        _stopOfflineRevalidation();
        _stopOnlineSessionRevalidation();
        _isLoggedIn = false;
        _user = null;
        _offlineVerifiedAt = null;
        _status = AuthStatus.suspended;
        _errorMessage =
            'This salesperson account is suspended or no longer active. Contact your administrator.';
        return false;
      }
      _receiptSave = _verifiedProfileCache.save(userData).catchError((
        Object error,
      ) {
        debugPrint('Verified profile receipt could not be saved: $error');
      });
      if (request != _profileRequest) return false;
      _stopOfflineRevalidation();
      _startOnlineSessionRevalidation();
      _user = userData;
      _isLoggedIn = true;
      _offlineVerifiedAt = null;
      _status = AuthStatus.idle;
      _errorMessage = '';
      return true;
    } on TimeoutException {
      return _restoreVerifiedProfile(firebaseUser, request);
    } on FirebaseException catch (error) {
      if (_isTransientProfileFailure(error.code)) {
        return _restoreVerifiedProfile(firebaseUser, request);
      }
      if (request != _profileRequest) return false;
      if (error.code == 'permission-denied' ||
          error.code == 'unauthenticated') {
        await _clearVerifiedProfile(firebaseUser.uid);
      }
      if (request != _profileRequest) return false;
      _stopOfflineRevalidation();
      _stopOnlineSessionRevalidation();
      _isLoggedIn = false;
      _user = null;
      _offlineVerifiedAt = null;
      _status = AuthStatus.unavailable;
      _errorMessage =
          'Your salesperson profile could not be authorised. Reconnect and retry.';
      return false;
    } catch (error) {
      debugPrint('Salesperson profile verification failed: $error');
      if (request != _profileRequest) return false;
      _stopOfflineRevalidation();
      _stopOnlineSessionRevalidation();
      _isLoggedIn = false;
      _user = null;
      _offlineVerifiedAt = null;
      _status = AuthStatus.unavailable;
      _errorMessage =
          'We could not verify your salesperson profile. Check your connection and retry.';
      return false;
    } finally {
      if (request == _profileRequest) {
        _initialising = false;
        notifyListeners();
      }
    }
  }

  Future<bool> _restoreVerifiedProfile(User firebaseUser, int request) async {
    try {
      final VerifiedProfileReceipt? receipt = await _verifiedProfileCache.load(
        firebaseUser.uid,
      );
      if (request != _profileRequest) return false;
      if (receipt != null) {
        _applyVerifiedProfileReceipt(receipt, preserveOfflineSession: true);
        return true;
      }
    } catch (error) {
      debugPrint('Verified profile receipt could not be restored: $error');
    }
    if (request != _profileRequest) return false;
    _stopOfflineRevalidation();
    _stopOnlineSessionRevalidation();
    _isLoggedIn = false;
    _user = null;
    _offlineVerifiedAt = null;
    _status = AuthStatus.unavailable;
    _errorMessage =
        'Your saved account verification is missing or expired. Reconnect to continue.';
    return false;
  }

  void _applyVerifiedProfileReceipt(
    VerifiedProfileReceipt receipt, {
    required bool preserveOfflineSession,
  }) {
    _user = receipt.user;
    _isLoggedIn = true;
    _offlineVerifiedAt = receipt.verifiedAt;
    _status = AuthStatus.offline;
    _errorMessage =
        'Using a recently verified salesperson profile while offline.';
    _startOfflineRevalidation();
    if (!preserveOfflineSession) _initialising = false;
    notifyListeners();
  }

  bool _isTransientProfileFailure(String code) => const <String>{
    'unavailable',
    'deadline-exceeded',
    'cancelled',
    'network-request-failed',
    'network_error',
  }.contains(code);

  Future<void>? _receiptSave;

  Future<void> _clearVerifiedProfile(String uid) async {
    try {
      await _receiptSave;
      await _verifiedProfileCache.clear(uid);
    } catch (error) {
      debugPrint('Verified profile receipt could not be cleared: $error');
    }
  }

  void _startOfflineRevalidation() {
    _stopOnlineSessionRevalidation();
    if (_offlineRevalidationTimer?.isActive == true) return;
    _offlineRevalidationTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(revalidateOfflineProfile()),
    );
  }

  void _stopOfflineRevalidation() {
    _offlineRevalidationTimer?.cancel();
    _offlineRevalidationTimer = null;
  }

  void _startOnlineSessionRevalidation() {
    if (_onlineSessionRevalidationTimer?.isActive == true) return;
    _onlineSessionRevalidationTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(revalidateActiveSession()),
    );
  }

  void _stopOnlineSessionRevalidation() {
    _onlineSessionRevalidationTimer?.cancel();
    _onlineSessionRevalidationTimer = null;
  }

  Future<void> revalidateActiveSession() async {
    if (_profileRevalidationInFlight ||
        !_isLoggedIn ||
        isOfflineVerified ||
        _auth.currentUser == null) {
      return;
    }
    final User current = _auth.currentUser!;
    final String currentUid = current.uid.trim();
    final int generation = _sessionGeneration;
    if (currentUid != _user?.uid.trim()) {
      if (generation == _sessionGeneration &&
          _auth.currentUser?.uid.trim() == currentUid) {
        await _revokeActiveSession(
          AuthStatus.missingProfile,
          'Your sign-in is no longer linked to this salesperson profile. Please sign in again.',
          expectedGeneration: generation,
          expectedUid: currentUid,
        );
      }
      return;
    }

    _profileRevalidationInFlight = true;
    try {
      final UserModel? userData;
      try {
        userData = await _firestoreService
            .getUser(current.uid, source: Source.server)
            .timeout(const Duration(seconds: 8));
      } on TimeoutException {
        return;
      } on FirebaseException catch (error) {
        if (_isTransientProfileFailure(error.code)) return;
        if (error.code == 'permission-denied' ||
            error.code == 'unauthenticated') {
          final CompanyLifecycle? lifecycle = await CompanyLifecycleMonitor
              .instance
              .refresh(upload: false);
          if (lifecycle != null && !lifecycle.isOpen) return;
          await _revokeActiveSession(
            AuthStatus.unavailable,
            'Your session could not be authorised. Please sign in again.',
            expectedGeneration: generation,
            expectedUid: currentUid,
          );
        }
        return;
      } catch (_) {
        return;
      }

      if (generation != _sessionGeneration ||
          !_isLoggedIn ||
          _auth.currentUser?.uid.trim() != currentUid) {
        return;
      }

      if (userData == null ||
          userData.uid.trim() != currentUid ||
          !userData.hasSalespersonRole) {
        debugPrint(
          'Profile revalidation found no usable profile; keeping the current '
          'session until the server answers definitively.',
        );
        return;
      }
      if (!userData.hasActiveAccount) {
        await _revokeActiveSession(
          AuthStatus.suspended,
          'This salesperson account is suspended or no longer active. Contact your administrator.',
          expectedGeneration: generation,
          expectedUid: currentUid,
        );
        return;
      }

      final UserModel? previous = _user;
      final bool profileChanged =
          previous == null ||
          previous.userDocId != userData.userDocId ||
          previous.employeeCode != userData.employeeCode ||
          !mapEquals(previous.toMap(), userData.toMap());
      final bool statusChanged =
          _status != AuthStatus.idle || _errorMessage.isNotEmpty;
      if (profileChanged) _user = userData;
      _status = AuthStatus.idle;
      _errorMessage = '';
      _startOnlineSessionRevalidation();
      if (profileChanged || statusChanged) notifyListeners();
    } finally {
      _profileRevalidationInFlight = false;
    }
  }

  Future<void> _revokeActiveSession(
    AuthStatus status,
    String message, {
    int? expectedGeneration,
    String? expectedUid,
  }) async {
    if (expectedGeneration != null &&
        (expectedGeneration != _sessionGeneration ||
            _auth.currentUser?.uid.trim() != expectedUid)) {
      return;
    }
    final String uid = _auth.currentUser?.uid.trim() ?? _user?.uid.trim() ?? '';
    _sessionGeneration++;
    final int revocationGeneration = _sessionGeneration;
    _profileRequest++;
    _stopOnlineSessionRevalidation();
    _stopOfflineRevalidation();
    _isLoggedIn = false;
    _user = null;
    _offlineVerifiedAt = null;
    _terminalAccessStatus = status;
    _terminalAccessMessage = message;
    _status = status;
    _errorMessage = message;
    notifyListeners();
    await _clearVerifiedProfile(uid);
    if (revocationGeneration != _sessionGeneration ||
        _auth.currentUser?.uid.trim() != uid) {
      return;
    }
    try {
      await _auth.signOut();
    } catch (error) {
      debugPrint('Authorisation session could not be signed out: $error');
    }
  }

  Future<void> revalidateOfflineProfile() async {
    if (_profileRevalidationInFlight || !isOfflineVerified) return;
    final User? current = _auth.currentUser;
    if (current == null || current.uid.trim() != _user?.uid.trim()) return;
    _profileRevalidationInFlight = true;
    try {
      await _loadUserProfile(current, preserveOfflineSession: true);
    } finally {
      _profileRevalidationInFlight = false;
    }
  }

  Future<void> retryProfile() async {
    final current = _auth.currentUser;
    if (current != null) await _loadUserProfile(current);
  }

  Future<bool> login(String email, String password) async {
    _sessionGeneration++;
    _terminalAccessStatus = null;
    _terminalAccessMessage = '';
    _status = AuthStatus.loading;
    _errorMessage = '';
    _localLockEmail = null;
    _localLockedUntil = null;
    notifyListeners();

    try {
      final String loginIdentity = email.trim().toLowerCase();
      final DateTime now = DateTime.now();
      final LoginThrottle throttle = await _loginThrottleStore.load(
        loginIdentity,
        now: now,
      );
      final DateTime? lockedUntil = throttle.activeLockAt(now);
      if (lockedUntil != null) {
        final bool released = await AccountLockoutService.instance.isUnlocked(
          email: loginIdentity,
          lockedUntil: lockedUntil,
        );
        if (released) {
          await _loginThrottleStore.clear(
            loginIdentity,
            expectedLockedUntil: lockedUntil,
          );
        }
        final LoginThrottle current = await _loginThrottleStore.load(
          loginIdentity,
        );
        final DateTime? remainingLock = current.activeLockAt(DateTime.now());
        if (remainingLock != null) {
          _localLockEmail = loginIdentity;
          _localLockedUntil = remainingLock;
          _status = AuthStatus.locked;
          _errorMessage = kDeviceSignInDelayedText;
          notifyListeners();
          return false;
        }
      }

      _credentialLoginInProgress = true;
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      await _loginThrottleStore.clear(loginIdentity);

      final firebaseUser = credential.user;
      final profileReady =
          firebaseUser != null && await _loadUserProfile(firebaseUser);
      _credentialLoginInProgress = false;
      if (!profileReady) return false;

      _status = AuthStatus.idle;
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _credentialLoginInProgress = false;
      if (e.code == 'too-many-requests') {
        _status = AuthStatus.locked;
        _errorMessage = 'Too many attempts. Please try again later.';
      } else if (isCredentialFailureCode(e.code)) {
        final String loginIdentity = email.trim().toLowerCase();
        final DateTime now = DateTime.now();
        final LoginThrottle throttle = await _loginThrottleStore
            .recordCredentialFailure(loginIdentity, now);
        if (throttle.activeLockAt(now) != null) {
          _localLockEmail = loginIdentity;
          _localLockedUntil = throttle.lockedUntil;
          _status = AuthStatus.locked;
          _errorMessage = kDeviceSignInLockedText;
        } else {
          _status = AuthStatus.error;
          final int remaining = throttle.remainingAttemptsAt(now);
          _errorMessage =
              'Invalid username or password. $remaining attempt${remaining == 1 ? '' : 's'} remaining.';
        }
      } else {
        _status = AuthStatus.error;
        switch (e.code) {
          case 'user-disabled':
            _errorMessage =
                'This account has been disabled. Contact your manager.';
            break;
          case 'network-request-failed':
          case 'network_error':
          case 'unavailable':
            _errorMessage = 'No connection. Reconnect and try again.';
            break;
          default:
            _errorMessage = 'Login failed. Please try again.';
        }
      }
      notifyListeners();
      return false;
    } catch (e) {
      _credentialLoginInProgress = false;
      _status = AuthStatus.error;
      _errorMessage = 'An error occurred. Please try again.';
      notifyListeners();
      return false;
    }
  }

  Future<bool> loginWithCustomToken(String customToken) async {
    _sessionGeneration++;
    _terminalAccessStatus = null;
    _terminalAccessMessage = '';
    _status = AuthStatus.loading;
    _errorMessage = '';
    _localLockEmail = null;
    _localLockedUntil = null;
    notifyListeners();

    try {
      _credentialLoginInProgress = true;
      final credential = await _auth.signInWithCustomToken(customToken);
      final firebaseUser = credential.user;
      final profileReady =
          firebaseUser != null && await _loadUserProfile(firebaseUser);
      _credentialLoginInProgress = false;
      if (!profileReady) return false;

      _status = AuthStatus.idle;
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _credentialLoginInProgress = false;
      _status = AuthStatus.error;
      _errorMessage = switch (e.code) {
        'user-disabled' =>
          'This account has been disabled. Contact your manager.',
        'network-request-failed' ||
        'network_error' ||
        'unavailable' => 'No connection. Reconnect and try again.',
        _ =>
          'Sign-in with the invitation failed. Sign in with your email and password.',
      };
      notifyListeners();
      return false;
    } catch (_) {
      _credentialLoginInProgress = false;
      _status = AuthStatus.error;
      _errorMessage = 'An error occurred. Please try again.';
      notifyListeners();
      return false;
    }
  }

  Future<void> notifyAdminOfLocalLock({
    required String email,
    required DateTime lockedUntil,
  }) async {
    final LoginThrottle current = await _loginThrottleStore.load(email);
    if (current.activeLockAt(DateTime.now()) != lockedUntil) {
      throw StateError('The local retry delay has expired.');
    }
    await AccountLockoutService.instance.notifyAdmin(
      email: email,
      lockedUntil: lockedUntil,
    );
  }

  Future<String?> reauthenticate(String password) async {
    final User? current = _auth.currentUser;
    final String? email = current?.email;
    if (current == null || email == null) {
      return 'You are not signed in.';
    }
    return checkPasswordWithDeviceThrottle(
      email: email,
      store: _loginThrottleStore,
      verify: () => current.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      ),
    );
  }

  Future<void> logout() async {
    final String outgoingUid =
        _auth.currentUser?.uid.trim() ?? _user?.uid.trim() ?? '';
    ProjectLocalStore.invalidateIdentity();
    CartDraftCache.resetRuntime();
    GuidedVisitSessionStore.resetRuntime();
    ReplenishmentPrefill.clear();
    _sessionGeneration++;
    _profileRequest++;
    _stopOfflineRevalidation();
    _stopOnlineSessionRevalidation();
    _terminalAccessStatus = null;
    _terminalAccessMessage = '';
    try {
      await _auth.signOut();
    } finally {
      await _clearVerifiedProfile(outgoingUid);
    }
    final prefs = await SharedPreferences.getInstance();
    if (!_rememberMe) {
      await prefs.remove('remember_me');
      await prefs.remove(rememberedEmailKey);
    }
    _isLoggedIn = false;
    _user = null;
    _offlineVerifiedAt = null;
    _status = AuthStatus.idle;
    _errorMessage = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _stopOfflineRevalidation();
    _stopOnlineSessionRevalidation();
    unawaited(_authSubscription?.cancel());
    super.dispose();
  }

  void setRememberMe(bool value) {
    _rememberMe = value;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('remember_me', value);
      if (!value) prefs.remove(rememberedEmailKey);
    });
    notifyListeners();
  }

  Future<void> updateSettings(String uid, Map<String, dynamic> settings) async {
    if (_user == null) return;
    final previous = _user!;

    _user = _user!.copyWith(
      offlineMode: settings['offlineMode'],
      gpsAutofill: settings['gpsAutofill'],
      lastWeekTemplate: settings['lastWeekTemplate'],
      pushNotifications: settings['pushNotifications'],
    );
    notifyListeners();

    try {
      await _firestoreService
          .updateUserSettings(uid, settings)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      _user = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateProfile({
    required String uid,
    required String name,
    required String displayName,
    required String initials,
    required String email,
    required String phone,
    required String territory,
    required String role,
    Uint8List? photoBytes,
    String photoExt = 'jpg',
  }) async {
    String photoUrl = _user?.photoUrl ?? '';
    if (photoBytes != null) {
      final cleanExt = photoExt.toLowerCase().replaceAll('.', '');
      final mime = cleanExt == 'png'
          ? 'image/png'
          : cleanExt == 'webp'
          ? 'image/webp'
          : 'image/jpeg';
      photoUrl = 'data:$mime;base64,${base64Encode(photoBytes)}';
    }

    final existingStaffId = _user?.staffId ?? '';
    final existingJoinedDate = _user?.joinedDate ?? '';

    final updates = {
      'staffId': existingStaffId,
      'name': name,
      'displayName': displayName,
      'initials': initials,
      'email': email,
      'phone': phone,
      'territory': territory,
      'role': role,
      'photoUrl': photoUrl,
      if (existingJoinedDate.isNotEmpty) 'joinedDate': existingJoinedDate,
    };

    await _firestoreService
        .updateUserProfile(uid, updates)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            debugPrint(
              'Profile save timed out after 30s. Check the Firebase '
              'configuration and the network.',
            );
            throw Exception(
              'Saving took too long. Check your connection and try again.',
            );
          },
        );

    if (_user != null) {
      _user = _user!.copyWith(
        name: name,
        displayName: displayName,
        initials: initials,
        email: email,
        phone: phone,
        territory: territory,
        role: role,
        photoUrl: photoUrl,
      );
      notifyListeners();
    }
  }

  Future<void> updatePhoneWithVerification({
    required String uid,
    required String currentPassword,
    required String newPhone,
  }) async {
    final firebaseUser = _auth.currentUser;
    if (firebaseUser == null || firebaseUser.email == null) {
      throw Exception('You must be logged in to change your phone number.');
    }

    final credential = EmailAuthProvider.credential(
      email: firebaseUser.email!,
      password: currentPassword,
    );
    await firebaseUser.reauthenticateWithCredential(credential);

    await _firestoreService.updateUserProfile(uid, {'phone': newPhone});

    if (_user != null) {
      _user = _user!.copyWith(phone: newPhone);
      notifyListeners();
    }
  }

  Future<void> changeEmailWithVerification({
    required String currentPassword,
    required String newEmail,
  }) async {
    final firebaseUser = _auth.currentUser;
    if (firebaseUser == null || firebaseUser.email == null) {
      throw Exception('You must be logged in to change your email.');
    }

    final credential = EmailAuthProvider.credential(
      email: firebaseUser.email!,
      password: currentPassword,
    );
    await firebaseUser.reauthenticateWithCredential(credential);

    await firebaseUser.verifyBeforeUpdateEmail(newEmail);
  }
}
