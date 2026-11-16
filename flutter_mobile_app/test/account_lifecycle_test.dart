import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/user_model.dart';

void main() {
  UserModel userFrom(Map<String, dynamic> overrides) {
    return UserModel.fromMap({
      'name': 'Test Salesperson',
      'email': 'sales@example.com',
      ...overrides,
    }, 'uid-1');
  }

  test('suspended and removed profiles are rejected', () {
    expect(userFrom({'accountStatus': 'suspended'}).hasActiveAccount, isFalse);
    expect(userFrom({'status': 'removed'}).hasActiveAccount, isFalse);
  });

  test('string false does not accidentally become an active account', () {
    expect(userFrom({'isActive': 'false'}).hasActiveAccount, isFalse);
  });

  test('dashboard roles are not accepted as mobile salesperson roles', () {
    expect(userFrom({'role': 'admin'}).hasSalespersonRole, isFalse);
    expect(userFrom({'role': 'salesman'}).hasSalespersonRole, isTrue);
    expect(
      userFrom({'role': 'sales_representative'}).hasSalespersonRole,
      isTrue,
    );
  });
}
