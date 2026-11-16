import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';

void main() {
  test('email cannot grant developer role without an explicit stored role', () {
    final UserProfile profile = UserProfile.fromFirestore('sales-1', {
      'email': 'admin01@scoot-ops.test',
      'role': 'salesman',
      'status': 'active',
    });

    expect(profile.role, UserProfile.roleSalesman);
    expect(profile.isDeveloper, isFalse);
    expect(profile.canUseWebDashboard, isFalse);
  });

  test('explicit developer role remains available to the stored profile', () {
    final UserProfile profile = UserProfile.fromFirestore('admin-1', {
      'email': 'admin01@scoot-ops.test',
      'role': 'developer',
      'status': 'active',
    });

    expect(profile.isDeveloper, isTrue);
    expect(profile.canUseWebDashboard, isTrue);
  });
}
