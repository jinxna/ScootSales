import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/all_orders_page.dart';
import 'package:scoot_design/scoot_design.dart';

const String _orderId = 'ORD-P1-b7f12276706a38b03debab008410f635';

Widget _table(bool cards) {
  ScootTableColumn<String> column(String label, String value) =>
      ScootTableColumn<String>(
        label: label,
        cell: (BuildContext context, String row) => Text(value),
      );
  return ScootDataTable<String>(
    columns: <ScootTableColumn<String>>[
      column('Order ID', _orderId),
      column('Retailer', 'Choice Supermarket Tabuan Jaya'),
      column('Salesman', 'E2E Salesperson'),
      column('Submitted', '12/11/2026 01:54'),
      column('Items', '1'),
      column('Total', 'RM 28.12'),
      column('Status', 'STATUS-VALUE'),
    ],
    rows: const <String>['row'],
    phase: ScootLoadPhase.ready,
    onRetry: () {},
    emptyTitle: 'No orders found',
    countLabel: ordersLoadedLabel(1, all: true),
    live: true,
    minTableWidth: OrdersListLayout.minTableWidth,
  );
}

void main() {
  testWidgets('at 360 wide the whole order card sits above the list footer', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 480);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.dashboard(),
        home: Scaffold(
          body: OrdersListLayout(
            filters: const SizedBox(height: 190),
            tableBuilder: _table,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final Rect status = tester.getRect(find.text('STATUS-VALUE'));
    final Rect footer = tester.getRect(find.textContaining('per page'));
    expect(
      status.bottom,
      lessThanOrEqualTo(footer.top),
      reason: 'the Status row is under the footer',
    );
    await tester.drag(find.text('Retailer'), const Offset(0, -400));
    await tester.pump();
    expect(
      tester.getRect(find.textContaining('per page')).bottom,
      lessThanOrEqualTo(480),
      reason: 'the footer cannot be scrolled into view',
    );
  });
}
