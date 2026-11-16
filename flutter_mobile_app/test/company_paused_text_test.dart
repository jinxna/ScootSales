import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/company_lifecycle.dart';
import 'package:fmcg_sales/services/company_api.dart';
import 'package:fmcg_sales/services/company_lifecycle_monitor.dart';
import 'package:fmcg_sales/services/held_work_sync.dart';
import 'package:fmcg_sales/screens/company_paused_screen.dart';

class _PausedApi extends CompanyApi {
  @override
  bool get enabled => true;
  @override
  Future<CompanyLifecycle?> readLifecycle() async => CompanyLifecycle(
    state: 'suspended',
    access: 'cut',
    cutAt: DateTime.utc(2026, 11, 8),
  );
}

class _FakeSync extends HeldWorkSync {
  _FakeSync(this.heldCounts, this.workToUpload);
  final HeldWorkCounts heldCounts;
  final bool workToUpload;
  @override
  Future<int> flush(String uid, CompanyLifecycle lifecycle) async => 0;
  @override
  Future<HeldWorkCounts> counts(
    String uid,
    CompanyLifecycle? lifecycle,
  ) async => heldCounts;
  @override
  Future<bool> hasWorkToUpload(
    String uid, {
    bool includeNotAccepted = true,
  }) async => workToUpload;
}

Future<CompanyLifecycleMonitor> _pumpPaused(
  WidgetTester tester,
  HeldWorkCounts counts,
  bool workToUpload,
) async {
  final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor(
    api: _PausedApi(),
    sync: _FakeSync(counts, workToUpload),
  );
  monitor.start('salesperson-1');
  await tester.runAsync(() => monitor.refresh());
  await tester.pumpWidget(
    MaterialApp(
      home: CompanyPausedScreen(
        monitor: monitor,
        showStatusStrip: false,
        onSignOut: () {},
      ),
    ),
  );
  return monitor;
}

void main() {
  test(
    'FIX-119 a cancelled company is not promised that held work uploads later',
    () {
      final String cancelled = companyPausedKeptText('cancelled');
      expect(cancelled, isNot(contains('will upload when')));
      expect(cancelled, contains('only if the company is reactivated'));
      expect(
        companyPausedKeptText('suspended'),
        'Your work is kept and will upload when the company is active again.',
      );
    },
  );

  testWidgets('a paused phone with no held work does not promise an upload', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CompanyPausedScreen(
          monitor: CompanyLifecycleMonitor(),
          showStatusStrip: false,
          onSignOut: () {},
        ),
      ),
    );
    expect(find.text('No work is held on this phone.'), findsOneWidget);
    expect(find.textContaining('will upload'), findsNothing);
    expect(find.textContaining('uploads only if'), findsNothing);
  });

  testWidgets('a pending visit outcome is not shown as no held work', (
    WidgetTester tester,
  ) async {
    final CompanyLifecycleMonitor monitor = await _pumpPaused(
      tester,
      const HeldWorkCounts(),
      true,
    );
    expect(find.text('No work is held on this phone.'), findsNothing);
    expect(find.textContaining('will upload'), findsOneWidget);
    monitor.stop();
  });

  testWidgets('held route updates show their count and the kept text', (
    WidgetTester tester,
  ) async {
    final CompanyLifecycleMonitor monitor = await _pumpPaused(
      tester,
      const HeldWorkCounts(stops: 2),
      true,
    );
    expect(find.textContaining('2 items are held'), findsOneWidget);
    expect(find.textContaining('will upload'), findsOneWidget);
    monitor.stop();
  });

  testWidgets('truly nothing to upload says so', (WidgetTester tester) async {
    final CompanyLifecycleMonitor monitor = await _pumpPaused(
      tester,
      const HeldWorkCounts(),
      false,
    );
    expect(find.text('No work is held on this phone.'), findsOneWidget);
    monitor.stop();
  });
}
