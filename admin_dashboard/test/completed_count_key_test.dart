import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/order_id_resolver.dart';

void main() {
  test('a completed route stop without an order id still gets a count key', () {
    final Map<String, dynamic> stop = <String, dynamic>{
      'sourceCollection': 'route_stop_progress',
      'docId': 'plan_uid_stop1',
    };
    expect(OrderIdResolver.completionKey(stop), 'route_stop_progress:plan_uid_stop1');
    expect(
      OrderIdResolver.completionKey(<String, dynamic>{
        'sourceCollection': 'orders',
        'docId': 'order_ORD1',
      }),
      'ORD1',
    );
    expect(OrderIdResolver.completionKey(<String, dynamic>{}), '');
  });
}
