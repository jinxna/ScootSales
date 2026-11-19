import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/purchase_orders_view.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';
import 'package:scoot_design/scoot_design.dart';

Map<String, dynamic> _po(
  int n, {
  String retailer = 'Choice Supermarket Tabuan Jaya',
  String status = 'issued',
}) => <String, dynamic>{
  'docId': 'ORD-$n',
  'poNumber': 'PO-20261104-ORD-$n',
  'orderId': 'ORD-$n',
  'retailerName': retailer,
  'salesmanCode': 'S001',
  'totalPrice': 65.25,
  'status': status,
  'issuedAt': Timestamp.fromDate(DateTime(2026, 11, 4, 10)),
  'lines': <Map<String, dynamic>>[
    <String, dynamic>{
      'productName': 'ORGANIC APPLE CIDER VINEGAR',
      'packingSize': '12BTL X 946ML',
      'quantity': 2,
      'price': 28.12,
    },
  ],
};

Widget _view({
  ScootLoadPhase phase = ScootLoadPhase.ready,
  List<Map<String, dynamic>> pos = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> legacy = const <Map<String, dynamic>>[],
  bool isAdmin = true,
  VoidCallback? onRetry,
  ValueChanged<String>? onIssue,
  void Function(Map<String, dynamic>, String)? onStatus,
  VoidCallback? onJump,
  Map<String, String> names = const <String, String>{},
  bool? hasAny,
  Future<List<Map<String, dynamic>>> Function(String)? loadLines,
}) {
  return MaterialApp(
    theme: ScootTheme.dashboard(),
    home: Scaffold(
      body: PurchaseOrdersView(
        phase: phase,
        onRetry: onRetry ?? () {},
        weekLabel: '2 Nov 2026 – 8 Nov 2026',
        canGoNext: false,
        onPreviousWeek: () {},
        onNextWeek: () {},
        onThisWeek: () {},
        weekPos: pos,
        weekLegacy: legacy,
        hasAnyActivity: hasAny ?? (pos.isNotEmpty || legacy.isNotEmpty),
        isAdmin: isAdmin,
        issuing: const <String>{},
        changing: const <String>{},
        onIssue: onIssue ?? (_) {},
        onChangeStatus: onStatus ?? (_, _) {},
        loadOrderLines: loadLines ?? (_) async => <Map<String, dynamic>>[],
        salespersonNames: names,
        onJumpToLatest: onJump,
      ),
    ),
  );
}

Future<void> _size(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('branch manager sees a view-only notice and no actions', (
    WidgetTester tester,
  ) async {
    await _size(tester);
    await tester.pumpWidget(
      _view(pos: <Map<String, dynamic>>[_po(1)], isAdmin: false),
    );
    expect(find.textContaining('View only'), findsOneWidget);
    expect(find.text('Mark fulfilled'), findsNothing);
  });

  testWidgets('on a 390 phone each PO shows its value, status and actions', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1600);
    addTearDown(tester.view.reset);
    final List<String> changed = <String>[];
    await tester.pumpWidget(
      _view(
        pos: <Map<String, dynamic>>[_po(1)],
        onStatus: (Map<String, dynamic> po, String status) =>
            changed.add(status),
      ),
    );
    expect(tester.takeException(), isNull);
    for (final String label in <String>['Value', 'Status', 'Issued']) {
      expect(
        tester.getRect(find.text(label).last).right,
        lessThanOrEqualTo(390),
        reason: '$label label is off screen',
      );
    }
    expect(
      tester.getRect(find.text('RM 65.25').last).right,
      lessThanOrEqualTo(390),
    );
    await tester.tap(find.text('Mark fulfilled'));
    expect(changed, <String>['fulfilled']);
  });

  testWidgets('the week switch and This week stay on a 390 wide phone', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_view());

    expect(tester.takeException(), isNull);
    for (final Finder finder in <Finder>[
      find.byTooltip('Previous week'),
      find.byTooltip('Next week'),
      find.widgetWithText(OutlinedButton, 'This week'),
    ]) {
      final Rect rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
    }
  });

  Future<void> openLazyLines(
    WidgetTester tester,
    Future<List<Map<String, dynamic>>> Function(String) loadLines,
  ) async {
    await _size(tester);
    final Map<String, dynamic> po = _po(1)..remove('lines');
    await tester.pumpWidget(
      _view(pos: <Map<String, dynamic>>[po], loadLines: loadLines),
    );
    await tester.tap(find.text('PO-20261104-ORD-1'));
    await tester.pump();
  }

  testWidgets('order lines show a loading line while they are read', (
    WidgetTester tester,
  ) async {
    final Completer<List<Map<String, dynamic>>> never =
        Completer<List<Map<String, dynamic>>>();
    await openLazyLines(tester, (_) => never.future);
    expect(find.text('Loading the order lines.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('a failed read of the order lines can be tried again', (
    WidgetTester tester,
  ) async {
    int reads = 0;
    await openLazyLines(tester, (_) async {
      reads++;
      throw StateError('network');
    });
    await tester.pump();
    expect(find.text('The order lines could not be loaded.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(reads, 2);
  });

  testWidgets('a deleted order says its lines are gone and offers no retry', (
    WidgetTester tester,
  ) async {
    await openLazyLines(
      tester,
      (_) async => throw const PurchaseOrderSourceGone(),
    );
    await tester.pump();
    expect(
      find.text('The order was deleted, so its lines are not available.'),
      findsOneWidget,
    );
    expect(find.text('The order lines could not be loaded.'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets(
    'a deleted order says its lines are gone even when its read is refused with permission-denied, as the order rule does for a supervisor or branch manager',
    (WidgetTester tester) async {
      await openLazyLines(
        tester,
        (_) async => authoritativeOrderItems(
          await readPurchaseOrderSource(
            () async => throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'permission-denied',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('The order was deleted, so its lines are not available.'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsNothing);
    },
  );

  testWidgets('an order read that fails for another reason can be tried again', (
    WidgetTester tester,
  ) async {
    await openLazyLines(
      tester,
      (_) async => authoritativeOrderItems(
        await readPurchaseOrderSource(
          () async => throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'unavailable',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('The order lines could not be loaded.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('below the table width every PO action stays inside the card', (
    WidgetTester tester,
  ) async {
    for (final double width in <double>[700, 840, 970]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_view(pos: <Map<String, dynamic>>[_po(1)]));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final Finder target in <Finder>[
        find.text('Status').last,
        find.text('Mark fulfilled'),
        find.byTooltip('Cancel PO'),
      ]) {
        expect(
          tester.getRect(target).right,
          lessThanOrEqualTo(width),
          reason: '$target is past the card edge at $width px',
        );
      }
    }
  });
}
