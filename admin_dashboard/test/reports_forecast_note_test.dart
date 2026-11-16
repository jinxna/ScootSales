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

void main() {
  testWidgets(
    'the Reports forecast note names a product from the latest forecast week',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: DsoTheme.light,
          home: Scaffold(
            body: ReportsHubPage(
              currentUser: _admin,
              loadOrders: (DateTime start, DateTime end) async =>
                  OrderWindowRead(
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
                rows: <Map<String, dynamic>>[
                  <String, dynamic>{
                    'productId': 'A',
                    'productName': 'Old Week Product',
                    'periodStart': '2026-10-05',
                    'generatedAt': '2026-10-05T00:00:00Z',
                  },
                  <String, dynamic>{
                    'productId': 'B',
                    'productName': 'Latest Week Product',
                    'periodStart': '2026-11-09',
                    'generatedAt': '2026-11-09T00:00:00Z',
                  },
                ],
                excludedCount: 0,
                verificationAvailable: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Latest Week Product: review saved forecast demand.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Old Week Product'), findsNothing);
    },
  );
}
