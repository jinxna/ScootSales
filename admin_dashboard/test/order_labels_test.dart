import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';

const String _orderId = 'ORD-P1-b7f12276706a38b03debab008410f635';

void main() {
  test('an order status reads like its filter and a long id uses the phone '
      'reference', () {
    expect(orderStatusLabel('submitted'), 'Submitted');
    expect(orderStatusLabel('held_for_review'), 'Held for review');
    expect(shortOrderReference(_orderId), 'ORD-8410F635');
    expect(shortOrderReference('ORD-OLD-1'), 'ORD-OLD-1');
  });
}
