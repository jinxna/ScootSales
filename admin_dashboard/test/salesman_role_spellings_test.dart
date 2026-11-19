import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every spelling the access rules accept is a salesperson', () {
    for (final String role in <String>[
      'salesman',
      'Salesman',
      'SALESMAN',
      'sales_representative',
      'sales representative',
      'Sales Representative',
      'Sales representative',
      'Sales_Representative',
      'SALES_REPRESENTATIVE',
      'SALES REPRESENTATIVE',
    ]) {
      expect(UserProfile.isSalesmanRole(role), isTrue, reason: role);
      expect(UserProfile.canonicalRole(role), UserProfile.roleSalesman);
    }
  });

  test('near misses the access rules refuse are not a salesperson', () {
    for (final Object? role in <Object?>[
      null,
      '',
      7,
      'sales-representative',
      ' salesman',
      'salesman ',
      'salesperson',
      'sales manager',
      'representative',
      'supervisor',
    ]) {
      expect(UserProfile.isSalesmanRole(role), isFalse, reason: '$role');
    }
  });

  test('other roles keep the access rules spelling', () {
    expect(UserProfile.canonicalRole('Administrator'), UserProfile.roleAdmin);
    expect(
      UserProfile.canonicalRole('Branch Manager'),
      UserProfile.roleBranchManager,
    );
    expect(UserProfile.canonicalRole('Supervisor'), UserProfile.roleSupervisor);
    expect(UserProfile.canonicalRole(null), '');
  });
}
