import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/widgets/order_details_dialog.dart';
import 'package:flutter_web_app/utils/money_format.dart';
import 'package:scoot_design/scoot_design.dart';

Future<void> _pump(WidgetTester tester, double width, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ScootTheme.dashboard(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: const ValueKey<String>('dialog'),
            width: width < 600 ? width - 80 : 880,
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void _inside(WidgetTester tester, Finder finder, String what) {
  expect(finder, findsOneWidget, reason: '$what is missing');
  final Rect dialog = tester.getRect(
    find.byKey(const ValueKey<String>('dialog')),
  );
  final Rect rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(dialog.left), reason: '$what is cut');
  expect(rect.right, lessThanOrEqualTo(dialog.right), reason: '$what is cut');
}

void main() {
  testWidgets('Close, Reject and Approve stay inside a 360 phone dialog', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      360,
      OrderDetailsActions(
        busy: false,
        onClose: () {},
        onReject: () {},
        onApprove: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    for (final String label in <String>['Close', 'Reject', 'Approve']) {
      final Finder button = find.ancestor(
        of: find.text(label),
        matching: find.bySubtype<ButtonStyleButton>(),
      );
      _inside(tester, button, label);
      expect(
        tester.getSize(button).height,
        greaterThanOrEqualTo(44),
        reason: '$label is a small touch target',
      );
    }
  });

  testWidgets(
    'an order line shows its quantity and price inside a 360 phone dialog',
    (WidgetTester tester) async {
      const List<Map<String, dynamic>> items = <Map<String, dynamic>>[
        <String, dynamic>{
          'productName': 'ORGANIC APPLE CIDER VINEGAR (12BTL X 946ML)',
          'department': 'GROCERY',
          'packingSize': '12 x 946ml',
          'qty': 3,
          'price': 28.12,
          'expiry': '12/11/2026',
        },
      ];
      await _pump(tester, 360, const OrderItemsTable(items: items));
      expect(tester.takeException(), isNull);
      _inside(tester, find.textContaining('3 boxes'), 'quantity');
      _inside(tester, find.textContaining(formatRm(28.12)), 'unit price');
      _inside(tester, find.textContaining(formatRm(84.36)), 'line total');
      _inside(tester, find.textContaining('ORGANIC APPLE CIDER'), 'product');

      await _pump(tester, 1280, const OrderItemsTable(items: items));
      expect(tester.takeException(), isNull);
      expect(find.byType(DataTable), findsOneWidget);
    },
  );
}
