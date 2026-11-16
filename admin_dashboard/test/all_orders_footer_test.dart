import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/all_orders_page.dart';

void main() {
  test('the orders footer counts one order and offers more only when '
      'older orders can exist', () {
    expect(ordersLoadedLabel(1, all: true), '1 order loaded (all)');
    expect(ordersLoadedLabel(2, all: false), '2 orders loaded');
    expect(
      ordersHaveMore(moreLoaded: false, reachedEnd: false, liveComplete: true),
      isFalse,
    );
    expect(
      ordersHaveMore(moreLoaded: false, reachedEnd: false, liveComplete: false),
      isTrue,
    );
    expect(
      ordersHaveMore(moreLoaded: false, reachedEnd: true, liveComplete: false),
      isFalse,
    );
    expect(
      ordersHaveMore(moreLoaded: true, reachedEnd: true, liveComplete: true),
      isTrue,
    );
  });
}
