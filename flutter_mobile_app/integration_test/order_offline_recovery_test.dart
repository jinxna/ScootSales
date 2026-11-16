import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fmcg_sales/main.dart' as app;

const String stopName = 'Emart Moyan';

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 90),
  String? label,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail(
    'Timed out waiting for ${label ?? finder.describeMatch(Plurality.many)}',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an offline draft is sent only by the explicit submit', (
    WidgetTester tester,
  ) async {
    app.main();
    await tester.pump(const Duration(seconds: 2));

    final Finder quickSignIn = find.text('Salesperson');
    final DateTime signInDeadline = DateTime.now().add(
      const Duration(seconds: 30),
    );
    while (DateTime.now().isBefore(signInDeadline) &&
        quickSignIn.evaluate().isEmpty &&
        find.textContaining(stopName).evaluate().isEmpty) {
      await tester.pump(const Duration(seconds: 1));
    }
    if (quickSignIn.evaluate().isNotEmpty) {
      await tester.tap(quickSignIn);
    }
    await waitFor(
      tester,
      find.textContaining(stopName),
      timeout: const Duration(seconds: 120),
      label: 'the home screen',
    );

    Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
    serverOrders() async {
      final String? uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) {
        return const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      }
      final QuerySnapshot<Map<String, dynamic>> snapshot =
          await FirebaseFirestore.instance
              .collection('orders')
              .where('salesmanUid', isEqualTo: uid)
              .get(const GetOptions(source: Source.server));
      return snapshot.docs
          .where(
            (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                doc.id.startsWith('ORD-V2-'),
          )
          .toList(growable: false);
    }

    final DateTime quietUntil = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(quietUntil)) {
      await tester.pump(const Duration(seconds: 1));
    }
    final int beforeSubmit = (await serverOrders()).length;
    debugPrint('FIELD_CHECK orders-before-explicit-submit=$beforeSubmit');
    expect(
      beforeSubmit,
      0,
      reason: 'reconnecting must not send an offline draft',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(ScootBottomNav),
        matching: find.text('Route'),
      ),
    );
    await tapButton(tester, 'Open visit', required: false);
    await tapButton(tester, 'Continue to sell', required: false);
    await tapButton(tester, 'Start order', required: false);
    await tapButton(tester, 'Continue to Signature', required: false);
    await tapButton(
      tester,
      'Submit Order',
      timeout: const Duration(seconds: 90),
    );
    await waitFor(
      tester,
      find.textContaining('Order Submitted Successfully'),
      label: 'the confirmation after the explicit submit',
    );

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> matches =
        await serverOrders();
    debugPrint('FIELD_CHECK orders-after-explicit-submit=${matches.length}');
    expect(
      matches,
      hasLength(1),
      reason: 'the explicit submit must create exactly one order',
    );
    final QueryDocumentSnapshot<Map<String, dynamic>> order = matches.single;
    final Map<String, dynamic> data = order.data();
    expect(data['orderId'], order.id);
    expect(
      (data['items'] as List<dynamic>?)?.isNotEmpty,
      isTrue,
      reason: 'the order must keep the draft lines',
    );
    expect(data['submittedAt'], isNotNull);
  });
}

Future<bool> tapButton(
  WidgetTester tester,
  String label, {
  Duration timeout = const Duration(seconds: 30),
  bool required = true,
}) async {
  final Finder button = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (Widget widget) => widget is ButtonStyleButton,
    ),
  );
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (button.evaluate().isEmpty) continue;
    final Widget widget = tester.widget(button.first);
    if (widget is ButtonStyleButton && widget.onPressed != null) {
      await tester.ensureVisible(button.first).catchError((Object _) {});
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(button.first);
      await tester.pump(const Duration(milliseconds: 600));
      return true;
    }
  }
  if (!required) return false;
  fail('Timed out waiting for "$label" to be enabled');
}
