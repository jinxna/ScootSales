import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/views/reports_hub_page.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/utils/forecast_catalogue_provenance.dart';

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

Future<void> _pumpReports(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: DsoTheme.light,
      home: Scaffold(
        body: ReportsHubPage(
          currentUser: _admin,
          loadOrders: (DateTime start, DateTime end) async => OrderWindowRead(
            rows: <Map<String, dynamic>>[
              <String, dynamic>{
                'docId': 'O1',
                'retailerName': 'Shop',
                'salesmanCode': 'S1',
                'status': 'approved',
                'totalPrice': 10,
                'submittedAt': DateTime.now(),
              },
            ],
          ),
          loadForecasts: () async => const ForecastCatalogueSelection(
            rows: <Map<String, dynamic>>[],
            excludedCount: 0,
            verificationAvailable: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('on a 390 phone each Reports tile uses the full width and the '
      'switch is named for what it does', (WidgetTester tester) async {
    await _pumpReports(tester, const Size(390, 2400));
    for (final String label in <String>['Orders', 'Revenue', 'Boxes']) {
      final Size tile = tester.getSize(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      expect(tile.width, greaterThan(300), reason: '$label tile is narrow');
    }
    expect(find.text('Include rejected'), findsOneWidget);
    expect(find.text('Excluding rejected'), findsNothing);
  });

  testWidgets('a screen reader hears the Include rejected switch with its '
      'name and its on or off state', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pumpReports(tester, const Size(390, 2400));
    expect(
      tester.getSemantics(find.byType(Switch)),
      isSemantics(
        label: 'Include rejected',
        hasToggledState: true,
        isToggled: false,
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byType(Switch)),
      isSemantics(
        label: 'Include rejected',
        hasToggledState: true,
        isToggled: true,
      ),
    );
    semantics.dispose();
  });
}
