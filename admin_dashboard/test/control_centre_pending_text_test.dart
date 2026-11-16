import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/pages/company_page.dart';
import 'package:flutter_web_app/control_centre/pages/packages_page.dart';
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

void main() {
  for (final (String label, String status, int code, String expected)
      in <(String, String, int, String)>[
        (
          'pending when the server answers 202',
          'pending',
          202,
          'not confirmed yet',
        ),
        (
          'failed when the server answers 200 with status failed',
          'failed',
          200,
          'The change failed',
        ),
      ]) {
    testWidgets('Retry says $label', (WidgetTester tester) async {
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
                  'services': <String, Object?>{},
                },
              ],
            }),
            200,
          );
        }
        if (path == '/staff/v1/companies/$_tenant/operations') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'operations': <Object?>[
                <String, Object?>{
                  'operationId': 'op1',
                  'action': 'company.update',
                  'status': 'pending',
                  'reason': null,
                  'createdAt': null,
                  'errorType': null,
                  'errorMessage': null,
                  'canRetry': true,
                },
              ],
            }),
            200,
          );
        }
        if (path == '/staff/v1/operations/op1/retry') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'operationId': 'op1',
              'status': status,
              'steps': <String, Object?>{
                'store_record': <String, Object?>{
                  'status': status,
                  'result': null,
                },
              },
            }),
            code,
          );
        }
        return http.Response(jsonEncode(<String, Object?>{}), 404);
      });
      final CcStore store = CcStore(
        StaffApiClient(client: client, baseUri: Uri.parse('http://localhost')),
      );
      store.profile = _owner;
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
              initialTab: CompanyTab.activity,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      final Iterable<String> snack = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Text),
            ),
          )
          .map((Text t) => t.data ?? '');
      expect(snack, isNot(contains('The operation completed.')));
      expect(snack.join(' '), contains(expected));
    });
  }

  testWidgets('first price answered 202 pending is not shown as saved', (
    WidgetTester tester,
  ) async {
    final MockClient client = MockClient((http.Request request) async {
      final String path = request.url.path;
      if (request.method == 'GET' && path == '/staff/v1/packages') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'packages': <Object?>[
              <String, Object?>{
                'planId': 'standard',
                'name': 'Standard',
                'edition': 'basic',
                'limits': <String, Object?>{'salesmen': 5},
                'prices': <String, Object?>{'monthly': null, 'yearly': null},
              },
            ],
          }),
          200,
        );
      }
      if (request.method == 'GET' && path == '/staff/v1/plans') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'plans': <Object?>[
              <String, Object?>{
                'planId': 'standard',
                'current': <String, Object?>{
                  'name': 'Standard',
                  'edition': 'basic',
                },
              },
            ],
          }),
          200,
        );
      }
      if (request.method == 'PUT' && path == '/staff/v1/plans/standard') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'operationId': 'op1',
            'status': 'pending',
            'steps': <String, Object?>{
              'store_plan': <String, Object?>{
                'status': 'pending',
                'result': null,
              },
            },
          }),
          202,
        );
      }
      return http.Response(jsonEncode(<String, Object?>{}), 404);
    });
    final CcStore store = CcStore(
      StaffApiClient(client: client, baseUri: Uri.parse('http://localhost')),
    );
    store.profile = const StaffProfile(
      email: 'owner@scoot.test',
      role: 'owner',
      capabilities: <String>{
        'owner.tools',
        'accounts.manage',
        'commercial.read',
      },
      home: 'companies',
    );
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PackagesPage(
            store: store,
            nav: CcNav(
              go: (_) {},
              openCompany: (String id, {int tab = 0}) {},
              openInvoice: (_) {},
              openOnboarding: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set price for Standard'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('first-price-monthly')),
      '300',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Reason'),
      'first price',
    );
    await tester.tap(find.text('Save price'));
    await tester.pumpAndSettle();
    final List<String> shown = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((RichText t) => t.text.toPlainText())
        .where(
          (String s) =>
              s.contains('saved') ||
              s.contains('Saved') ||
              s.contains('pending') ||
              s.contains('confirmed'),
        )
        .toList();
    expect(shown, isNot(contains('Price saved')));
    expect(shown.join(' '), contains('not confirmed yet'));
  });
}
