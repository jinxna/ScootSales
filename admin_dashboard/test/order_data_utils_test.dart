import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';
import 'package:flutter_web_app/utils/quantity_unit.dart';

String line(String productId, String name, int qty, int cents) {
  final String encoded = base64Url
      .encode(utf8.encode(name))
      .replaceAll('=', '');
  return '$productId~$encoded~$qty~$cents';
}

void main() {
  test('canonical lines override forged display maps and aggregate totals', () {
    final Map<String, dynamic> order = <String, dynamic>{
      'commercialSchemaVersion': 1,
      'commercialLines': <String>[line('juice_1', 'Orange Juice', 2, 1250)],
      'totalBoxes': 999,
      'totalPrice': 999999,
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'productId': 'forged',
          'name': 'Forged',
          'qty': -100,
          'price': -500,
          'department': 'Beverage',
        },
      ],
    };

    expect(orderQuantity(order), 2);
    expect(orderRevenue(order), 25);
    expect(orderItemCount(order), 1);
    expect(
      authoritativeOrderItems(order).single,
      containsPair('name', 'Orange Juice'),
    );
    expect(
      authoritativeOrderItems(order).single,
      containsPair('productId', 'juice_1'),
    );
    expect(
      authoritativeOrderItems(order).single,
      containsPair('department', 'Beverage'),
    );
  });

  test('malformed canonical lines fail closed without legacy fallback', () {
    final Map<String, dynamic> order = <String, dynamic>{
      'commercialSchemaVersion': 1,
      'commercialLines': <String>['bad'],
      'totalBoxes': 999,
      'totalPrice': 999999,
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'productId': 'forged', 'qty': 999, 'price': 999},
      ],
    };

    expect(orderQuantity(order), 0);
    expect(orderRevenue(order), 0);
    expect(authoritativeOrderItems(order), isEmpty);
  });

  test('identifies incomplete orders before approval', () {
    final Map<String, dynamic> incomplete = <String, dynamic>{
      'retailerId': 'R001',
      'items': <Map<String, dynamic>>[],
      'totalBoxes': 0,
      'totalPrice': 0,
    };
    expect(isCompleteOrder(incomplete), isFalse);
    expect(orderCompletenessIssue(incomplete), 'No order items were recorded.');
  });

  test('accepts 1 to 999 per line, the server ceiling, but rejects 1000', () {
    for (final int quantity in <int>[1, 5, 6, 100, 999]) {
      final Map<String, dynamic> order = <String, dynamic>{
        'commercialSchemaVersion': 1,
        'commercialLines': <String>[
          line('juice_1', 'Orange Juice', quantity, 1250),
        ],
      };
      expect(
        canonicalCommercialLines(order),
        hasLength(1),
        reason: 'quantity=$quantity',
      );
    }

    final Map<String, dynamic> rejected = <String, dynamic>{
      'commercialSchemaVersion': 1,
      'commercialLines': <String>[line('juice_1', 'Orange Juice', 1000, 1250)],
    };
    expect(canonicalCommercialLines(rejected), isEmpty);
    expect(absoluteMaxQtyPerLine, 999);
  });

  test('purchase-order facts must agree with the commercial lines', () {
    Map<String, dynamic> order({
      String productId = 'juice_1',
      int qty = 2,
      num price = 12.5,
      num total = 25,
    }) => <String, dynamic>{
      'commercialSchemaVersion': 1,
      'commercialLines': <String>[line('juice_1', 'Orange Juice', 2, 1250)],
      'totalPrice': total,
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'productId': productId, 'qty': qty, 'price': price},
      ],
    };

    expect(orderCommercialFactsAgree(order()), isTrue);
    expect(orderCommercialFactsAgree(order(productId: 'other')), isFalse);
    expect(orderCommercialFactsAgree(order(qty: 3)), isFalse);
    expect(orderCommercialFactsAgree(order(price: 99)), isFalse);
    expect(orderCommercialFactsAgree(order(total: 999)), isFalse);
    expect(
      orderCommercialFactsAgree(<String, dynamic>{'totalPrice': 10}),
      isTrue,
    );
  });

  test(
    'rejected, cancelled, void, draft and deleted orders are neither a visit '
    'nor a sale; a held order is a sale but not a visit',
    () {
      const Map<String, List<bool>> expected = <String, List<bool>>{
        '': <bool>[true, true],
        'submitted': <bool>[true, true],
        'approved': <bool>[true, true],
        'Approved': <bool>[true, true],
        'pending_approval': <bool>[true, true],
        'synced': <bool>[true, true],
        'held_for_review': <bool>[false, true],
        'rejected': <bool>[false, false],
        'cancelled': <bool>[false, false],
        'canceled': <bool>[false, false],
        'void': <bool>[false, false],
        'draft': <bool>[false, false],
        'deleted': <bool>[false, false],
      };
      expected.forEach((String status, List<bool> want) {
        final Map<String, dynamic> order = <String, dynamic>{'status': status};
        expect(
          <bool>[orderCountsAsVisit(order), orderCountsAsSale(order)],
          want,
          reason: 'status="$status"',
        );
      });
      final Map<String, dynamic> flagged = <String, dynamic>{
        'status': 'submitted',
        'isRejected': true,
      };
      expect(orderCountsAsVisit(flagged), isFalse);
      expect(orderCountsAsSale(flagged), isFalse);
    },
  );

  test('an order whose lines carry no price is counted as unpriced', () {
    final Map<String, dynamic> old = <String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'productId': 'a', 'qty': 2},
      ],
    };
    final Map<String, dynamic> priced = <String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'productId': 'a', 'qty': 2, 'price': 3.5},
      ],
    };
    expect(orderLacksLinePrices(old), isTrue);
    expect(orderLacksLinePrices(priced), isFalse);
    expect(orderLacksLinePrices(<String, dynamic>{'totalPrice': 10}), isFalse);
  });

  test(
    'FIX-132 possible duplicate: same retailer and same items within 30 minutes',
    () {
      Map<String, dynamic> order(
        String id,
        DateTime at, {
        String retailer = 'R001',
        List<String>? lines,
        String status = 'submitted',
        String visitId = '',
      }) => <String, dynamic>{
        'docId': id,
        'retailerId': retailer,
        'visitId': visitId,
        'status': status,
        'submittedAt': at.toIso8601String(),
        'commercialSchemaVersion': 1,
        'commercialLines':
            lines ??
            <String>[
              line('juice_1', 'Orange Juice', 2, 1250),
              line('tea_1', 'Green Tea', 1, 900),
            ],
      };

      final DateTime t0 = DateTime.utc(2026, 11, 4, 2);
      final Set<String> flagged = possibleDuplicateOrders(
        <Map<String, dynamic>>[
          order('A', t0, visitId: 'v1'),
          order(
            'B',
            t0.add(const Duration(minutes: 30)),
            visitId: 'v2',
            lines: <String>[
              line('tea_1', 'Green Tea', 1, 900),
              line('juice_1', 'Orange Juice', 2, 1250),
            ],
          ),
          order('C', t0.add(const Duration(minutes: 61))),
          order('D', t0, retailer: 'R002'),
          order(
            'E',
            t0.add(const Duration(minutes: 5)),
            retailer: 'R003',
            visitId: 'v9',
          ),
          order(
            'F',
            t0.add(const Duration(minutes: 6)),
            retailer: 'R003',
            visitId: 'v9',
            lines: <String>[line('juice_1', 'Orange Juice', 3, 1250)],
          ),
          order('G', t0, retailer: 'R004'),
          order(
            'H',
            t0.add(const Duration(minutes: 1)),
            retailer: 'R004',
            status: 'rejected',
          ),
        ],
      );

      expect(flagged, <String>{'A', 'B'});
    },
  );
}
