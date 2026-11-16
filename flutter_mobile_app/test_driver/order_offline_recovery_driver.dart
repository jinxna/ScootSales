import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

final String adbPath = Platform.environment['ADB_PATH'] ?? 'adb';
const String packageId = 'my.scootsales.app';
const String firestoreBase =
    'http://127.0.0.1:8089/v1/projects/cos40005/databases/(default)/documents';
const String salesmanUid = 'BEdqZslfM0oBmV8YMHpHl2iETzyM';

String activeSalesmanUid = salesmanUid;
const String reportPath =
    '../qa_artifacts/runtime/offline_recovery_driver.json';

final Map<String, Object?> report = <String, Object?>{'steps': <String>[]};

void note(String message) {
  stdout.writeln('[recovery] $message');
  (report['steps']! as List<String>).add(message);
}

Future<ProcessResult> adb(List<String> args) async {
  return Process.run(adbPath, args);
}

Future<String> deviceLog() async {
  final ProcessResult result = await adb(<String>[
    'logcat',
    '-d',
    '-t',
    '4000',
  ]);
  return '${result.stdout}';
}

Future<void> setRadio({required bool on}) async {
  await adb(<String>['shell', 'svc', 'wifi', on ? 'enable' : 'disable']);
  await adb(<String>['shell', 'svc', 'data', on ? 'enable' : 'disable']);
  await adb(<String>[
    'shell',
    'cmd',
    'connectivity',
    'airplane-mode',
    on ? 'disable' : 'enable',
  ]);
  final ProcessResult mode = await adb(<String>[
    'shell',
    'settings',
    'get',
    'global',
    'airplane_mode_on',
  ]);
  final String airplane = '${mode.stdout}'.trim();
  note('radio ${on ? 'restored' : 'cut'} (airplane_mode_on=$airplane)');
}

Future<void> cutRadioDuringOfflineWindow() async {
  final DateTime deadline = DateTime.now().add(const Duration(minutes: 5));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final String log = await deviceLog();
    if (log.contains('order-ready-for-offline-submit')) {
      await setRadio(on: false);
      return;
    }
  }
  note('offline-window marker never appeared');
}

