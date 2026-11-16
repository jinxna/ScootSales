import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';

void main() {
  test('a tracking doc owned by another salesperson is ignored', () {
    final Map<String, dynamic> order = <String, dynamic>{'salesmanUid': 'a'};
    expect(
      trackingFixBelongsToOrder(order, <String, dynamic>{'salesmanUid': 'b'}),
      isFalse,
    );
    expect(trackingFixBelongsToOrder(order, <String, dynamic>{}), isFalse);
    expect(
      trackingFixBelongsToOrder(order, <String, dynamic>{'salesmanUid': 'a'}),
      isTrue,
    );
  });
}
