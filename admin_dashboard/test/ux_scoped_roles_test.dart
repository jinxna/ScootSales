import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/views/route_planner/route_plan_workspace.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';

UserProfile _profile(
  String role, {
  List<String> codes = const <String>[],
  String branchId = 'B1',
}) => UserProfile(
  docId: 'd',
  uid: 'u-$role',
  email: '$role@example.test',
  name: role,
  role: role,
  employeeCode: 'E1',
  status: 'active',
  branchId: branchId,
  assignedSalesmanCodes: codes,
);

Future<void> _pumpFooter(WidgetTester tester, {required bool readOnly}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RoutePlanFooter(
            status: 'draft',
            title: 'Draft',
            message: 'Not assigned yet',
            saved: true,
            saving: false,
            readOnly: readOnly,
            onSave: () {},
            onApprove: () {},
            onPublish: () {},
            onWithdraw: () {},
            onBackToDraft: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('route planner footer', () {
    testWidgets('hides the actions and explains why when read-only', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      await _pumpFooter(tester, readOnly: true);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Publish'), findsNothing);
      expect(find.text('Save changes'), findsNothing);
      expect(find.text('View only'), findsOneWidget);
    });
  });

  group('view-only branch manager', () {
    test('cannot change a tracking mode; admin and own supervisor can', () {
      final UserProfile manager = _profile(UserProfile.roleBranchManager);
      final UserProfile admin = _profile(UserProfile.roleAdmin);
      final UserProfile supervisor = _profile(
        UserProfile.roleSupervisor,
        codes: <String>['S001'],
      );
      expect(CmsRepository.canChangeTrackingModeFor(manager, 'S001'), isFalse);
      expect(CmsRepository.canChangeTrackingModeFor(admin, 'S001'), isTrue);
      expect(
        CmsRepository.canChangeTrackingModeFor(supervisor, 'S001'),
        isTrue,
      );
      expect(
        CmsRepository.canChangeTrackingModeFor(supervisor, 'S002'),
        isFalse,
      );
    });
  });
}
