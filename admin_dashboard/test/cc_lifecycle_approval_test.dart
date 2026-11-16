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

Map<String, Object?> _lifecycle(
  String state,
  List<String> next, {
  String? retentionEndsAt,
}) => <String, Object?>{
  'lifecycle': <String, Object?>{
    'tenantId': _tenant,
    'state': state,
    'revision': 3,
    'stateSince': '2026-11-01T00:00:00Z',
    'graceEndsAt': null,
    'windowEndsAt': null,
    'retentionEndsAt': retentionEndsAt,
    'reason': 'test',
    'ticket': null,
    'updatedBy': 'a@b.test',
    'updatedAt': '2026-11-01T00:00:00Z',
    'lastOperationId': 'op1',
    'activationReceiptId': null,
  },
  'projection': null,
  'allowedNext': next,
};

Future<List<String>> _changeStatusTo(
  WidgetTester tester, {
  required String from,
  required List<String> next,
  required String choice,
  String? retentionEndsAt,
  bool settle = true,
}) async {
  final List<String> calls = <String>[];
  final MockClient client = MockClient((http.Request request) async {
    calls.add('${request.method} ${request.url.path}');
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
              'lifecycleState': from,
            },
          ],
        }),
        200,
      );
    }
    if (path == '/staff/v1/companies/$_tenant/lifecycle' &&
        request.method == 'GET') {
      return http.Response(
        jsonEncode(_lifecycle(from, next, retentionEndsAt: retentionEndsAt)),
        200,
      );
    }
    if (path == '/staff/v1/companies/$_tenant/payments' &&
        request.method == 'GET') {
      final DateTime now = DateTime.now().toUtc();
      return http.Response(
        jsonEncode(<String, Object?>{
          'cover': <String, Object?>{
            'coveringEntryIds': <String>['pay1'],
          },
          'entries': <Object?>[
            <String, Object?>{
              'entryId': 'pay1',
              'tenantId': _tenant,
              'type': 'payment',
              'reason': 'paid',
              'createdBy': 'a@b.test',
              'createdAt': now.toIso8601String(),
              'amountMinor': 10000,
              'invoiceReference': 'INV-1',
              'receivedAt': now.toIso8601String(),
              'periodStart': now
                  .subtract(const Duration(days: 1))
                  .toIso8601String(),
              'periodEnd': now.add(const Duration(days: 30)).toIso8601String(),
            },
          ],
        }),
        200,
      );
    }
    if (request.method == 'PUT') {
      return http.Response(jsonEncode(<String, Object?>{'detail': 'x'}), 409);
    }
    return http.Response(jsonEncode(<String, Object?>{'detail': 'x'}), 500);
  });
  final CcStore store = CcStore(
    StaffApiClient(client: client, baseUri: Uri.parse('http://localhost')),
  );
  store.profile = const StaffProfile(
    email: 'a@b.test',
    role: 'owner',
    capabilities: <String>{'accounts.manage', 'commercial.read'},
    home: 'companies',
  );
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
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
  await tester.tap(find.text('Change status…'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButtonFormField<String>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(choice).last);
  await tester.pumpAndSettle();
  if (choice == 'Active') {
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('INV-1').last);
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byType(TextField).last, 'because');
  await tester.tap(
    find.text('Send for approval').evaluate().isNotEmpty
        ? find.text('Send for approval')
        : find.text('Apply change'),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 500));
  }
  return calls;
}

void main() {
  testWidgets('Expired from past due goes to the expire approval', (
    WidgetTester tester,
  ) async {
    final List<String> calls = await _changeStatusTo(
      tester,
      from: 'past_due',
      next: <String>['active', 'suspended', 'expired'],
      choice: 'Expired',
    );
    expect(calls, contains('POST /staff/v1/approvals'));
    expect(calls.where((String c) => c.startsWith('PUT')), isEmpty);
  });

  testWidgets('Reactivating after the data window warns first', (
    WidgetTester tester,
  ) async {
    final List<String> calls = await _changeStatusTo(
      tester,
      from: 'expired',
      next: <String>['active', 'cancelled'],
      choice: 'Active',
      retentionEndsAt: '2026-10-01T00:00:00Z',
      settle: false,
    );
    expect(
      find.textContaining(
        'The data window ended on 1 Oct 2026. Data may be deleted. '
        'Reactivate anyway?',
      ),
      findsOneWidget,
    );
    expect(calls, isNot(contains('POST /staff/v1/approvals')));
    await tester.tap(find.text('Reactivate anyway'));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /staff/v1/approvals'));
  });
}
