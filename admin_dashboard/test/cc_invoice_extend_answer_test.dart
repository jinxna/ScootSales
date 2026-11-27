import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/pages/company_page.dart';
import 'package:flutter_web_app/control_centre/staff_api_client.dart';
import 'package:flutter_web_app/control_centre/store/cc_store.dart';
import 'package:flutter_web_app/control_centre/widgets/cc_nav.dart';

const String _tenant = 'tenant-one';

Map<String, Object?> _invoice(String number, {bool? canExtend}) =>
    <String, Object?>{
      'invoiceId': 'id-$number',
      'tenantId': _tenant,
      'number': number,
      'periodStart': '2026-11-01',
      'periodEnd': '2026-11-30',
      'amountMinor': 10000,
      'outstandingMinor': 10000,
      'status': 'sent',
      'dueAt': DateTime.now()
          .toUtc()
          .add(const Duration(days: 30))
          .toIso8601String(),
      'createdAt': '2026-11-01T00:00:00Z',
      if (canExtend != null) 'canExtend': canExtend,
    };

Future<void> _openCompany(
  WidgetTester tester,
  List<Map<String, Object?>> invoices,
) async {
  final MockClient client = MockClient((http.Request request) async {
    final String path = request.url.path;
    if (path == '/staff/v1/companies') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'companies': <Object?>[
            <String, Object?>{
              'tenantId': _tenant,
              'legalName': 'One Sdn Bhd',
              'workspace': 'one',
              'companyCode': 'one',
              'status': 'active',
              'planRef': 'standard',
              'lifecycleState': 'active',
            },
          ],
        }),
        200,
      );
    }
    if (path == '/staff/v1/invoices') {
      return http.Response(
        jsonEncode(<String, Object?>{'invoices': invoices}),
        200,
      );
    }
    return http.Response(jsonEncode(<String, Object?>{'detail': 'x'}), 500);
  });
  final CcStore store = CcStore(
    StaffApiClient(client: client, baseUri: Uri.parse('http://localhost')),
  );
  store.profile = const StaffProfile(
    email: 'op@b.test',
    role: 'operator',
    capabilities: <String>{'accounts.manage', 'commercial.read'},
    home: 'companies',
  );
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      home: Scaffold(
        body: CompanyPage(
          store: store,
          nav: CcNav(
            go: (_) {},
            openCompany: (String id, {int tab = 0}) {},
            openInvoice: (_) {},
            openOnboarding: (_) {},
          ),
          tenantId: _tenant,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('More'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Extend an invoice offers only the invoices the server says can be extended',
    (WidgetTester tester) async {
      await _openCompany(tester, <Map<String, Object?>>[
        _invoice('INV-REFUSED', canExtend: false),
        _invoice('INV-OLDER-SERVER'),
      ]);
      expect(find.text('Extend an invoice…'), findsNothing);

      await _openCompany(tester, <Map<String, Object?>>[
        _invoice('INV-REFUSED', canExtend: false),
        _invoice('INV-ALLOWED', canExtend: true),
      ]);
      await tester.tap(find.text('Extend an invoice…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('INV-ALLOWED'), findsWidgets);
      expect(find.textContaining('INV-REFUSED'), findsNothing);
    },
  );
}
