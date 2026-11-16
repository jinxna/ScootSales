import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/pages/onboarding_page.dart';
import 'package:flutter_web_app/control_centre/staff_api_client.dart';
import 'package:flutter_web_app/control_centre/store/cc_store.dart';
import 'package:flutter_web_app/control_centre/widgets/cc_nav.dart';

Future<void> _openDraft(
  WidgetTester tester, {
  required String role,
  required Set<String> capabilities,
  bool? canExtend,
}) async {
  final MockClient client = MockClient((http.Request request) async {
    if (request.url.path == '/staff/v1/onboarding-drafts') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'drafts': <Object?>[
            <String, Object?>{
              'draftId': 'd1',
              'status': 'open',
              'legalName': 'Two Sdn Bhd',
              'workspace': 'two',
              'createdBy': 'a@b.test',
              'createdAt': '2026-11-01T00:00:00Z',
              'endsAt': '2026-12-01T00:00:00Z',
              'steps': <Object?>[],
              if (canExtend != null) 'canExtend': canExtend,
            },
          ],
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
    capabilities: capabilities,
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
}

void main() {
  testWidgets(
    'Extend 30 days on a draft shows only when the server offers it to this person',
    (WidgetTester tester) async {
      const Set<String> owner = <String>{
        'onboarding',
        'accounts.manage',
        'owner.tools',
      };
      const Set<String> operator = <String>{'onboarding', 'accounts.manage'};
      final Finder extend = find.text('Extend 30 days');

      await _openDraft(
        tester,
        role: 'owner',
        capabilities: owner,
        canExtend: true,
      );
      expect(find.text('Two Sdn Bhd'), findsWidgets);
      expect(extend, findsOneWidget);

      await _openDraft(
        tester,
        role: 'owner',
        capabilities: owner,
        canExtend: false,
      );
      expect(extend, findsNothing);

      await _openDraft(tester, role: 'owner', capabilities: owner);
      expect(extend, findsNothing);

      await _openDraft(
        tester,
        role: 'operator',
        capabilities: operator,
        canExtend: false,
      );
      expect(extend, findsNothing);

      await _openDraft(
        tester,
        role: 'operator',
        capabilities: operator,
        canExtend: true,
      );
      expect(extend, findsOneWidget);
    },
  );
}
