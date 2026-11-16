import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/login_throttle.dart';

void main() {
  test('only rejected credentials consume a local attempt', () {
    expect(isCredentialFailureCode('invalid-credential'), isTrue);
    expect(isCredentialFailureCode('wrong-password'), isTrue);
    expect(isCredentialFailureCode('user-not-found'), isTrue);
    expect(isCredentialFailureCode('network-request-failed'), isFalse);
    expect(isCredentialFailureCode('user-disabled'), isFalse);
    expect(isCredentialFailureCode('too-many-requests'), isFalse);
  });

  group('LoginThrottle', () {
    final DateTime now = DateTime.utc(2026, 9, 2, 10);

    test('locks on the third credential failure', () {
      final LoginThrottle throttle = LoginThrottle();

      expect(throttle.recordCredentialFailure(now), isNull);
      expect(throttle.remainingAttemptsAt(now), 2);
      expect(throttle.recordCredentialFailure(now), isNull);
      expect(throttle.remainingAttemptsAt(now), 1);

      expect(
        throttle.recordCredentialFailure(now),
        now.add(const Duration(minutes: 15)),
      );
      expect(throttle.remainingAttemptsAt(now), 0);
    });

    test('expired lock starts a fresh attempt window', () {
      final LoginThrottle throttle = LoginThrottle(
        failedAttempts: 3,
        lockedUntil: now.add(const Duration(minutes: 15)),
      );

      expect(
        throttle.activeLockAt(now.add(const Duration(minutes: 16))),
        isNull,
      );
      expect(throttle.failedAttempts, 0);
      expect(throttle.remainingAttemptsAt(now), 3);
    });

    test('successful sign-in reset clears failures and lock', () {
      final LoginThrottle throttle = LoginThrottle();
      throttle.recordCredentialFailure(now);
      throttle.recordCredentialFailure(now);

      throttle.reset();

      expect(throttle.failedAttempts, 0);
      expect(throttle.lockedUntil, isNull);
      expect(throttle.remainingAttemptsAt(now), 3);
    });
  });
}
