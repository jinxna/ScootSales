import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/pages/admin/widgets/order_details_dialog.dart';
import 'package:flutter_web_app/utils/server_price_check.dart';

void main() {
  testWidgets(
    'The order details header wraps its title by word on a phone-width dialog',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 310,
                child: OrderDetailsHeader(
                  title: 'ORD-OLD-1',
                  subtitle: 'Choice Supermarket Tabuan Jaya',
                  status: 'submitted',
                  priceCheck: ServerPriceCheck.fromOrder(
                    const <String, dynamic>{},
                  ),
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final RenderParagraph title = tester.renderObject<RenderParagraph>(
        find.text('ORD-OLD-1'),
      );
      expect(title.size.height, lessThan(title.textSize.height * 2 + 1));
      expect(
        title.getMaxIntrinsicWidth(double.infinity) <= title.size.width,
        isTrue,
        reason: 'the order id fits on one line',
      );
      final RenderBox header = tester.renderObject<RenderBox>(
        find.byType(OrderDetailsHeader),
      );
      expect(header.size.height, lessThan(240));
    },
  );
}
