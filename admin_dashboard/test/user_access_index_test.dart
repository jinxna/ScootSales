import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/security/user_access_index.dart';

void main() {
  test('clears salesman codes for every role except supervisor', () {
    final Map<String, dynamic> access = UserAccessIndex.build(
      uid: 'former-supervisor-uid',
      userDocId: 'SV02@example.test',
      email: 'sv02@example.test',
      roleRaw: 'branch_manager',
      branchId: 'B1',
      assignedSalesmanCodes: <String>['S001'],
    );

    expect(access['assignedSalesmanCodes'], isA<FieldValue>());
    expect(access['assignedSalesmanCodes'], FieldValue.delete());
  });
}
