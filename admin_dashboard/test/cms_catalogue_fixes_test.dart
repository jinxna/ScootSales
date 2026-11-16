import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/views/branch_management_cms_page.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/utils/safe_doc_id.dart';

class _FakeBranchStore implements BranchStore {
  _FakeBranchStore({List<Map<String, dynamic>>? branches})
    : _branches = branches ?? <Map<String, dynamic>>[];

  final List<Map<String, dynamic>> _branches;
  final List<String> created = <String>[];

  @override
  Stream<List<Map<String, dynamic>>> watchUsers() =>
      Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);

  @override
  Stream<List<Map<String, dynamic>>> watchBranches() =>
      Stream<List<Map<String, dynamic>>>.value(_branches);

  @override
  Future<void> createBranch(String docId, Map<String, dynamic> data) async {
    created.add(docId);
  }

  @override
  Future<void> updateBranch(String docId, Map<String, dynamic> data) async {}
}

const UserProfile _admin = UserProfile(
  docId: 'a',
  email: 'a@x.test',
  name: 'Admin',
  role: 'admin',
  employeeCode: 'A1',
  status: UserProfile.statusActive,
  uid: 'uid-a',
  branchId: '',
  assignedSalesmanCodes: <String>[],
);

Widget _host(Widget child) => MaterialApp(
  theme: DsoTheme.light,
  home: Scaffold(body: SizedBox(width: 1300, height: 900, child: child)),
);

void main() {
  group('safeDocId', () {
    test('slashes, dots and backslashes never reach the id', () {
      final String id = safeDocId('A/B\\C ../D');
      expect(id, matches(RegExp(r'^[a-z0-9_-]+$')));
      expect(id.contains('/'), isFalse);
    });
  });

  group('branch page save', () {
    testWidgets('a duplicate name is blocked with an Open it action', (
      WidgetTester tester,
    ) async {
      final _FakeBranchStore store = _FakeBranchStore(
        branches: <Map<String, dynamic>>[
          <String, dynamic>{'docId': 'kuching', 'branchName': 'Kuching'},
        ],
      );
      await tester.pumpWidget(
        _host(BranchManagementCmsPage(currentUser: _admin, store: store)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, ' kuching ');
      await tester.tap(find.text('Save Branch'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(find.text('Open it'), findsOneWidget);
      expect(store.created, isEmpty);
    });
  });
}
