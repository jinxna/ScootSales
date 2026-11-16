import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/all_orders_page.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';
import 'package:scoot_design/scoot_design.dart';

const String _stop = 'monday_1_kedai_runcit_sri_aman_jalan_tun_razak_00123';
const String _alpha = 'ORD-V2-AbCdEfGhIjKlMnOpQrStUvWxYz12.plan_2026w45.$_stop';
const String _beta = 'ORD-V2-AbCdEfGhIjKlMnOpQrStUvWxYz12.plan_2026w46.$_stop';
const String _unique = 'ORD-P1-b7f12276706a38b03debab008410f635';

void main() {
  testWidgets('phone cards whose short reference repeats show the whole id, '
      'also for one salesperson on two weeks, and a unique one keeps the '
      'short reference', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    const List<String> ids = <String>[_alpha, _beta, _unique];
    final Set<String> repeated = repeatedShortOrderReferences(ids);
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.dashboard(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ScootDataTable<String>(
              columns: <ScootTableColumn<String>>[
                ScootTableColumn<String>(
                  label: 'Order ID',
                  cell: (BuildContext context, String id) => OrderCardReference(
                    key: ValueKey<String>(id),
                    orderId: id,
                    repeated: repeated,
                  ),
                ),
              ],
              rows: ids,
              phase: ScootLoadPhase.ready,
              onRetry: () {},
              emptyTitle: 'No orders found',
              minTableWidth: OrdersListLayout.minTableWidth,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    String shown(String id) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey<String>(id)),
            matching: find.byType(Text),
          ),
        )
        .data!;
    expect(shown(_alpha), _alpha);
    expect(shown(_beta), _beta);
    expect(shown(_alpha), isNot(shown(_beta)));
    expect(shown(_unique), 'ORD-8410F635');

    for (final String id in <String>[_alpha, _beta]) {
      final Finder card = find.byKey(ValueKey<String>(id));
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: card, matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: '$id is cut');
      expect(
        tester.getRect(card).right,
        lessThanOrEqualTo(360),
        reason: '$id overflows',
      );
    }
  });
}
