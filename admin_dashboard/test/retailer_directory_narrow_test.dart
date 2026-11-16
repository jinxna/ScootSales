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
  _FakeCms({this.status = 'Display'});

  final String status;

  @override
  Stream<List<Map<String, dynamic>>> watchCollection(
    String collection, {
    String? orderBy,
    bool descending = false,
    int? limit,
    bool coverageProbe = true,
  }) {
    return Stream<List<Map<String, dynamic>>>.value(switch (collection) {
      'branches' => <Map<String, dynamic>>[
        <String, dynamic>{'docId': 'BR01', 'branchName': 'Kuching North'},
      ],
      'retailers' => <Map<String, dynamic>>[
        <String, dynamic>{
          'docId': 'R1',
          'retailerName': 'Emart Moyan',
          'branchId': 'BR01',
          'assignedSalesmanName': 'Sara Lim',
          'status': status,
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

  for (final double width in <double>[390, 840]) {
    testWidgets(
      'every retailer column and action is on screen at $width wide',
      (WidgetTester tester) async {
        tester.view.physicalSize = Size(width, 900);
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

        expect(tester.takeException(), isNull);
        void onScreen(Finder finder, String what) {
          expect(finder, findsWidgets, reason: '$what is missing');
          final Rect rect = tester.getRect(finder.first);
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$what is cut');
          expect(rect.right, lessThanOrEqualTo(width), reason: '$what is cut');
        }

        for (final String text in <String>[
          'List',
          'Map',
          'Coverage',
          'Emart Moyan',
          'Kuching North',
          'Sara Lim',
          'Active',
          'Edit',
          'Remove',
        ]) {
          onScreen(find.textContaining(text), text);
        }
        onScreen(find.textContaining('Not recorded'), 'Last visit');
        onScreen(
          find.textContaining('Next planned visit'),
          'Next planned visit',
        );
        for (final String action in <String>['Memory', 'Replenishment']) {
          final Finder finder = find.text(action);
          if (finder.evaluate().isNotEmpty) onScreen(finder, action);
        }

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 13));
      },
    );
  }

  testWidgets('a retailer stored as inactive shows as Inactive, not Active', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(840, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: DsoTheme.light,
        home: Scaffold(
          body: RetailerManagementCmsPage(
            currentUser: _admin,
            onOpenRoutePlanner: () {},
            repository: _FakeCms(status: 'inactive'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.text('Emart Moyan'), findsWidgets);
    expect(find.text('Inactive'), findsOneWidget);
    expect(find.text('Active'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 13));
  });
}
