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

const StaffProfile _owner = StaffProfile(
  email: 'a@b.test',
  role: 'owner',
  capabilities: <String>{'owner.tools', 'accounts.manage', 'commercial.read'},
  home: 'companies',
);

const StaffProfile _engineer = StaffProfile(
  email: 'e@b.test',
  role: 'engineer',
  capabilities: <String>{
    'companies',
    'onboarding',
    'commercial.read',
    'setup.enter',
  },
  home: 'companies',
);

Future<List<http.Request>> _open(
  WidgetTester tester,
  String menuItem, {
  StaffProfile profile = _owner,
  String? currentRulesVersion,
  List<Object?> paymentEntries = const <Object?>[],
}) async {
  final List<http.Request> sent = <http.Request>[];
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
              'version': 4,
              'location': <String, Object?>{
                'projectId': 'one-project',
                'databaseId': '(default)',
                'authTenantId': 'one-auth',
              },
              'locationKind': 'dedicated',
              'clientConfig': <String, Object?>{},
              'releaseRing': 'stable',
              'rulesVersion': 'v1',
              'currentRulesVersion': ?currentRulesVersion,
              'services': <String, Object?>{
                'copilotUrl': 'https://old.scootsales.my',
              },
            },
          ],
        }),
        200,
      );
    }
    if (request.method == 'GET' &&
        path == '/staff/v1/companies/$_tenant/payments') {
      return http.Response(
        jsonEncode(<String, Object?>{'entries': paymentEntries}),
        200,
      );
    }
    if (request.method == 'GET') {
      return http.Response(jsonEncode(<String, Object?>{}), 404);
    }
    sent.add(request);
    return http.Response(
      jsonEncode(<String, Object?>{
        'operationId': 'op1',
        'status': 'completed',
        'steps': <String, Object?>{'store_record': 'done'},
      }),
      200,
    );
  });
  final CcStore store = CcStore(
    StaffApiClient(client: client, baseUri: Uri.parse('http://localhost')),
  );
  store.profile = profile;
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
  if (menuItem.isEmpty) return sent;
  await tester.tap(find.text(menuItem));
  await tester.pumpAndSettle();
  return sent;
}

final RegExp _serverTimestamp = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$',
);

void main() {
  testWidgets('Editing the company record saves the new service address', (
    WidgetTester tester,
  ) async {
    final List<http.Request> sent = await _open(tester, 'Edit company record…');
    await tester.enterText(
      find.widgetWithText(TextField, 'Scout address'),
      'https://new.scootsales.my',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Reason'),
      'moved server',
    );
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(sent.single.method, 'PUT');
    expect(sent.single.url.path, '/staff/v1/companies/$_tenant');
    final Map<String, Object?> body =
        jsonDecode(sent.single.body) as Map<String, Object?>;
    expect(body['expectedVersion'], 4);
    expect(
      ((body['record']! as Map<String, Object?>)['services']!
          as Map<String, Object?>)['copilotUrl'],
      'https://new.scootsales.my',
    );
  });

  Future<Map<String, Object?>> saveEdit(
    WidgetTester tester, {
    required String current,
    required bool tick,
  }) async {
    final List<http.Request> sent = await _open(
      tester,
      'Edit company record…',
      currentRulesVersion: current,
    );
    final Finder box = find.byType(CheckboxListTile);
    if (tick) {
      await tester.tap(box);
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'sync');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final Map<String, Object?> body =
        jsonDecode(sent.single.body) as Map<String, Object?>;
    return body['record']! as Map<String, Object?>;
  }

  testWidgets('Ticking the rules version box saves the current build value', (
    WidgetTester tester,
  ) async {
    final Map<String, Object?> record = await saveEdit(
      tester,
      current: 'v9',
      tick: true,
    );
    expect(record['rulesVersion'], 'v9');
  });

  testWidgets('Leaving the rules version box unticked keeps the old value', (
    WidgetTester tester,
  ) async {
    final Map<String, Object?> record = await saveEdit(
      tester,
      current: 'v9',
      tick: false,
    );
    expect(record['rulesVersion'], 'v1');
  });

  testWidgets('No rules version box shows when the versions match', (
    WidgetTester tester,
  ) async {
    await _open(tester, 'Edit company record…', currentRulesVersion: 'v1');
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('No rules version box shows when the build value is unknown', (
    WidgetTester tester,
  ) async {
    await _open(tester, 'Edit company record…');
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('A quote request goes to approval with the price in sen', (
    WidgetTester tester,
  ) async {
    final List<http.Request> sent = await _open(
      tester,
      'Request a quoted price…',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Price per billing period (RM)'),
      '1250.50',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Reason'),
      'agreed by phone',
    );
    await tester.tap(find.text('Send for approval'));
    await tester.pumpAndSettle();
    expect(sent.single.url.path, '/staff/v1/approvals');
    final Map<String, Object?> body =
        jsonDecode(sent.single.body) as Map<String, Object?>;
    expect(body['action'], 'quote.price');
    expect((body['params']! as Map<String, Object?>)['amountMinor'], 125050);
  });

  testWidgets(
    'An override request sends its end time in the format the server accepts',
    (WidgetTester tester) async {
      final List<http.Request> sent = await _open(
        tester,
        'Request a package override…',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Salespeople limit'),
        '25',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Reason'),
        'busy season',
      );
      await tester.tap(find.text('Send for approval'));
      await tester.pumpAndSettle();
      expect(sent.single.url.path, '/staff/v1/approvals');
      final Map<String, Object?> body =
          jsonDecode(sent.single.body) as Map<String, Object?>;
      expect(body['action'], 'plan.override');
      final Map<String, Object?> params =
          body['params']! as Map<String, Object?>;
      expect(params['expiresAt'], matches(_serverTimestamp));
      expect((params['limits']! as Map<String, Object?>)['salesmen'], 25);
    },
  );

  testWidgets('A company with no payments says No payments on its overview', (
    WidgetTester tester,
  ) async {
    await _open(tester, '');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('No payments'), findsOneWidget);
    expect(find.text('All payments checked'), findsNothing);
  });

  testWidgets(
    'An engineer sees More with only Edit company record, and cannot rename',
    (WidgetTester tester) async {
      await _open(tester, '', profile: _engineer);
      expect(find.text('Edit company record…'), findsOneWidget);
      expect(find.text('Request a package override…'), findsNothing);
      expect(find.text('Request a quoted price…'), findsNothing);
      expect(find.text('Change package…'), findsNothing);
      await tester.tap(find.text('Edit company record…'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Scout address'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Company name'), findsNothing);
    },
  );
}
