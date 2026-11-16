import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/company_lifecycle.dart';
import 'package:fmcg_sales/services/held_order_outbox.dart';
import 'package:fmcg_sales/services/held_work_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signInTestUser('u1');
  });

  test(
    'a held order written directly is not rewritten when tracking is retried',
    () async {
      final HeldOrderOutbox outbox = HeldOrderOutbox();
      final HeldOrder held = HeldOrder(
        orderId: 'o1',
        uid: 'u1',
        workSessionId: 'w',
        workSessionGeneration: 1,
        sessionStartedAt: DateTime.utc(2026, 1, 1),
        deviceAt: DateTime.utc(2026, 1, 1),
        payload: const <String, dynamic>{},
        state: HeldOrderState.held,
        tracking: const <String, dynamic>{'latitude': 1.5},
      );
      await outbox.put(held);
      int orderWrites = 0;
      bool trackingWorks = false;
      final HeldWorkSync sync = HeldWorkSync(
        orderWriter: (HeldOrder order) async => orderWrites++,
        trackingSettler: (HeldOrder order) async => trackingWorks,
      );
      const CompanyLifecycle open = CompanyLifecycle(
        state: 'active',
        access: 'open',
      );

      await sync.writeOrderDirectly(held, open);

      final List<HeldOrder> afterFirst = await outbox.readAll('u1');
      expect(orderWrites, 1);
      expect(afterFirst.single.state, HeldOrderState.pending);

      trackingWorks = true;
      expect(await sync.settleTrackingForTest(afterFirst.single, open), isTrue);
      expect(orderWrites, 1);
    },
  );
}
