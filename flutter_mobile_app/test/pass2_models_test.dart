import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/services/cart_draft_cache.dart';
import 'package:fmcg_sales/utils/order_submission_id.dart';

void main() {
  test('order submission ID remains stable across timeout retries', () {
    final firstAttemptAt = DateTime.fromMillisecondsSinceEpoch(1000);
    final firstId = resolveOrderSubmissionId('', firstAttemptAt);

    expect(firstId, matches(RegExp(r'^ORD-P1-[0-9a-f]{32}$')));
    expect(
      resolveOrderSubmissionId(
        firstId,
        DateTime.fromMillisecondsSinceEpoch(2000),
      ),
      firstId,
    );
    expect(
      resolveOrderSubmissionId(
        'ORD-1000',
        DateTime.fromMillisecondsSinceEpoch(2000),
      ),
      'ORD-1000',
    );
    final replacement = resolveOrderSubmissionId(
      'invalid/order-id',
      DateTime.fromMillisecondsSinceEpoch(3000),
    );
    expect(replacement, matches(RegExp(r'^ORD-P1-[0-9a-f]{32}$')));
    expect(replacement, isNot(firstId));

    final restoredDraft = CartDraftSnapshot(
      salesmanUid: 'U001',
      retailerId: 'R001',
      pendingOrderId: firstId,
    ).copyWith(progress: 4);
    expect(restoredDraft.pendingOrderId, firstId);
  });

  test('restored order identity must match the same salesman and retailer', () {
    final order = <String, dynamic>{
      'orderId': 'ORD-1000',
      'salesmanUid': 'U001',
      'retailerId': 'R001',
      'routePlanId': 'route-1',
      'routeStopId': 'stop-1',
    };

    expect(isOrderSubmissionId(' ORD-1000 '), isTrue);
    expect(isOrderSubmissionId('invalid/order-id'), isFalse);
    expect(
      matchesOrderSubmissionIdentity(
        order,
        orderId: 'ORD-1000',
        salesmanUid: 'U001',
        retailerId: 'R001',
      ),
      isTrue,
    );
    expect(
      matchesOrderSubmissionIdentity(
        order,
        orderId: 'ORD-1000',
        salesmanUid: 'U002',
        retailerId: 'R001',
      ),
      isFalse,
    );
    expect(
      matchesOrderSubmissionIdentity(
        order,
        orderId: 'ORD-1000',
        salesmanUid: 'U001',
        retailerId: 'R001',
        routePlanId: 'route-1',
        routeStopId: 'stop-1',
      ),
      isTrue,
    );
    expect(
      matchesOrderSubmissionIdentity(
        order,
        orderId: 'ORD-1000',
        salesmanUid: 'U001',
        retailerId: 'R001',
        routePlanId: 'route-1',
        routeStopId: 'another-stop',
      ),
      isFalse,
    );
  });
}
