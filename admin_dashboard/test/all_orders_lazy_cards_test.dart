import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/all_orders_page.dart';
import 'package:scoot_design/scoot_design.dart';

const Key _filters = Key('filters');
const int _orders = 200;

Widget _table(bool cards, {int count = _orders}) => ScootDataTable<int>(
  columns: <ScootTableColumn<int>>[
    ScootTableColumn<int>(
      label: 'Retailer',
      cell: (BuildContext context, int row) => Text('Retailer $row'),
    ),
    ScootTableColumn<int>(
      label: 'Status',
      cell: (BuildContext context, int row) => Text('STATUS-$row'),
    ),
  ],
  rows: List<int>.generate(count, (int i) => i),
  phase: ScootLoadPhase.ready,
  onRetry: () {},
  emptyTitle: 'No orders found',
  pagesLoaded: 4,
  countLabel: ordersLoadedLabel(count, all: true),
  live: true,
  minTableWidth: OrdersListLayout.minTableWidth,
);

void main() {
  testWidgets('at 390 wide 200 order cards are built only near the screen, '
      'and the filters scroll away with them', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.dashboard(),
        home: Scaffold(
          body: OrdersListLayout(
            filters: const SizedBox(key: _filters, height: 190),
            tableBuilder: _table,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    final int built = find
        .textContaining('STATUS-', skipOffstage: false)
        .evaluate()
        .length;
    debugPrint('CARDS BUILT at 390x800 with $_orders shown rows: $built');
    expect(built, lessThan(30), reason: 'every card is built at once');

    final Rect first = tester.getRect(find.text('STATUS-0'));
    expect(first.top, greaterThanOrEqualTo(0));
    expect(first.bottom, lessThanOrEqualTo(800));

    final Finder last = find.text('STATUS-${_orders - 1}');
    for (int i = 0; i < 80 && last.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(OrdersListLayout), const Offset(0, -600));
      await tester.pumpAndSettle();
    }
    for (int i = 0; i < 3; i++) {
      await tester.drag(find.byType(OrdersListLayout), const Offset(0, -600));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);

    expect(
      tester.getRect(find.byKey(_filters, skipOffstage: false)).bottom,
      lessThanOrEqualTo(0),
      reason: 'the filters stay on screen while the cards scroll',
    );
    final Rect footer = tester.getRect(find.textContaining('per page'));
    expect(
      tester.getRect(last).bottom,
      lessThanOrEqualTo(footer.top),
      reason: 'the last Status row is under the footer',
    );
    expect(footer.bottom, lessThanOrEqualTo(800));
  });

  for (final (int count, Size size) in <(int, Size)>[
    (1, const Size(390, 800)),
    (9, const Size(760, 1100)),
  ]) {
    testWidgets('at ${size.width.round()} by ${size.height.round()} the '
        'footer of a list with $count order cards that fit on the panel sits '
        'right under the last card', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ScootTheme.dashboard(),
          home: Scaffold(
            body: OrdersListLayout(
              filters: const SizedBox(key: _filters, height: 190),
              tableBuilder: (bool cards) => _table(cards, count: count),
              rowCount: count,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final Rect card = tester.getRect(find.text('STATUS-${count - 1}'));
      final Rect footer = tester.getRect(find.textContaining('per page'));
      expect(
        footer.top - card.bottom,
        lessThan(60),
        reason: 'an empty area sits between the last card and the footer',
      );
      expect(footer.bottom, lessThanOrEqualTo(size.height));
    });
  }
}
