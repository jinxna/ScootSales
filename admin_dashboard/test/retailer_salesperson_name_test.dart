import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/views/retailer_management_cms_page.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';

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

class _FakeCms extends CmsRepository {
  @override
  Stream<List<Map<String, dynamic>>> watchCollection(
    String collection, {
    String? orderBy,
    bool descending = false,
    int? limit,
    bool coverageProbe = true,
  }) {
    return Stream<List<Map<String, dynamic>>>.value(switch (collection) {
      'users' => <Map<String, dynamic>>[
        <String, dynamic>{
          'docId': 'u1',
          'uid': 'uid-s1',
          'name': 'Sara Lim',
          'role': 'salesman',
          'employeeCode': 'S001',
        },
      ],
      'retailers' => <Map<String, dynamic>>[
        <String, dynamic>{
          'docId': 'R1',
          'retailerName': 'Emart Moyan',
          'assignedSalesmanId': 'S001',
          'status': 'Display',
        },
        <String, dynamic>{
          'docId': 'R2',
          'retailerName': 'Choice Tabuan',
          'assignedSalesmanId': 'S999',
          'status': 'Display',
        },
      ],
      _ => <Map<String, dynamic>>[],
    });
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  });

  testWidgets('a retailer shows the salesperson name with the code, and '
      'keeps a code nobody matches', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: DsoTheme.light,
        home: Scaffold(
          body: RetailerManagementCmsPage(
            currentUser: _admin,
            onOpenRoutePlanner: () {},
            repository: _FakeCms(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Sara Lim (S001)'), findsOneWidget);
    expect(find.textContaining('S999'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 13));
  });
}
