import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/utils/admin_setup_checklist_state.dart';
import 'package:flutter_web_app/widgets/admin_setup_checklist.dart';

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

void main() {
  testWidgets(
    'setup steps stay readable and inside the card on a 320 wide phone',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: DsoTheme.light,
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: AdminSetupChecklist(
                currentUser: _admin,
                onNavigate: (_) {},
                loadCounts: () async => const AdminSetupChecklistCounts(
                  branches: 1,
                  activeSupervisors: 1,
                  activeSalespeopleWithBranch: 1,
                  supervisorsWithAssignedSalespeople: 1,
                  nonRetiredRetailers: 1,
                  retailersAssignedToValidSalespeople: 1,
                  visibleCategorizedProducts: 1,
                  scoreSheetSettings: 1,
                  publishedRoutes: 0,
                  aiRuns: 0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      for (final String title in <String>[
        'Publish a first route',
        'Prepare weekly insights',
      ]) {
        final Size size = tester.getSize(find.text(title));
        expect(size.width, greaterThan(100), reason: '$title is squeezed');
      }
      for (final String label in <String>['Open', 'Read the runbook']) {
        for (final Element button
            in find.widgetWithText(OutlinedButton, label).evaluate()) {
          final Rect rect = tester.getRect(find.byWidget(button.widget));
          expect(
            rect.right,
            lessThanOrEqualTo(320 - 16),
            reason: '$label runs past the card',
          );
        }
      }
    },
  );
}
