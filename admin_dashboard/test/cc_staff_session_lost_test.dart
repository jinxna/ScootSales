import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/control_centre/staff_auth.dart';

void main() {
  test('eight concurrent 401s end the session once', () async {
    final StaffAuth auth = StaffAuth()..step = StaffAuthStep.signedIn;
    int notifications = 0;
    auth.addListener(() => notifications++);

    for (int i = 0; i < 8; i++) {
      auth.sessionLost();
    }
    await Future<void>.delayed(Duration.zero);

    expect(auth.step, StaffAuthStep.signedOut);
    expect(auth.error, 'Your session ended. Sign in again.');
    expect(notifications, 1);
  });
}
