import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/company_lifecycle.dart';
import 'package:fmcg_sales/services/company_api.dart';
import 'package:fmcg_sales/services/company_lifecycle_monitor.dart';
import 'package:fmcg_sales/services/held_work_sync.dart';

class PausedCompanyApi extends CompanyApi {
  @override
  bool get enabled => true;
  @override
  Future<CompanyLifecycle?> readLifecycle() async => CompanyLifecycle(
    state: 'suspended',
    access: 'cut',
    cutAt: DateTime.utc(2026, 11, 8),
  );
}

class StalledUploadSync extends HeldWorkSync {
  final Completer<int> upload = Completer<int>();
  int flushes = 0;
  @override
  Future<int> flush(String uid, CompanyLifecycle lifecycle) {
    flushes++;
    return upload.future;
  }

  @override
  Future<HeldWorkCounts> counts(
    String uid,
    CompanyLifecycle? lifecycle,
  ) async => const HeldWorkCounts();
}

void main() {
  test('a slow held upload does not hold up a screen that only asks the '
      'company state', () async {
    final StalledUploadSync sync = StalledUploadSync();
    final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor(
      api: PausedCompanyApi(),
      sync: sync,
    );
    addTearDown(monitor.stop);
    monitor.start('salesperson-1');
    await pumpEventQueue();
    expect(sync.flushes, 1);

    final CompanyLifecycle? lifecycle = await monitor
        .refresh(upload: false)
        .timeout(const Duration(seconds: 2));

    expect(lifecycle?.access, 'cut');
    expect(monitor.paused, isTrue);
    expect(sync.flushes, 1);
    sync.upload.complete(0);
  });
}
