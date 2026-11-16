import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/pages/onboarding_page.dart';
import 'package:flutter_web_app/control_centre/staff_api_client.dart';
import 'package:flutter_web_app/control_centre/store/cc_store.dart';
import 'package:flutter_web_app/control_centre/widgets/cc_nav.dart';
import 'package:flutter_web_app/control_centre/widgets/draft_fields.dart';

Map<String, Object?> _step(
  int n,
  String key,
  String label,
  String state, {
  Map<String, Object?>? button,
  String? operationId,
}) => <String, Object?>{
  'n': n,
  'key': key,
  'label': label,
  'state': state,
  'unknown': false,
  'fact': 'Fact for $label',
  'checkedAt': '2026-11-15T06:05:00Z',
  'button': button,
  'operationId': ?operationId,
};

Map<String, Object?> _button(String id, String label, List<String> roles) =>
    <String, Object?>{'id': id, 'label': label, 'roles': roles};

Map<String, Object?> _draft({
  List<Object?>? steps,
  String? next,
}) => <String, Object?>{
  'draftId': 'd1',
  'status': 'open',
  'phase': 'setup',
  'legalName': 'Two Sdn Bhd',
  'workspace': 'two',
  'createdBy': 'a@b.test',
  'createdAt': '2026-11-01T00:00:00Z',
  'endsAt': '2026-12-01T00:00:00Z',
  'canExtend': false,
  'tenantId': 't1',
  'adminName': 'Ada Lee',
  'adminEmail': 'ada@two.test',
  'adminEmployeeCode': 'A1',
  'lifecycleState': 'lead',
  'doneCount': 2,
  'total': 3,
  'next': <String, Object?>{'key': next ?? 'people'},
  'steps':
      steps ??
      <Object?>[
        _step(1, 'details', 'Company details', 'green'),
        _step(2, 'project', 'Firebase project', 'green'),
        _step(
          3,
          'people',
          'People and data',
          'red',
          button: _button('prepare', 'Prepare company data', <String>['owner']),
        ),
      ],
};

typedef _Route = http.Response? Function(http.Request request);

Map<String, Object?> _payment(String id, {required bool canCheck}) =>
    <String, Object?>{
      'entryId': id,
      'tenantId': 't1',
      'type': 'payment',
      'revision': 1,
      'reason': 'r',
      'createdBy': 'rec@b.test',
      'createdAt': '2026-11-10T00:00:00Z',
      'amountMinor': 10000,
      'externalReference': 'REF-$id',
      'canCheck': canCheck,
    };

