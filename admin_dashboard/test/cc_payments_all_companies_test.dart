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

class _Run {
  final Set<String> ledgers = <String>{};
  int inFlight = 0;
  int maxInFlight = 0;
  int sessionLost = 0;
}

Future<void> _drain(WidgetTester tester, _Run run) async {
  int idle = 0;
  for (int i = 0; i < 600 && idle < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    idle = run.ledgers.isNotEmpty && run.inFlight == 0 ? idle + 1 : 0;
  }
}

Future<_Run> _open(
  WidgetTester tester, {
  required int companies,
  Set<String> failing = const <String>{},
  int? status,
}) async {
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (!details.exceptionAsString().contains('overflowed')) {
      previous?.call(details);
    }
  };
  addTearDown(() => FlutterError.onError = previous);
  final _Run run = _Run();
  final MockClient client = MockClient((http.Request request) async {
    final List<String> parts = request.url.pathSegments;
    if (request.url.path == '/staff/v1/companies') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'companies': <Object?>[
            for (int i = 1; i <= companies; i++)
              <String, Object?>{
                'tenantId': 'tenant-$i',
                'legalName': 'Company $i',
                'workspace': 'w$i',
                'companyCode': 'w$i',
                'status': 'active',
                'planRef': 'standard',
              },
          ],
        }),
        200,
      );
    }
    if (parts.length == 5 && parts[4] == 'payments') {
      run.ledgers.add(parts[3]);
      run.inFlight++;
      if (run.inFlight > run.maxInFlight) run.maxInFlight = run.inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      run.inFlight--;
      if (status != null) {
        return http.Response(
          jsonEncode(<String, Object?>{'detail': 'no'}),
          status,
        );
      }
      if (failing.contains(parts[3])) {
        return http.Response(
          jsonEncode(<String, Object?>{'detail': 'boom'}),
          500,
        );
      }
      return http.Response(
        jsonEncode(<String, Object?>{'entries': <Object?>[]}),
        200,
      );
    }
    if (request.url.path.endsWith('to-check')) {
      return http.Response(
        jsonEncode(<String, Object?>{'payments': <Object?>[]}),
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
      onSessionLost: () => run.sessionLost++,
    ),
  );
  tester.view.physicalSize = const Size(1400, 1000);
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
  await tester.tap(find.text('All payments'));
  return run;
}

void main() {
  testWidgets('All payments reads the ledger of every company', (
    WidgetTester tester,
  ) async {
    final _Run run = await _open(tester, companies: 101);
    await _drain(tester, run);
    expect(run.ledgers.length, 101);
    expect(run.ledgers, contains('tenant-101'));
    expect(run.maxInFlight, lessThanOrEqualTo(8));
    expect(find.textContaining('could not be read'), findsNothing);
  });

  testWidgets('failed ledger reads are counted and can be retried', (
    WidgetTester tester,
  ) async {
    final _Run run = await _open(
      tester,
      companies: 200,
      failing: <String>{'tenant-5', 'tenant-150', 'tenant-199'},
    );
    await _drain(tester, run);
    expect(
      find.textContaining('3 companies could not be read.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a 401 stops the reads and ends the session once', (
    WidgetTester tester,
  ) async {
    final _Run run = await _open(tester, companies: 200, status: 401);
    await _drain(tester, run);
    expect(run.sessionLost, 1);
    expect(run.ledgers.length, 1);
  });

  testWidgets('Reload during a load keeps 8 or fewer reads in flight', (
    WidgetTester tester,
  ) async {
    final _Run run = await _open(tester, companies: 60);
    await tester.pump(const Duration(milliseconds: 200));
    for (int i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Reload payments'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _drain(tester, run);
    expect(run.maxInFlight, lessThanOrEqualTo(8));
    expect(run.ledgers.length, 60);
  });
}
