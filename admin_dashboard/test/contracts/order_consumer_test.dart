import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';

final Timestamp _serverTime = Timestamp.fromDate(
  DateTime.utc(2026, 10, 5, 2, 15),
);

Object? _materialise(Object? value) {
  if (value is Map) {
    if (value.containsKey(r'$sentinel')) {
      if (value[r'$sentinel'] == 'serverTimestamp') return _serverTime;
      throw StateError('Unexpected sentinel in a stored order.');
    }
    return <String, dynamic>{
      for (final MapEntry<dynamic, dynamic> e in value.entries)
        e.key as String: _materialise(e.value),
    };
  }
  if (value is Iterable) return value.map<Object?>(_materialise).toList();
  return value;
}

void main() {
  final List<File> files =
      Directory('../contracts/orders')
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.json'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  test('order fixtures are present', () {
    expect(files, isNotEmpty);
  });

  for (final File file in files) {
    final Map<String, dynamic> fixture =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final Map<String, dynamic> expected =
        (fixture['expect'] as Map<String, dynamic>)['dashboard']
            as Map<String, dynamic>;
    final String name = file.uri.pathSegments.last;

    test('dashboard reads every displayed field of $name', () {
      final Map<String, dynamic> order =
          _materialise(fixture['order'])! as Map<String, dynamic>;

      expect(orderStatus(order), expected['status']);
      expect(
        isSubmittedOrApprovedOrder(order),
        expected['isSubmittedOrApproved'],
      );
      expect(isPendingApprovalOrder(order), expected['isPendingApproval']);
      expect(orderRevenue(order), closeTo(expected['revenue'] as num, 1e-9));
      expect(orderQuantity(order), expected['quantity']);
      expect(orderItemCount(order), expected['itemCount']);
      expect(resolveSalesmanName(order), expected['salesmanName']);
      expect(dataText(order['retailerName']), expected['retailerName']);
      expect(dataText(order['outlet']), expected['retailerName']);
      expect(
        orderDateFromRow(order)?.toUtc(),
        _serverTime.toDate().toUtc(),
        reason: 'submittedAt must parse as the order date',
      );

      final List<Map<String, dynamic>> items = authoritativeOrderItems(order);
      final List<dynamic> expectedItems = expected['items'] as List<dynamic>;
      expect(items.length, expectedItems.length);
      for (int i = 0; i < items.length; i++) {
        final Map<String, dynamic> want =
            expectedItems[i] as Map<String, dynamic>;
        expect(items[i]['name'], want['name']);
        expect(items[i]['productName'], want['name']);
        expect(items[i]['productId'], want['productId']);
        expect(itemQuantity(items[i]), want['qty']);
        expect(dataNumber(items[i]['price']), closeTo(want['price'] as num, 1e-9));
        expect(items[i]['department'], want['department']);
      }
    });
  }
}
