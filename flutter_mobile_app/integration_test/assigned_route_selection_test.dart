import 'dart:convert';

import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fmcg_sales/main.dart' as app;

const String _routePlanId = 'route-selection-e2e';
const String _stopAId = 'selection-stop-a';
const String _stopBId = 'selection-stop-b';
const String _stopAName = 'QA Select Retailer A';
const String _stopBName = 'QA Select Retailer B';

String _visibleText(WidgetTester tester) {
  return find
      .byType(Text)
      .evaluate()
      .map((Element element) => (element.widget as Text).data ?? '')
      .where((String value) => value.trim().isNotEmpty)
      .join(' | ');
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required Duration timeout,
  required String label,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for $label. Visible text: ${_visibleText(tester)}');
}

Future<void> _scrollIntoView(WidgetTester tester, Finder target) async {
  Finder? verticalScrollable;
  for (final Element element
      in find
          .ancestor(of: target, matching: find.byType(Scrollable))
          .evaluate()) {
    final Widget widget = element.widget;
    if (widget is Scrollable && widget.axisDirection == AxisDirection.down) {
      verticalScrollable = find.byWidget(widget);
      break;
    }
  }
  if (verticalScrollable == null) {
    fail(
      'No vertical scrollable contains ${target.describeMatch(Plurality.one)}.',
    );
  }
  await tester.scrollUntilVisible(
    target,
    350,
    scrollable: verticalScrollable,
    maxScrolls: 20,
  );
  await tester.pumpAndSettle();
}

Future<void> _waitForSelectedDestination(
  WidgetTester tester,
  String retailerName,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find.text('No stop selected').evaluate().isEmpty &&
        find.text('Selected destination').evaluate().length >= 2) {
      final Finder summary = find
          .ancestor(
            of: find.text('Selected destination').first,
            matching: find.byType(Container),
          )
          .first;
      if (find
          .descendant(of: summary, matching: find.text(retailerName))
          .evaluate()
          .isNotEmpty) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(
    'The selected destination UI did not settle on $retailerName. '
    'Visible text: ${_visibleText(tester)}',
  );
}

Future<Map<String, dynamic>?> _readProgress(String uid) async {
  final QuerySnapshot<Map<String, dynamic>> snapshot = await FirebaseFirestore
      .instance
      .collection('route_plan_progress')
      .where('planId', isEqualTo: _routePlanId)
      .where('salesmanUid', isEqualTo: uid)
      .limit(2)
      .get(const GetOptions(source: Source.server))
      .timeout(const Duration(seconds: 10));
  expect(snapshot.docs.length, lessThanOrEqualTo(1));
  return snapshot.docs.isEmpty ? null : snapshot.docs.single.data();
}

Future<Map<String, dynamic>> _waitForSelection(
  String uid, {
  required String? selectedStopId,
  required int revision,
}) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
  Map<String, dynamic>? latest;
  while (DateTime.now().isBefore(deadline)) {
    latest = await _readProgress(uid);
    final String currentSelection =
        (latest?['selectedStopId'] as String?) ?? '';
    final int currentRevision = (latest?['selectionRevision'] as int?) ?? 0;
    if (currentSelection == (selectedStopId ?? '') &&
        currentRevision == revision) {
      if (latest == null) {
        fail('Selection revision $revision was expected in route progress.');
      }
      return latest;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }
  fail(
    'Timed out waiting for selection ${selectedStopId ?? '(clear)'} at '
    'revision $revision. Latest progress: $latest',
  );
}

