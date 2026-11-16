import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/order_submission_contract.dart';
import 'package:fmcg_sales/utils/quantity_unit.dart';

Map<String, dynamic> validItem({
  String name = 'Orange Juice',
  String productId = 'p_1',
  int qty = 2,
  num price = 12.50,
  List<Map<String, dynamic>>? shelfBatches,
}) {
  return <String, dynamic>{
    'name': name,
    'productName': name,
    'productId': productId,
    'barcode': '9551000000015',
    'packingSize': '12 x 1L',
    'price': price,
    'qty': qty,
    'expiry': '',
    'department': 'Beverage',
    'departmentName': 'Beverage',
    'shelfBatches': shelfBatches ?? <Map<String, dynamic>>[],
    'remarks': '',
  };
}

void main() {
  test('rejects zero, negative, excessive, and wrong-type quantities', () {
    for (final Object qty in <Object>[
      0,
      -1,
      defaultMaxQtyPerLine + 1,
      1.5,
      '1',
    ]) {
      final item = validItem();
      item['qty'] = qty;
      expect(
        OrderSubmissionContract.validateItems(<Map<String, dynamic>>[item]),
        isNotNull,
      );
    }
  });

  test('rejects non-positive and excessive line prices', () {
    for (final num price in <num>[
      0,
      -0.01,
      1.001,
      OrderSubmissionContract.maxUnitPriceCents / 100 + 0.01,
    ]) {
      expect(
        OrderSubmissionContract.validateItems(<Map<String, dynamic>>[
          validItem(price: price),
        ]),
        contains('invalid unit price'),
      );
    }
  });

  test('round-trips the rules-verifiable commercial lines', () {
    final items = <Map<String, dynamic>>[
      validItem(name: 'Orange Juice 芒果', qty: 2, price: 12.50),
    ];
    final encoded = OrderSubmissionContract.commercialLines(items);
    final decoded =
        OrderSubmissionContract.readCommercialLines(<String, dynamic>{
          'commercialSchemaVersion': OrderSubmissionContract.schemaVersion,
          'commercialLines': encoded,
        });

    expect(decoded, hasLength(1));
    expect(decoded!.single.productId, 'p_1');
    expect(decoded.single.productName, 'Orange Juice 芒果');
    expect(decoded.single.quantity, 2);
    expect(decoded.single.unitPriceCents, 1250);
    expect(decoded.single.lineTotalCents, 2500);
  });
}
