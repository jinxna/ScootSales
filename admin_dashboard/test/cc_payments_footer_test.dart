import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/pages/payments_page.dart';
import 'package:flutter_web_app/control_centre/staff_api_client.dart';
import 'package:flutter_web_app/control_centre/store/cc_store.dart';
import 'package:flutter_web_app/control_centre/widgets/cc_nav.dart';

Future<void> _open(WidgetTester tester, {required bool canCheck}) async {
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (!details.exceptionAsString().contains('overflowed')) {
      previous?.call(details);
    }
  };
  addTearDown(() => FlutterError.onError = previous);
  final MockClient client = MockClient((http.Request request) async {
    if (request.url.path.endsWith('to-check')) {
      return http.Response(
        jsonEncode(<String, Object?>{
          'payments': <Object?>[
            <String, Object?>{
              'entryId': 'pay_1',
              'tenantId': 'tenant-1',
              'type': 'payment',
              'revision': 1,
              'reason': 'Bank transfer',
              'createdBy': 'owner@scoot.test',
              'createdAt': '2026-11-01T00:00:00Z',
              'amountMinor': 1000,
              'canCheck': canCheck,
            },
          ],
        }),
        200,
      );
    }
    return http.Response(jsonEncode(<String, Object?>{}), 500);
  });
  final CcStore store = CcStore(
    StaffApiClient(
      client: client,
      baseUri: Uri.parse('http://localhost'),
      headers: () async => <String, String>{'X-Staff-Session': 's'},
      onSessionLost: () {},
    ),
  );
  store.profile = const StaffProfile(
    email: 'owner@scoot.test',
    role: 'owner',
    capabilities: <String>{},
    home: 'home',
  );
  tester.view.physicalSize = const Size(2000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PaymentsPage(
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
}

void main() {
  testWidgets('solo owner is told they can check their own payment', (
    WidgetTester tester,
  ) async {
    await _open(tester, canCheck: true);
    expect(
      find.textContaining('can check a payment you recorded'),
      findsOneWidget,
    );
    expect(find.textContaining('never checks it'), findsNothing);
  });

  testWidgets('other staff are told the recorder never checks', (
    WidgetTester tester,
  ) async {
    await _open(tester, canCheck: false);
    expect(find.textContaining('never checks it'), findsOneWidget);
  });
}