Future<Map<String, dynamic>> _readPublishedRoute() async {
  final DocumentSnapshot<Map<String, dynamic>> snapshot =
      await FirebaseFirestore.instance
          .collection('route_plans')
          .doc(_routePlanId)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
  expect(
    snapshot.exists,
    isTrue,
    reason: 'The local fixture route must exist.',
  );
  return snapshot.data()!;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('selects B then A without changing the published route', (
    WidgetTester tester,
  ) async {
    const bool useFirebaseEmulator = bool.fromEnvironment(
      'USE_FIREBASE_EMULATOR',
    );
    const String firebaseEmulatorHost = String.fromEnvironment(
      'FIREBASE_EMULATOR_HOST',
    );
    expect(
      useFirebaseEmulator,
      isTrue,
      reason: 'This flow must fail closed unless local emulators are enabled.',
    );
    expect(firebaseEmulatorHost, '10.0.2.2');

    app.main();
    await tester.pump(const Duration(seconds: 2));

    final Finder quickSignIn = find.text('Salesperson');
    final Finder assignedRouteEntry = find.descendant(
      of: find.byType(ScootBottomNav),
      matching: find.text('Route'),
    );
    final DateTime loginDeadline = DateTime.now().add(
      const Duration(seconds: 60),
    );
    while (DateTime.now().isBefore(loginDeadline) &&
        quickSignIn.evaluate().isEmpty &&
        assignedRouteEntry.evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (quickSignIn.evaluate().isNotEmpty) {
      await tester.tap(quickSignIn.first);
    }
    await _waitFor(
      tester,
      assignedRouteEntry,
      timeout: const Duration(seconds: 90),
      label: 'the authenticated salesperson home',
    );

    final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    expect(uid, isNotEmpty, reason: 'Salesperson sign-in must be complete.');

    final Map<String, dynamic> routeBefore = await _readPublishedRoute();
    expect(routeBefore['status'], 'published');
    expect(routeBefore['stopIds'], <String>[_stopAId, _stopBId]);
    expect(await _readProgress(uid), isNull);

    await tester.tap(assignedRouteEntry.first);
    await _waitFor(
      tester,
      find.text(_stopAName),
      timeout: const Duration(seconds: 60),
      label: 'stop A from the published route',
    );
    await _waitFor(
      tester,
      find.text(_stopBName),
      timeout: const Duration(seconds: 30),
      label: 'stop B from the published route',
    );
    expect(find.text('Go to this stop'), findsNWidgets(2));
    expect(find.text('No stop selected'), findsOneWidget);

    final Finder goToStop = find.text('Go to this stop');
    await _scrollIntoView(tester, goToStop.at(1));
    await tester.tap(goToStop.at(1));
    await tester.pump(const Duration(milliseconds: 350));
    final Map<String, dynamic> selectedB = await _waitForSelection(
      uid,
      selectedStopId: _stopBId,
      revision: 1,
    );
    await _waitForSelectedDestination(tester, _stopBName);
    final Finder summaryForB = find
        .ancestor(
          of: find.text('Selected destination').first,
          matching: find.byType(Container),
        )
        .first;
    expect(
      find.descendant(of: summaryForB, matching: find.text(_stopBName)),
      findsOneWidget,
    );

    final Finder selectA = find.text('Go to this stop');
    expect(selectA, findsOneWidget);
    await _scrollIntoView(tester, selectA);
    await tester.tap(selectA);
    await tester.pump(const Duration(milliseconds: 350));
    final Map<String, dynamic> selectedA = await _waitForSelection(
      uid,
      selectedStopId: _stopAId,
      revision: 2,
    );
    await _waitForSelectedDestination(tester, _stopAName);

    final Finder clearDestination = find.text('Clear destination');
    await _waitFor(
      tester,
      clearDestination,
      timeout: const Duration(seconds: 15),
      label: 'the explicit clear-destination action',
    );
    await tester.ensureVisible(clearDestination);
    await tester.pumpAndSettle();
    await tester.tap(clearDestination);
    await tester.pump(const Duration(milliseconds: 350));
    final Map<String, dynamic> cleared = await _waitForSelection(
      uid,
      selectedStopId: null,
      revision: 3,
    );
    final DateTime clearUiDeadline = DateTime.now().add(
      const Duration(seconds: 20),
    );
    while (DateTime.now().isBefore(clearUiDeadline) &&
        (find.text('No stop selected').evaluate().isEmpty ||
            find
                .text('Suggested first pending stop · not selected')
                .evaluate()
                .isEmpty)) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('No stop selected'), findsOneWidget);
    expect(
      find.text('Suggested first pending stop · not selected'),
      findsOneWidget,
    );

    final Map<String, dynamic> routeAfter = await _readPublishedRoute();
    expect(routeAfter, equals(routeBefore));

    debugPrint(
      'ASSIGNED_ROUTE_SELECTION_TRACE ${jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'fixture': 'assigned-route-selection-v1',
        'routePlanUnchanged': true,
        'steps': <Map<String, Object?>>[
          <String, Object?>{'selectedStop': 'B', 'selectedStopId': _stopBId, 'selectionRevision': selectedB['selectionRevision']},
          <String, Object?>{'selectedStop': 'A', 'selectedStopId': _stopAId, 'selectionRevision': selectedA['selectionRevision']},
          <String, Object?>{'selectedStop': null, 'selectionRevision': cleared['selectionRevision']},
        ],
      })}',
    );
  });
}
