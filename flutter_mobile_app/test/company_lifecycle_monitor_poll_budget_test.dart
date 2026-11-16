import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/company_lifecycle.dart';
import 'package:fmcg_sales/services/company_api.dart';
import 'package:fmcg_sales/services/company_lifecycle_monitor.dart';
import 'package:fmcg_sales/services/held_work_sync.dart';

class CountingApi extends CompanyApi {
  int reads = 0;
  @override
  bool get enabled => true;
  @override
  Future<CompanyLifecycle?> readLifecycle() async {
    reads++;
    return const CompanyLifecycle(state: 'active', access: 'open');
  }
}

class NothingHeldSync extends HeldWorkSync {
  @override
  Future<void> forgetStoredOrders(
    String uid,
    CompanyLifecycle lifecycle,
  ) async {}

  @override
  Future<HeldWorkCounts> counts(
    String uid,
    CompanyLifecycle? lifecycle,
  ) async => const HeldWorkCounts();

  @override
  Future<bool> hasWorkToUpload(
    String uid, {
    bool includeNotAccepted = true,
  }) async => false;
}

class HeldUntilSentSync extends HeldWorkSync {
  int flushes = 0;
  bool held = true;

  @override
  Future<int> flush(String uid, CompanyLifecycle lifecycle) async {
    flushes++;
    if (flushes < 3) return 0;
    held = false;
    return 1;
  }

  @override
  Future<HeldWorkCounts> counts(
    String uid,
    CompanyLifecycle? lifecycle,
  ) async => const HeldWorkCounts();

  @override
  Future<bool> hasWorkToUpload(
    String uid, {
    bool includeNotAccepted = true,
  }) async => held;
}

class ReactivatedApi extends CountingApi {
  @override
  Future<CompanyLifecycle?> readLifecycle() async {
    reads++;
    return CompanyLifecycle(
      state: 'active',
      access: 'open',
      cutAt: DateTime.utc(2026, 11, 16),
    );
  }
}

const Duration workDay = Duration(hours: 8);
const int callsAllowedPerOpenWorkDay = 97;

void main() {
  testWidgets('an open app asks the company state at most '
      '$callsAllowedPerOpenWorkDay times in an 8-hour day', (
    WidgetTester tester,
  ) async {
    final CountingApi api = CountingApi();
    final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor(
      api: api,
      sync: NothingHeldSync(),
    );
    monitor.start('salesperson-1');
    await tester.pump(workDay);
    expect(api.reads, lessThanOrEqualTo(callsAllowedPerOpenWorkDay));
    monitor.stop();
    expect(api.reads, greaterThan(1));
  });

  testWidgets('an app in the background asks nothing, and asks again on the '
      'timer once it is on screen again, focused or not', (WidgetTester tester) async {
    final CountingApi api = CountingApi();
    final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor(
      api: api,
      sync: NothingHeldSync(),
      recheckOnlyWhileOpen: true,
    );
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    monitor.start('salesperson-1');
    await tester.pump();
    expect(api.reads, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(workDay);
    expect(api.reads, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(CompanyLifecycleMonitor.recheckEvery);
    expect(api.reads, 2);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(CompanyLifecycleMonitor.recheckEvery);
    monitor.stop();
    expect(api.reads, 3);
  });

  testWidgets('an app in the background keeps sending held work until none '
      'is left, then stops asking', (WidgetTester tester) async {
    final ReactivatedApi api = ReactivatedApi();
    final HeldUntilSentSync sync = HeldUntilSentSync();
    final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor(
      api: api,
      sync: sync,
      recheckOnlyWhileOpen: true,
    );
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    monitor.start('salesperson-1');
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(workDay);
    monitor.stop();
    expect(sync.flushes, 3);
    expect(sync.held, isFalse);
    expect(api.reads, 3);
  });
}
