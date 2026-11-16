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
  testWidgets('the Top Products tab label sits on the same line as the '
      'other Reports tabs', (WidgetTester tester) async {
    await _pumpReports(tester, const Size(1280, 1800));
    final double trend = tester.getCenter(find.text('Order Trend')).dy;
    final double products = tester.getCenter(find.text('Top Products')).dy;
    expect(products, moreOrLessEquals(trend, epsilon: 0.5));
  });
}
