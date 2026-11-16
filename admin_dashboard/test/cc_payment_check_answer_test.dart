import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/staff_api_client.dart';
import 'package:flutter_web_app/control_centre/store/cc_store.dart';
import 'package:flutter_web_app/control_centre/widgets/payment_actions.dart';

Future<void> _show(
  WidgetTester tester, {
  required String role,
  required String me,
  required String recordedBy,
  bool? canCheck,
}) async {
  final CcStore store = CcStore(
    StaffApiClient(
      client: MockClient((_) async => http.Response('{}', 500)),
      baseUri: Uri.parse('http://localhost'),
      headers: () async => <String, String>{'X-Staff-Session': 's'},
      onSessionLost: () {},
    ),
  );
  store.profile = StaffProfile.fromJson(<String, Object?>{
    'email': me,
    'role': role,
    'capabilities': <String>['payments'],
    'home': 'inbox',
  });
  final StaffPaymentEntry entry = StaffPaymentEntry.fromJson(<String, Object?>{
    'entryId': 'e1',
    'tenantId': 'tenant-a',
    'type': 'payment',
    'reason': 'Bank transfer',
    'createdBy': recordedBy,
    'createdAt': '2026-11-08T00:00:00Z',
    'amountMinor': 1000,
    if (canCheck != null) 'canCheck': canCheck,
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PaymentActionButtons(
          key: UniqueKey(),
          store: store,
          entry: entry,
          onDone: () {},
          showVoid: false,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'the payment check button follows the server answer for a solo owner, an operator and an older server',
    (WidgetTester tester) async {
      final Finder check = find.widgetWithText(
        FilledButton,
        'Matches bank statement',
      );
      const String hint = 'You recorded it, so another person checks it.';

      await _show(
        tester,
        role: 'owner',
        me: 'owner@example.com',
        recordedBy: 'owner@example.com',
        canCheck: true,
      );
      expect(tester.widget<FilledButton>(check).onPressed, isNotNull);
      expect(find.text(hint), findsNothing);

      await _show(
        tester,
        role: 'operator',
        me: 'op@example.com',
        recordedBy: 'op@example.com',
        canCheck: false,
      );
      expect(tester.widget<FilledButton>(check).onPressed, isNull);
      expect(find.text(hint), findsOneWidget);

      await _show(
        tester,
        role: 'operator',
        me: 'op@example.com',
        recordedBy: 'other@example.com',
        canCheck: false,
      );
      expect(tester.widget<FilledButton>(check).onPressed, isNull);
      expect(find.text(hint), findsNothing);

      await _show(
        tester,
        role: 'operator',
        me: 'op@example.com',
        recordedBy: 'other@example.com',
      );
      expect(check, findsNothing);
    },
  );
}