Future<List<String>> _open(
  WidgetTester tester, {
  required String role,
  List<Object?>? steps,
  String? next,
  _Route? route,
}) async {
  final List<String> log = <String>[];
  final MockClient client = MockClient((http.Request request) async {
    log.add('${request.method} ${request.url.path}');
    final http.Response? custom = route?.call(request);
    if (custom != null) return custom;
    if (request.url.path == '/staff/v1/onboarding-drafts') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'drafts': <Object?>[_draft(steps: steps, next: next)],
        }),
        200,
      );
    }
    return http.Response(jsonEncode(<String, Object?>{'detail': 'x'}), 500);
  });
  final CcStore store = CcStore(
    StaffApiClient(client: client, baseUri: Uri.parse('http://localhost')),
  );
  store.profile = StaffProfile(
    email: 'me@b.test',
    role: role,
    capabilities: <String>{'onboarding', if (role == 'owner') 'owner.tools'},
    home: 'inbox',
  );
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      home: Scaffold(
        body: OnboardingPage(
          store: store,
          nav: CcNav(
            go: (_) {},
            openCompany: (String id, {int tab = 0}) {},
            openInvoice: (_) {},
            openOnboarding: (_) {},
          ),
          draftId: 'd1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return log;
}

http.Response _json(Object body, [int code = 200]) =>
    http.Response(jsonEncode(body), code);

int _draftLoads(List<String> log) =>
    log.where((String l) => l == 'GET /staff/v1/onboarding-drafts').length;

void main() {
  testWidgets('the owner sees one active button and the facts with the time', (
    WidgetTester tester,
  ) async {
    await _open(tester, role: 'owner');
    expect(find.text('Fact for People and data'), findsOneWidget);
    expect(find.text('checked 14:05'), findsWidgets);
    final Finder button = find.widgetWithText(
      FilledButton,
      'Prepare company data',
    );
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets(
    'a role that cannot press sees a greyed button and who to wait for',
    (WidgetTester tester) async {
      await _open(tester, role: 'operator');
      final Finder button = find.widgetWithText(
        FilledButton,
        'Prepare company data',
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(
        find.text('Waiting for the owner: Prepare company data.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Finish package retries the failed operation and does not open Change package',
    (WidgetTester tester) async {
      final List<String> log = await _open(
        tester,
        role: 'owner',
        next: 'package',
        steps: <Object?>[
          _step(
            4,
            'package',
            'Package',
            'red',
            button: _button('finish_package', 'Finish package', <String>[
              'owner',
            ]),
            operationId: 'op1',
          ),
        ],
        route: (http.Request request) =>
            request.url.path == '/staff/v1/operations/op1/retry'
            ? _json(<String, Object?>{
                'operationId': 'op1',
                'status': 'completed',
                'steps': <String, Object?>{
                  'subscription': <String, Object?>{
                    'status': 'done',
                    'result': null,
                  },
                },
              })
            : null,
      );
      final int loadsBefore = _draftLoads(log);
      await tester.tap(find.widgetWithText(FilledButton, 'Finish package'));
      await tester.pumpAndSettle();
      expect(log, contains('POST /staff/v1/operations/op1/retry'));
      expect(find.text('Change package'), findsNothing);
      expect(_draftLoads(log), greaterThan(loadsBefore));
      expect(find.text('Package finished.'), findsOneWidget);
    },
  );

  testWidgets('Finish package that fails says which parts are saved', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      role: 'owner',
      next: 'package',
      steps: <Object?>[
        _step(
          4,
          'package',
          'Package',
          'red',
          button: _button('finish_package', 'Finish package', <String>[
            'owner',
          ]),
          operationId: 'op1',
        ),
      ],
      route: (http.Request request) =>
          request.url.path == '/staff/v1/operations/op1/retry'
          ? _json(<String, Object?>{
              'detail': 'The company record could not be saved.',
              'parts': <String, Object?>{
                'subscription': 'saved',
                'companyLimits': 'saved',
                'companyRecord': 'pending',
              },
            }, 409)
          : null,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Finish package'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Saved: subscription and company limits. Not finished: company record.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Check again reads the facts again and does not open Connect', (
    WidgetTester tester,
  ) async {
    final List<String> log = await _open(
      tester,
      role: 'owner',
      next: 'project',
      steps: <Object?>[
        _step(
          2,
          'project',
          'Firebase project',
          'red',
          button: _button('check_again', 'Check again', <String>['owner']),
        ),
      ],
    );
    final int loadsBefore = _draftLoads(log);
    await tester.tap(find.widgetWithText(FilledButton, 'Check again'));
    await tester.pumpAndSettle();
    expect(find.text('Connect the Firebase project'), findsNothing);
    expect(_draftLoads(log), greaterThan(loadsBefore));
  });

  testWidgets(
    'Connect stays usable when the Scoot service email is not known',
    (WidgetTester tester) async {
      await _open(
        tester,
        role: 'owner',
        next: 'project',
        steps: <Object?>[
          _step(
            2,
            'project',
            'Firebase project',
            'red',
            button: _button('connect_project', 'Connect project', <String>[
              'owner',
            ]),
          ),
        ],
        route: (http.Request request) =>
            request.url.path == '/staff/v1/project-access'
            ? _json(<String, Object?>{'serviceEmail': null})
            : null,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Connect project'));
      await tester.pumpAndSettle();
      expect(find.text('Connect the Firebase project'), findsOneWidget);
      expect(
        find.textContaining('Ask the engineer for the Scoot service email'),
        findsOneWidget,
      );
      expect(
        find.text('The staff service returned an invalid response.'),
        findsNothing,
      );
      final Finder connect = find.widgetWithText(FilledButton, 'Connect');
      expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
    },
  );

  testWidgets(
    'Check payment skips an entry this person may not check and confirms the first one they may',
    (WidgetTester tester) async {
      final List<String> log = await _open(
        tester,
        role: 'owner',
        next: 'payment',
        steps: <Object?>[
          _step(
            5,
            'payment',
            'Payment',
            'red',
            button: _button('check_payment', 'Check payment', <String>[
              'owner',
            ]),
          ),
        ],
        route: (http.Request request) =>
            request.url.path == '/staff/v1/payments/to-check'
            ? _json(<String, Object?>{
                'payments': <Object?>[
                  _payment('e1', canCheck: false),
                  _payment('e2', canCheck: true),
                ],
              })
            : null,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Check payment'));
      await tester.pumpAndSettle();
      expect(find.text('Does it match the bank statement?'), findsOneWidget);
      expect(find.textContaining('REF-e2'), findsOneWidget);
      expect(find.textContaining('REF-e1'), findsNothing);
      expect(log, contains('GET /staff/v1/payments/to-check'));
    },
  );

  testWidgets(
    'Check payment with nothing this person may check shows no confirm button',
    (WidgetTester tester) async {
      await _open(
        tester,
        role: 'owner',
        next: 'payment',
        steps: <Object?>[
          _step(
            5,
            'payment',
            'Payment',
            'red',
            button: _button('check_payment', 'Check payment', <String>[
              'owner',
            ]),
          ),
        ],
        route: (http.Request request) =>
            request.url.path == '/staff/v1/payments/to-check'
            ? _json(<String, Object?>{
                'payments': <Object?>[_payment('e1', canCheck: false)],
              })
            : null,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Check payment'));
      await tester.pumpAndSettle();
      expect(find.text('Does it match the bank statement?'), findsNothing);
      expect(find.text('Matches bank statement'), findsNothing);
      expect(
        find.textContaining('Another person must check this payment'),
        findsOneWidget,
      );
    },
  );

  Future<void> openGiveAccess(
    WidgetTester tester, {
    required String role,
    required String detail,
    String? fix,
  }) async {
    await _open(
      tester,
      role: role,
      next: 'admin',
      steps: <Object?>[
        _step(
          6,
          'admin',
          'First administrator',
          'red',
          button: _button('give_access', 'Give access', <String>[
            'owner',
            'operator',
          ]),
        ),
      ],
      route: (http.Request request) =>
          request.url.path == '/staff/v1/onboarding-drafts/d1/first-admin'
          ? _json(<String, Object?>{'detail': detail, 'fix': ?fix}, 409)
          : null,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Give access').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Give access').last);
    await tester.pumpAndSettle();
  }

  const String hasOtherRole =
      'This email already has access in this company as Salesperson. Make this person the Admin, or use another email.';

  testWidgets(
    'the owner is offered to make an existing person the administrator',
    (WidgetTester tester) async {
      await openGiveAccess(
        tester,
        role: 'owner',
        detail: hasOtherRole,
        fix: 'promote_first_admin',
      );
      expect(find.text('Make this person the administrator'), findsOneWidget);
    },
  );

  testWidgets(
    'an operator is not offered to make an existing person the administrator',
    (WidgetTester tester) async {
      await openGiveAccess(
        tester,
        role: 'operator',
        detail: hasOtherRole,
        fix: 'promote_first_admin',
      );
      expect(find.textContaining('already has access'), findsOneWidget);
      expect(find.text('Make this person the administrator'), findsNothing);
    },
  );

  testWidgets('the owner is not offered the promotion for an unrelated refusal', (
    WidgetTester tester,
  ) async {
    await openGiveAccess(
      tester,
      role: 'owner',
      detail:
          'This sign-in account is turned off in the company\'s Firebase project.',
    );
    expect(find.textContaining('turned off'), findsOneWidget);
    expect(find.text('Make this person the administrator'), findsNothing);
  });

  testWidgets(
    'Edit details lets the owner change the billing email after the company exists',
    (WidgetTester tester) async {
      final GlobalKey<DraftFormFieldsState> key =
          GlobalKey<DraftFormFieldsState>();
      final StaffOnboardingDraft draft = StaffOnboardingDraft.fromJson(
        _draft(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DraftFormFields(
                key: key,
                packages: const <StaffPackage>[],
                initial: draft,
                adminOnly: true,
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Billing email'),
        'bill@two.test',
      );
      expect(key.currentState!.body()['billingEmail'], 'bill@two.test');
    },
  );
}
