import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/account_repair_analysis.dart';

void main() {
  AccountRepairDocument user(String id, Map<String, dynamic> data) =>
      AccountRepairDocument(id: id, data: data);

  test('blocks a legacy UID-keyed profile from changing the role source', () {
    final AccountRepairReport report = AccountRepairAnalysis.analyze(
      users: <AccountRepairDocument>[
        user('U1', <String, dynamic>{'role': 'salesman', 'status': 'active'}),
        user('S0001', <String, dynamic>{
          'uid': 'U1',
          'role': 'admin',
          'status': 'active',
          'branchId': 'KCH',
          'employeeCode': 'S0001',
        }),
      ],
      accessRecords: const <AccountRepairDocument>[],
      actorUid: 'admin-uid',
    );

    final AccountRepairFinding finding = report.findings.singleWhere(
      (AccountRepairFinding item) =>
          item.kind == AccountRepairFindingKind.missingAccess,
    );
    expect(finding.canRepair, isFalse);
    expect(finding.description, contains('ambiguous'));
  });

  test('blocks a legacy UID-keyed suspended profile from reactivation', () {
    final AccountRepairReport report = AccountRepairAnalysis.analyze(
      users: <AccountRepairDocument>[
        user('U1', <String, dynamic>{
          'role': 'salesman',
          'status': 'suspended',
        }),
        user('S0001', <String, dynamic>{
          'uid': 'U1',
          'role': 'salesman',
          'status': 'active',
          'branchId': 'KCH',
          'employeeCode': 'S0001',
        }),
      ],
      accessRecords: const <AccountRepairDocument>[],
      actorUid: 'admin-uid',
    );

    final AccountRepairFinding finding = report.findings.singleWhere(
      (AccountRepairFinding item) =>
          item.kind == AccountRepairFindingKind.missingAccess,
    );
    expect(finding.canRepair, isFalse);
  });

  test('blocks duplicate UID ownership and self-targeted index creation', () {
    final AccountRepairReport duplicate = AccountRepairAnalysis.analyze(
      users: <AccountRepairDocument>[
        user('S001', <String, dynamic>{'uid': 'same-uid', 'role': 'salesman'}),
        user('S002', <String, dynamic>{
          'userUid': 'same-uid',
          'role': 'salesman',
        }),
      ],
      accessRecords: const <AccountRepairDocument>[],
      actorUid: 'admin-uid',
    );
    final List<AccountRepairFinding> duplicateFindings = duplicate.findings
        .where(
          (AccountRepairFinding issue) =>
              issue.kind == AccountRepairFindingKind.missingAccess,
        )
        .toList();
    expect(duplicateFindings, hasLength(2));
    expect(
      duplicateFindings.every((AccountRepairFinding issue) => !issue.canRepair),
      isTrue,
    );

    final AccountRepairReport self = AccountRepairAnalysis.analyze(
      users: <AccountRepairDocument>[
        user('A001', <String, dynamic>{
          'uid': 'admin-uid',
          'role': 'admin',
          'status': 'active',
        }),
      ],
      accessRecords: const <AccountRepairDocument>[],
      actorUid: 'admin-uid',
    );
    expect(self.findings.single.canRepair, isFalse);
  });
}
