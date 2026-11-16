import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:flutter_web_app/utils/order_id_resolver.dart';

Map<String, dynamic> order(String id, String status) => <String, dynamic>{
  'docId': id,
  'orderId': id,
  'status': status,
};

Map<String, dynamic> trackingRow(String orderId) => <String, dynamic>{
  'docId': 'gps_tracking_order_$orderId',
  'bridgeKey': 'gps_tracking:order_$orderId',
  'sourceCollection': 'gps_tracking',
  'salesmanUid': 'sales-1',
  'lastOrderId': orderId,
  'orderDocId': orderId,
  'orderDocumentId': orderId,
  'timestamp': 'seen-$orderId',
};

void main() {
  test(
    'location rows keep their place but stop pointing at an order that does not count',
    () {
      final List<Map<String, dynamic>> orders = <Map<String, dynamic>>[
        order('o-submitted', 'submitted'),
        order('o-held', 'held_for_review'),
        order('o-rejected', 'rejected'),
        order('o-cancelled', 'cancelled'),
      ];
      final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
        trackingRow('o-submitted'),
        trackingRow('o-held'),
        trackingRow('o-rejected'),
        trackingRow('o-cancelled'),
        trackingRow('o-not-loaded'),
        <String, dynamic>{
          'docId': 'user_location_sales-1',
          'bridgeKey': 'users_location:sales-1',
          'sourceCollection': 'users',
          'lastOrderId': 'o-rejected',
        },
      ];

      final List<Map<String, dynamic>> merged =
          CmsRepository.withoutNonCountingOrderReferences(rows, orders);

      expect(merged.map((Map<String, dynamic> row) => row['docId']), <String>[
        'gps_tracking_order_o-submitted',
        'gps_tracking_order_o-held',
        'gps_tracking_order_o-rejected',
        'gps_tracking_order_o-cancelled',
        'gps_tracking_order_o-not-loaded',
        'user_location_sales-1',
      ]);
      expect(
        merged
            .map(OrderIdResolver.resolve)
            .where((String id) => id.isNotEmpty)
            .toList(),
        <String>['o-submitted', 'o-held', 'o-not-loaded'],
      );
      expect(merged[2]['timestamp'], 'seen-o-rejected');
      expect(merged[3]['salesmanUid'], 'sales-1');
    },
  );
}
