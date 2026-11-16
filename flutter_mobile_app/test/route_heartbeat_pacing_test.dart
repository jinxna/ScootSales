// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/services/route_plan_service.dart';

void main() {
  test(
    'a route screen that rebuilds and resumes many times writes a heartbeat at most once per 5 minutes',
    () {
      fakeAsync((FakeAsync async) {
        final DateTime start = DateTime.utc(2026, 11, 9, 8);
        final RouteHeartbeatPacer pacer = RouteHeartbeatPacer(
          now: () => start.add(async.elapsed),
        );
        final List<Duration> writes = <Duration>[];
        bool send() {
          writes.add(async.elapsed);
          return true;
        }

        const String current = 'plan-2_sales-1';
        for (int tick = 0; tick < 240; tick++) {
          pacer.stop();
          pacer.start(current, send);
          pacer.start(current, send);
          if (tick % 7 == 0) {
            pacer.pause();
            pacer.start(current, send);
          }
          async.elapse(const Duration(seconds: 5));
        }

        expect(writes, <Duration>[
          Duration.zero,
          const Duration(minutes: 5),
          const Duration(minutes: 10),
          const Duration(minutes: 15),
          const Duration(minutes: 20),
        ]);
      });
    },
  );
}
