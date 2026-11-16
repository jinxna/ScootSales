bool isCredentialFailureCode(String code) =>
    code == 'invalid-credential' ||
    code == 'wrong-password' ||
    code == 'user-not-found';

class LoginThrottle {
  LoginThrottle({
    this.maxFailures = 3,
    this.lockoutDuration = const Duration(minutes: 15),
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
