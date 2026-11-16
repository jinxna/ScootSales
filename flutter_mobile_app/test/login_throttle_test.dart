import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/login_throttle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoginThrottle', () {
    final DateTime now = DateTime.utc(2026, 9, 2, 10);

    test('locks on the third credential failure', () {
      final LoginThrottle throttle = LoginThrottle();

      throttle.recordCredentialFailure(now);
      throttle.recordCredentialFailure(now);
      expect(
        throttle.recordCredentialFailure(now),
        now.add(const Duration(minutes: 30)),
      );
      expect(throttle.remainingAttemptsAt(now), 0);
    });
  });
}