Future<List<String>> ordersForSalesman() async {
  final HttpClient client = HttpClient();
  final HttpClientRequest request = await client.getUrl(
    Uri.parse('$firestoreBase/orders?pageSize=200'),
  );
  request.headers.set('Authorization', 'Bearer owner');
  final HttpClientResponse response = await request.close();
  final String body = await response.transform(utf8.decoder).join();
  client.close();
  final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
  final List<dynamic> documents =
      (json['documents'] as List<dynamic>?) ?? <dynamic>[];
  final List<String> ids = <String>[];
  for (final dynamic document in documents) {
    final Map<String, dynamic> doc = document as Map<String, dynamic>;
    final String id = (doc['name'] as String).split('/').last;
    final Map<String, dynamic> fields =
        (doc['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final Map<String, dynamic> ownerField =
        (fields['salesmanUid'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String owner = (ownerField['stringValue'] as String?) ?? '';
    if (owner == activeSalesmanUid && id.startsWith('ORD-V2-')) ids.add(id);
  }
  return ids;
}

Future<List<String>> waitForOrder({required Duration timeout}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  List<String> ids = <String>[];
  while (DateTime.now().isBefore(deadline)) {
    ids = await ordersForSalesman();
    if (ids.isNotEmpty) return ids;
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  return ids;
}

Future<void> prepareDevice() async {
  await adb(<String>['shell', 'am', 'force-stop', packageId]);
  await adb(<String>['shell', 'pm', 'clear', packageId]);
  for (int attempt = 0; attempt < 6; attempt++) {
    final ProcessResult fine = await adb(<String>[
      'shell',
      'pm',
      'grant',
      packageId,
      'android.permission.ACCESS_FINE_LOCATION',
    ]);
    final ProcessResult coarse = await adb(<String>[
      'shell',
      'pm',
      'grant',
      packageId,
      'android.permission.ACCESS_COARSE_LOCATION',
    ]);
    if (fine.exitCode == 0 && coarse.exitCode == 0) {
      note('device prepared: app data cleared, location granted');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  note('device prepared: app data cleared, permission grant did not confirm');
}

Future<String> resolveSalesmanUid() async {
  final HttpClient client = HttpClient();
  final HttpClientRequest request = await client.getUrl(
    Uri.parse('$firestoreBase/visit_briefs/ret-2'),
  );
  request.headers.set('Authorization', 'Bearer owner');
  final HttpClientResponse response = await request.close();
  final String body = await response.transform(utf8.decoder).join();
  client.close();
  final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
  final Map<String, dynamic> fields =
      (json['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  final Map<String, dynamic> owner =
      (fields['salesmanUid'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  return (owner['stringValue'] as String?) ?? salesmanUid;
}

Future<void> dismissLocationAccuracyPrompt() async {
  final ProcessResult focus = await adb(<String>['shell', 'dumpsys', 'window']);
  if (!'${focus.stdout}'.contains('LocationSettingsCheckerActivity')) return;
  await adb(<String>['shell', 'uiautomator', 'dump', '/sdcard/ui.xml']);
  final ProcessResult dump = await adb(<String>[
    'shell',
    'cat',
    '/sdcard/ui.xml',
  ]);
  final RegExpMatch? node = RegExp(
    r'text="No thanks"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
  ).firstMatch('${dump.stdout}');
  if (node == null) {
    note(
      'location-accuracy prompt is focused but its dismiss button is missing',
    );
    return;
  }
  final int x = (int.parse(node.group(1)!) + int.parse(node.group(3)!)) ~/ 2;
  final int y = (int.parse(node.group(2)!) + int.parse(node.group(4)!)) ~/ 2;
  await adb(<String>['shell', 'input', 'tap', '$x', '$y']);
  note('dismissed the location-accuracy prompt');
}

Future<void> watchForSystemPrompts() async {
  final DateTime deadline = DateTime.now().add(const Duration(minutes: 15));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 5));
    try {
      await dismissLocationAccuracyPrompt();
    } catch (_) {}
  }
}

Future<bool> runAppTest() async {
  final FlutterDriver driver = await FlutterDriver.connect();
  final String jsonResult = await driver.requestData(
    null,
    timeout: const Duration(minutes: 20),
  );
  await driver.close();
  final Map<String, dynamic> result =
      json.decode(jsonResult) as Map<String, dynamic>;
  final bool passed = result['result'] == 'true';
  if (!passed) {
    note('app-side test failed: ${result['failureDetails']}');
  }
  return passed;
}

Future<void> restoreRadioAfterOfflineSubmit() async {
  final DateTime deadline = DateTime.now().add(const Duration(minutes: 8));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final String log = await deviceLog();
    if (log.contains('order-submitted-offline')) {
      await Future<void>.delayed(const Duration(seconds: 3));
      await setRadio(on: true);
      return;
    }
  }
  note('retry mode: the offline-submit marker never appeared');
}

Future<void> main() async {
  final bool retryMode = Platform.environment['OFFLINE_RETRY_MODE'] == '1';
  final ProcessResult clearedLog = await adb(<String>['logcat', '-c']);
  if (clearedLog.exitCode != 0) {
    throw StateError('Could not clear stale Android logcat before the E2E run');
  }
  note('cleared device log before reading flow markers');
  await setRadio(on: true);
  final Future<void> cut = cutRadioDuringOfflineWindow();
  final Future<void>? earlyRestore = retryMode
      ? restoreRadioAfterOfflineSubmit()
      : null;
  unawaited(watchForSystemPrompts());
  activeSalesmanUid = await resolveSalesmanUid();
  report['salesmanUid'] = activeSalesmanUid;
  bool appTestPassed = false;
  try {
    appTestPassed = await runAppTest();
  } catch (error) {
    note('app-side test could not be driven to completion: $error');
  }
  report['appTestPassed'] = appTestPassed;
  note('app-side test finished');
  await cut;

  final String logAfterAppTest = await deviceLog();
  final bool submittedOffline = logAfterAppTest.contains(
    'order-submitted-offline',
  );
  report['offlineSubmitObserved'] = submittedOffline;
  if (!submittedOffline) {
    note('inconclusive: the app-side test never reported an offline submit');
    final File inconclusive = File(reportPath);
    await inconclusive.parent.create(recursive: true);
    await inconclusive.writeAsString(
      const JsonEncoder.withIndent(' ').convert(report),
    );
    exit(2);
  }

  final List<String> beforeRelaunch = await ordersForSalesman();
  report['ordersBeforeRelaunch'] = beforeRelaunch;
  note('orders on the server before the relaunch: ${beforeRelaunch.length}');

  if (earlyRestore != null) {
    await earlyRestore;
    final List<String> afterRetry = await waitForOrder(
      timeout: const Duration(seconds: 60),
    );
    report['ordersAfterRetry'] = afterRetry;
    note('orders after the in-app retry: ${afterRetry.length}');
    await Future<void>.delayed(const Duration(seconds: 30));
    final List<String> settled = await ordersForSalesman();
    report['ordersAfterSettling'] = settled;
    note('orders 30s later (duplicate check): ${settled.length}');
    final File retryReport = File(reportPath);
    await retryReport.parent.create(recursive: true);
    await retryReport.writeAsString(
      const JsonEncoder.withIndent(' ').convert(report),
    );
    note('report written to $reportPath');
    if (afterRetry.length != 1 || settled.length != 1) {
      stderr.writeln(
        'RETRY FAILED: expected exactly one order, saw '
        '${afterRetry.length} then ${settled.length}',
      );
      exit(1);
    }
    stdout.writeln(
      'RETRY PASSED: exactly one order, no duplicate from the retry',
    );
    exit(0);
  }

  await adb(<String>['shell', 'am', 'force-stop', packageId]);
  note('app force-stopped with the radio off');
  await Future<void>.delayed(const Duration(seconds: 3));
  await adb(<String>[
    'shell',
    'monkey',
    '-p',
    packageId,
    '-c',
    'android.intent.category.LAUNCHER',
    '1',
  ]);
  note('app relaunched while still offline');
  await Future<void>.delayed(const Duration(seconds: 25));

  await setRadio(on: true);
  report['radioRestoredAt'] = DateTime.now().toIso8601String();

  final List<String> recovered = await waitForOrder(
    timeout: const Duration(seconds: 120),
  );
  report['ordersAfterReconnect'] = recovered;
  note('orders after reconnect without a Submit: ${recovered.length}');

  await Future<void>.delayed(const Duration(seconds: 30));
  final List<String> afterSettling = await ordersForSalesman();
  report['ordersAfterSettling'] = afterSettling;
  note('orders 30s later: ${afterSettling.length}');

  final File out = File(reportPath);
  await out.parent.create(recursive: true);
  await out.writeAsString(const JsonEncoder.withIndent(' ').convert(report));
  note('report written to $reportPath');

  if (recovered.isNotEmpty || afterSettling.isNotEmpty) {
    stderr.writeln(
      'RECOVERY FAILED: an offline draft reached the server without an explicit '
      'Submit (${recovered.length} then ${afterSettling.length} orders)',
    );
    exit(1);
  }
  stdout.writeln(
    'RECOVERY PASSED: the offline draft survived the force-stop and nothing was sent',
  );
  exit(0);
}
