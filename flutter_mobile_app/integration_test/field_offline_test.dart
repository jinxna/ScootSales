import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fmcg_sales/main.dart' as app;

const String stopName = 'Emart Moyan';
const String focusProduct = 'ORGANIC APPLE CIDER VINEGAR';

const Duration offlineWindow = Duration(seconds: 75);

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 60),
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

Future<bool> tapWhenEnabled(
  WidgetTester tester,
  String label, {
  Duration timeout = const Duration(seconds: 60),
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
      await tester.tap(button.first);
      return true;
    }
  }
  if (!required) return false;
  fail('Timed out waiting for the $label button to be enabled');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the assigned route keeps its focus items when the radio drops', (
    WidgetTester tester,
  ) async {
    app.main();
    await tester.pump(const Duration(seconds: 2));

    final Finder quickSignIn = find.text('Salesperson');
    await waitFor(tester, quickSignIn, label: 'the quick sign-in button');
    await tester.tap(quickSignIn);

    await waitFor(
      tester,
      find.descendant(
        of: find.byType(ScootBottomNav),
        matching: find.text('Route'),
      ),
      timeout: const Duration(seconds: 90),
      label: 'the home screen',
    );
    await waitFor(
      tester,
      find.textContaining(stopName),
      timeout: const Duration(seconds: 90),
      label: 'the published stop on the home screen',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(ScootBottomNav),
        matching: find.text('Route'),
      ),
    );
    await waitFor(
      tester,
      find.text("TODAY'S FOCUS"),
      timeout: const Duration(seconds: 90),
      label: "the TODAY'S FOCUS card",
    );
    expect(
      find.textContaining(focusProduct),
      findsWidgets,
      reason: 'the brief materialised for this stop should be shown',
    );

    await tapWhenEnabled(
      tester,
      'Accept route',
      timeout: const Duration(seconds: 20),
      required: false,
    );
    await tapWhenEnabled(tester, 'Start route');
    await tapWhenEnabled(tester, 'Open visit');
    await waitFor(
      tester,
      find.text("Today's focus"),
      timeout: const Duration(seconds: 60),
      label: 'the guided visit focus section',
    );
    expect(
      find.textContaining(focusProduct),
      findsWidgets,
      reason: 'the guided visit must carry the same materialised brief',
    );
    await tester.pageBack();
    await tester.pump(const Duration(seconds: 2));

    debugPrint('FIELD_CHECK online-passed');
    final DateTime resumeAt = DateTime.now().add(offlineWindow);
    while (DateTime.now().isBefore(resumeAt)) {
      await tester.pump(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    debugPrint('FIELD_CHECK offline-phase-start');

    expect(
      find.textContaining(stopName),
      findsWidgets,
      reason: 'the assigned stop must stay on screen offline',
    );
    expect(
      find.text("TODAY'S FOCUS"),
      findsOneWidget,
      reason: 'the focus items must stay on screen offline',
    );
    expect(
      find.textContaining(focusProduct),
      findsWidgets,
      reason: 'the focus item must stay on screen offline',
    );
    expect(
      find.text('Start route'),
      findsWidgets,
      reason: 'the visit must still be startable offline',
    );
  });
}
