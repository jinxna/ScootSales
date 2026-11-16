import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/views/retailer_management_cms_page.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:scoot_design/scoot_design.dart';

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
  _FakeCms(this.retailers);

  final Stream<List<Map<String, dynamic>>> retailers;

  @override
  Stream<List<Map<String, dynamic>>> watchCollection(
    String collection, {
    String? orderBy,
    bool descending = false,
    int? limit,
    bool coverageProbe = true,
  }) {
    if (collection == 'retailers') return retailers;
    return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Stream<List<Map<String, dynamic>>> retailers,
  ) async {
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
            repository: _FakeCms(retailers),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 13));
  }

  testWidgets('the retailer directory says it is empty only after the read '
      'finished with no rows', (WidgetTester tester) async {
    final StreamController<List<Map<String, dynamic>>> waiting =
        StreamController<List<Map<String, dynamic>>>();
    addTearDown(waiting.close);
    await pumpPage(tester, waiting.stream);
    expect(find.text('No retailers yet.'), findsNothing);
    expect(find.byType(ScootLoadingState), findsOneWidget);
    await close(tester);

    await pumpPage(
      tester,
      Stream<List<Map<String, dynamic>>>.error(StateError('read failed')),
    );
    expect(find.text('No retailers yet.'), findsNothing);
    expect(find.byType(ScootErrorState), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await close(tester);

    await pumpPage(
      tester,
      Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]),
    );
    expect(find.text('No retailers yet.'), findsOneWidget);
    expect(find.byType(ScootErrorState), findsNothing);
    await close(tester);
  });
}
