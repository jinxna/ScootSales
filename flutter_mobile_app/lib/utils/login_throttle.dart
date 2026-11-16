import 'package:shared_preferences/shared_preferences.dart';

bool isCredentialFailureCode(String code) =>
    code == 'invalid-credential' ||
    code == 'wrong-password' ||
    code == 'user-not-found';

class LoginThrottle {
  LoginThrottle({
    this.maxFailures = 3,
    this.lockoutDuration = const Duration(minutes: 30),
    int failedAttempts = 0,
    DateTime? lockedUntil,
  }) : assert(maxFailures > 0),
       assert(!lockoutDuration.isNegative),
       _failedAttempts = failedAttempts.clamp(0, maxFailures),
       _lockedUntil = lockedUntil;

  final int maxFailures;
  final Duration lockoutDuration;

  int _failedAttempts;
  DateTime? _lockedUntil;

  int get failedAttempts => _failedAttempts;
  DateTime? get lockedUntil => _lockedUntil;

  DateTime? activeLockAt(DateTime now) {
    final DateTime? until = _lockedUntil;
    if (until == null) return null;
    if (now.isBefore(until)) return until;
    reset();
    return null;
  }

  DateTime? recordCredentialFailure(DateTime now) {
    final DateTime? active = activeLockAt(now);
    if (active != null) return active;

    _failedAttempts += 1;
    if (_failedAttempts >= maxFailures) {
      _failedAttempts = maxFailures;
      _lockedUntil = now.add(lockoutDuration);
    }
    return _lockedUntil;
  }

  int remainingAttemptsAt(DateTime now) {
    if (activeLockAt(now) != null) return 0;
    final int remaining = maxFailures - _failedAttempts;
    return remaining < 0 ? 0 : remaining;
  }

  void reset() {
    _failedAttempts = 0;
    _lockedUntil = null;
  }
}

class LoginThrottleStore {
  Future<LoginThrottle> load(String identity, {DateTime? now}) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String keySuffix = _identityKey(identity);
    final String failureCountKey = 'login_throttle_${keySuffix}_failures';
    final String lockedUntilKey = 'login_throttle_${keySuffix}_until_ms';
    final int failedAttempts = preferences.getInt(failureCountKey) ?? 0;
    final int lockedUntilMs = preferences.getInt(lockedUntilKey) ?? 0;
    final LoginThrottle throttle = LoginThrottle(
      failedAttempts: failedAttempts,
      lockedUntil: lockedUntilMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(lockedUntilMs)
          : null,
    );
    if (throttle.activeLockAt(now ?? DateTime.now()) == null &&
        (failedAttempts != throttle.failedAttempts || lockedUntilMs > 0)) {
      await _save(preferences, identity, throttle);
    }
    return throttle;
  }

  Future<LoginThrottle> recordCredentialFailure(
    String identity,
    DateTime now,
  ) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LoginThrottle throttle = await load(identity, now: now);
    throttle.recordCredentialFailure(
      DateTime.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch),
    );
    await _save(preferences, identity, throttle);
    return throttle;
  }

  Future<void> clear(String identity, {DateTime? expectedLockedUntil}) async {
    if (expectedLockedUntil != null &&
        (await load(identity)).lockedUntil != expectedLockedUntil) {
      return;
    }
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String keySuffix = _identityKey(identity);
    await preferences.remove('login_throttle_${keySuffix}_failures');
    await preferences.remove('login_throttle_${keySuffix}_until_ms');
  }

  Future<void> _save(
    SharedPreferences preferences,
    String identity,
    LoginThrottle throttle,
  ) async {
    final String keySuffix = _identityKey(identity);
    final String failureCountKey = 'login_throttle_${keySuffix}_failures';
    final String lockedUntilKey = 'login_throttle_${keySuffix}_until_ms';
    await preferences.setInt(failureCountKey, throttle.failedAttempts);
    final DateTime? lockedUntil = throttle.lockedUntil;
    if (lockedUntil == null) {
      await preferences.remove(lockedUntilKey);
    } else {
      await preferences.setInt(
        lockedUntilKey,
        lockedUntil.millisecondsSinceEpoch,
      );
    }
  }

  String _identityKey(String identity) {
    int hash = 0x811c9dc5;
    for (final int codeUnit in identity.trim().toLowerCase().codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
