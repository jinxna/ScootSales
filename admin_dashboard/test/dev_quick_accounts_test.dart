import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/dev/dev_accounts.dart';

void main() {
  test('dashboard quick sign-in lists the dashboard roles by role, '
      'and leaves out the salesperson', () {
    const List<DevAccount> local = <DevAccount>[
      DevAccount(label: 'One', email: 'a@scoot.test', password: 'pw1', role: 'developer'),
      DevAccount(label: 'Two', email: 'sales@scoot.test', password: 'pw2', role: 'salesman'),
      DevAccount(label: 'Three', email: 's@scoot.test', password: 'pw3', role: 'supervisor'),
      DevAccount(label: 'Four', email: 'b@scoot.test', password: 'pw4', role: 'branch manager'),
    ];
    expect(
      dashboardDevQuickAccounts(local)
          .map((DevAccount account) => '${account.label}|${account.email}|${account.role}')
          .toList(),
      <String>[
        'Admin|a@scoot.test|admin',
        'Supervisor|s@scoot.test|supervisor',
        'Branch Manager|b@scoot.test|branch_manager',
      ],
    );
  });
}
