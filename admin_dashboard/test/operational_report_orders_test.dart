import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';

void main() {
  test('rejected orders cannot affect operational report totals', () {
    final List<Map<String, dynamic>> operational = operationalReportOrders(
      <Map<String, dynamic>>[
        <String, dynamic>{'status': 'submitted', 'total': 100, 'totalBoxes': 2},
        <String, dynamic>{
          'status': 'pending_approval',
          'total': 50,
          'totalBoxes': 1,
        },
        <String, dynamic>{'status': 'rejected', 'total': 900, 'totalBoxes': 90},
        <String, dynamic>{
          'status': 'cancelled',
          'total': 800,
          'totalBoxes': 80,
        },
        <String, dynamic>{'status': 'void', 'total': 700, 'totalBoxes': 70},
      ],
    );

    expect(operational, hasLength(2));
    expect(operational.map(orderRevenue), <double>[100, 50]);
    expect(operational.map(orderQuantity), <int>[2, 1]);
  });
}
