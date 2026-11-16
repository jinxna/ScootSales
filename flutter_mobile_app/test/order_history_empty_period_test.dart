import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/screens/order_history_screen.dart';
import 'package:fmcg_sales/theme/app_theme.dart';

void main() {
  testWidgets(
    'VP-06 an empty recent period says which period has no orders above Show older orders',
    (WidgetTester tester) async {
      int olderTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme,
          home: Scaffold(
            body: OrderHistoryList(
              orders: const <OrderHistoryRecord>[],
              onOpen: (_) {},
              footerLabel: 'Show older orders',
              onFooter: () => olderTaps++,
              emptyTitle: orderHistoryEmptyTitle(
                hasActiveFilters: false,
                limitedToRecent: true,
                retentionMonths: 3,
              ),
              emptyMessage: 'Orders you send will show here.',
            ),
          ),
        ),
      );

      final Finder title = find.text('No orders in the last 3 months');
      final Finder older = find.widgetWithText(
        OutlinedButton,
        'Show older orders',
      );
      expect(title, findsOneWidget);
      expect(older, findsOneWidget);
      expect(
        tester.getRect(title).bottom,
        lessThanOrEqualTo(tester.getRect(older).top),
      );
      await tester.tap(older);
      expect(olderTaps, 1);
    },
  );

  test(
    'VP-06 the empty period names whole years the way the dashboard does',
    () {
      String title(int months) => orderHistoryEmptyTitle(
        hasActiveFilters: false,
        limitedToRecent: true,
        retentionMonths: months,
      );
      expect(title(84), 'No orders in the last 7 years');
      expect(title(24), 'No orders in the last 2 years');
      expect(title(12), 'No orders in the last 12 months');
      expect(title(6), 'No orders in the last 6 months');
      expect(title(1), 'No orders in the last 1 month');
    },
  );
}
