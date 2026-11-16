import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/views/retailer_management_cms_page.dart';

UserProfile _user(String role) => UserProfile(
  docId: 'u-$role',
  email: '$role@example.com',
  name: role,
  role: role,
  employeeCode: 'E1',
  status: UserProfile.statusActive,
  branchId: 'BR01',
);

void main() {
  test('branch managers and supervisors cannot write retailers', () {
    expect(canWriteRetailers(_user(UserProfile.roleBranchManager)), isFalse);
    expect(canWriteRetailers(_user(UserProfile.roleSupervisor)), isFalse);
  });

  test('admin and developer keep retailer write access', () {
    expect(canWriteRetailers(_user(UserProfile.roleAdmin)), isTrue);
    expect(canWriteRetailers(_user(UserProfile.roleDeveloper)), isTrue);
  });
}
