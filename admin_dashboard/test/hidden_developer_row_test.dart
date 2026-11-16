import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/utils/user_directory_view.dart';

void main() {
  final UserProfile admin = UserProfile.fromFirestore('admin-1', <String, dynamic>{
    'email': 'owner@scoot.test',
    'role': 'admin',
    'status': 'active',
  });

  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
    <String, dynamic>{'docId': 'dev', 'email': 'DEV.Hidden@scoot.test', 'role': 'admin'},
    <String, dynamic>{'docId': 'blank', 'email': '', 'role': 'salesman'},
    <String, dynamic>{'docId': 'sales', 'email': 'sales@scoot.test', 'role': 'salesman'},
  ];

  List<Object?> shown(String hiddenEmail) => UserDirectoryView.scopeForActor(
        rows,
        admin,
        hiddenEmail: hiddenEmail,
      ).map((Map<String, dynamic> row) => row['docId']).toList();

  test('an admin never sees the developer account named at build time', () {
    expect(shown(' dev.hidden@SCOOT.test '), <String>['blank', 'sales']);
  });

  test('with no name set, an admin sees everyone, including a row with no email', () {
    expect(shown(''), <String>['dev', 'blank', 'sales']);
  });
}
