import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/services/order_submission_alerts.dart';

OrderChange order(
  String id, {
  String status = 'submitted',
  bool pending = false,
  bool removed = false,
  DateTime? submittedAt,
}) => OrderChange(
  id: id,
  data: <String, dynamic>{
    'status': status,
    if (submittedAt != null) 'submittedAt': submittedAt,
    'salesmanName': 'Aina',
    'retailerName': 'Kedai Maju',
  },
  pendingWrite: pending,
  removed: removed,
);

void main() {
  test('FR-ADM-04: a newly submitted order yields exactly one alert', () async {
    final List<OrderAlert> alerts = <OrderAlert>[];
    final StreamController<List<OrderChange>> feed =
        StreamController<List<OrderChange>>();
    final OrderSubmissionAlerts service = OrderSubmissionAlerts(
      onAlert: alerts.add,
    )..start(feed.stream);

    feed.add(<OrderChange>[order('old'), order('draft1', status: 'draft')]);
    await pumpEventQueue();
    expect(alerts, isEmpty);

    feed.add(<OrderChange>[order('mine', pending: true)]);
    feed.add(<OrderChange>[order('draft2', status: 'draft')]);
    feed.add(<OrderChange>[order('new1')]);
    feed.add(<OrderChange>[order('new1'), order('old')]);
    feed.add(<OrderChange>[order('new1', removed: true)]);
    feed.add(<OrderChange>[order('new1')]);
    await pumpEventQueue();
    expect(alerts.map((OrderAlert a) => a.orderId), <String>['new1']);
    expect(alerts.single.message, 'Order submitted by Aina for Kedai Maju.');

    feed.add(<OrderChange>[order('draft1')]);
    feed.add(<OrderChange>[order('draft1')]);
    await pumpEventQueue();
    expect(alerts.map((OrderAlert a) => a.orderId), <String>['new1', 'draft1']);

    await service.dispose();
    await feed.close();
  });
}
