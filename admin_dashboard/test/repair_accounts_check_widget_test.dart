import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/repositories/account_repair_repository.dart';
import 'package:flutter_web_app/utils/account_repair_analysis.dart';
import 'package:flutter_web_app/widgets/repair_accounts_check.dart';

void main() {
  UserProfile actor({String role = UserProfile.roleAdmin}) => UserProfile(
    docId: 'A001',
    uid: 'admin-uid',
    email: 'admin@example.test',
    name: 'Admin',
    role: role,
    employeeCode: 'A001',
    status: UserProfile.statusActive,
  );

  testWidgets('does not expose the check to a non-admin', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepairAccountsCheck(
            currentUser: actor(role: UserProfile.roleSupervisor),
            repository: _FakeRepository(),
          ),
        ),
      ),
    );

    expect(find.text('Repair accounts'), findsNothing);
    expect(find.text('Scan accounts'), findsNothing);
  });
}

class _FakeRepository implements AccountRepairRepository {
  _FakeRepository();

  int scanCalls = 0;

  @override
  Future<AccountRepairReport> scan({required UserProfile actor}) async {
    scanCalls++;
    return AccountRepairReport(findings: const <AccountRepairFinding>[]);
  }

  @override
  Future<void> repair(
    AccountRepairFinding finding, {
    required UserProfile actor,
  }) async {}
}
