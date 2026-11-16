import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fmcg_sales/main.dart' as app;

const String stopName = 'Emart Moyan';
String visibleText(WidgetTester tester) {
  final List<String> parts = <String>[];
  for (final Element element in find.byType(Text).evaluate()) {
    final String? data = (element.widget as Text).data;
    if (data != null && data.trim().isNotEmpty) parts.add(data.trim());
  }
  return parts.join(' | ');
}

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
}) {
  return tapWhenEnabledFinder(
    tester,
    find.text(label),
    timeout: timeout,
    required: required,
  );
}

Future<bool> tapWhenEnabledFinder(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 60),
  bool required = true,
}) async {
  final Finder button = find.ancestor(
    of: finder,
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
      await tester.pump(const Duration(milliseconds: 400));
      return true;
    }
  }
  if (!required) return false;
  fail(
    'Timed out waiting for '
    '${finder.describeMatch(Plurality.many)} to be enabled'
    ' Visible text: ${visibleText(tester)}',
  );
}

Future<void> completeArrival(WidgetTester tester) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find.text('Continue to sell').evaluate().isNotEmpty ||
        find.text('Start order').evaluate().isNotEmpty) {
      return;
    }
    final Finder unverified = find.text('Record unverified');
    if (unverified.evaluate().isEmpty) continue;
    await tester.tap(unverified.first);
    await tester.pump(const Duration(milliseconds: 600));
    final Finder note = find.byType(TextField);
    if (note.evaluate().isNotEmpty) {
      await tester.enterText(
        note.first,
        'Device check: no GPS fix available in the harness.',
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
    final Finder save = find.text('Save unverified');
    if (save.evaluate().isNotEmpty) {
      await tester.tap(save.first);
      await tester.pump(const Duration(milliseconds: 800));
    }
    return;
  }
  debugPrint('FIELD_CHECK arrival-unresolved: ${visibleText(tester)}');
}

Future<void> drawSignatures(WidgetTester tester) async {
  final Finder pads = find.byWidgetPredicate(
    (Widget widget) => widget is GestureDetector && widget.onPanUpdate != null,
  );
  await waitFor(tester, pads, label: 'a signature pad');
  for (int index = 0; index < pads.evaluate().length; index++) {
    final Finder pad = pads.at(index);
    final Offset centre = tester.getCenter(pad);
    final TestGesture gesture = await tester.startGesture(
      centre - const Offset(30, 10),
    );
    for (int step = 0; step < 5; step++) {
      await gesture.moveBy(const Offset(14, 6));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 250));
  }
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an order submitted offline stays an unsent draft', (
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
      find.descendant(
        of: find.byType(ScootBottomNav),
        matching: find.text('Route'),
      ),
      timeout: const Duration(seconds: 90),
      label: 'the Route tab on the home screen',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(ScootBottomNav),
        matching: find.text('Route'),
      ),
    );
    await waitFor(tester, find.text("TODAY'S FOCUS"), label: 'the brief');
    await tapWhenEnabled(
      tester,
      'Start',
      timeout: const Duration(seconds: 30),
      required: false,
    );

    await tapWhenEnabled(
      tester,
      'Accept route',
      timeout: const Duration(seconds: 20),
      required: false,
    );
    await tapWhenEnabled(
      tester,
      'Start route',
      timeout: const Duration(seconds: 20),
      required: false,
    );
    await tapWhenEnabled(tester, 'Open visit');
    await waitFor(
      tester,
      find.text("Today's focus"),
      label: 'the guided visit',
    );

    await tapWhenEnabled(
      tester,
      'Mark arrived',
      timeout: const Duration(seconds: 45),
      required: false,
    );
    await completeArrival(tester);
    debugPrint('FIELD_CHECK arrival-step-done');
    await tapWhenEnabled(
      tester,
      'Continue to sell',
      timeout: const Duration(seconds: 45),
      required: false,
    );
    await tapWhenEnabled(
      tester,
      'Start order',
      timeout: const Duration(seconds: 60),
      required: true,
    );

    final Finder department = find.text('GROCERY');
    await waitFor(tester, department, label: 'a department to open');
    await tester.tap(department.first);
    await tester.pump(const Duration(milliseconds: 600));
    final Finder products = find.byType(CheckboxListTile);
    await waitFor(tester, products, label: 'a selectable catalogue product');
    await tester.tap(products.first);
    await tester.pump(const Duration(milliseconds: 400));
    await tapWhenEnabledFinder(tester, find.textContaining('Add to Cart'));
    await tapWhenEnabled(
      tester,
      'Confirm & Proceed',
      timeout: const Duration(seconds: 30),
    );

    await tapWhenEnabledFinder(
      tester,
      find.textContaining('Continue to Signature'),
    );
    await waitFor(
      tester,
      find.text('Submit Order'),
      label: 'the submit control',
    );
    await drawSignatures(tester);

    debugPrint('FIELD_CHECK order-ready-for-offline-submit');
    final DateTime resumeAt = DateTime.now().add(offlineWindow);
    while (DateTime.now().isBefore(resumeAt)) {
      await tester.pump(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    debugPrint('FIELD_CHECK offline-window-over');

    await tapWhenEnabled(
      tester,
      'Submit Order',
      timeout: const Duration(seconds: 90),
    );
    debugPrint('FIELD_CHECK order-submitted-offline');

    await waitFor(
      tester,
      find.textContaining('was saved on this device and was not sent'),
      timeout: const Duration(seconds: 90),
      label: 'the unsent-draft notice',
    );
    expect(find.text('Submit Order'), findsOneWidget);
    expect(find.text('Check Submission'), findsNothing);
    debugPrint('FIELD_CHECK order-kept-as-draft');

    final DateTime retryDeadline = DateTime.now().add(
      const Duration(seconds: 90),
    );
    bool resolved = false;
    while (DateTime.now().isBefore(retryDeadline) && !resolved) {
      final bool tapped = await tapWhenEnabled(
        tester,
        'Submit Order',
        timeout: const Duration(seconds: 15),
        required: false,
      );
      if (!tapped) continue;
      final DateTime step = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(step)) {
        await tester.pump(const Duration(seconds: 1));
        if (find
            .textContaining('Order Submitted Successfully')
            .evaluate()
            .isNotEmpty) {
          resolved = true;
          break;
        }
      }
    }
    if (resolved) {
      debugPrint('FIELD_CHECK explicit-submit-accepted');
      await tapWhenEnabled(
        tester,
        'View Order History',
        timeout: const Duration(seconds: 30),
        required: false,
      );
      await waitFor(
        tester,
        find.textContaining(stopName),
        timeout: const Duration(seconds: 90),
        label: 'the submitted order in history',
      );
      debugPrint('FIELD_CHECK order-visible-in-history');
    } else {
      debugPrint('FIELD_CHECK draft-still-unsent');
    }
  });
}
