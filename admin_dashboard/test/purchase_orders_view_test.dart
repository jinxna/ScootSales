import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/purchase_orders_view.dart';
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
