import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fmcg_sales/services/cart_draft_cache.dart';

void main() {
  test('assigned visits to the same retailer use separate draft keys', () {
    final String firstStop = CartDraftCache.keyFor(
      salesmanUid: 'sales-1',
      retailerId: 'retailer-1',
      routePlanId: 'route-1',
      routeStopId: 'stop-1',
    );
    final String secondStop = CartDraftCache.keyFor(
      salesmanUid: 'sales-1',
      retailerId: 'retailer-1',
      routePlanId: 'route-1',
      routeStopId: 'stop-2',
    );
    expect(firstStop, isNot(secondStop));
    expect(
      () => CartDraftCache.keyFor(
        salesmanUid: 'sales-1',
        retailerId: 'retailer-1',
        routePlanId: 'route-1',
      ),
      throwsArgumentError,
    );
  });

  test(
    'failed durable writes are reported and the next save can recover',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final String key = CartDraftCache.keyFor(
        salesmanUid: 'sales-failure',
        retailerId: 'retailer-failure',
      );
      final result = await CartDraftCache.saveAndWait(
        key,
        CartDraftSnapshot(
          salesmanUid: 'sales-failure',
          retailerId: 'retailer-failure',
          items: <Map<String, dynamic>>[
            {'price': double.nan},
          ],
        ),
      );
      expect(result.isSaved, isFalse);
      final recovered = await CartDraftCache.saveAndWait(
        key,
        CartDraftSnapshot(
          salesmanUid: 'sales-failure',
          retailerId: 'retailer-failure',
          pendingOrderId: 'ORDER-preserved',
        ),
      );
      expect(recovered.isSaved, isTrue);
      final preferences = await SharedPreferences.getInstance();
      final envelope = jsonDecode(preferences.getString(key)!);
      final stored = jsonDecode(envelope['data'] as String);
      expect(stored['pendingOrderId'], 'ORDER-preserved');
    },
  );
}
