import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/services/sales_visit_copilot_service.dart';
import 'package:fmcg_sales/utils/retailer_memory.dart';

void main() {
  RetailerMemory populatedHistory() => RetailerMemory(
    outcomeCount: 2,
    demoCount: 0,
    mostRecentAt: DateTime(2026, 9, 26),
    topReasons: const <ReasonStat>[
      ReasonStat(reasonCode: 'retailer_busy', count: 2, share: 1),
    ],
    priceSensitivityShare: 0,
    isPriceSensitive: false,
    hasSeasonalitySignal: false,
    commonReplacements: const <ReplacementStat>[],
    lastIssues: const <IssueMemory>[],
    confidence: 0.5,
  );

  test(
    'history cache scopes identity, invalidates, and retries failures',
    () async {
      final RetailerMemoryRequestCache cache = RetailerMemoryRequestCache();
      int loads = 0;

      Future<RetailerMemory?> load() async {
        loads += 1;
        return populatedHistory();
      }

      final Future<RetailerMemory?> first = cache.load(
        uid: 'user-a',
        retailerId: 'retailer-1',
        loader: load,
      );
      final Future<RetailerMemory?> same = cache.load(
        uid: 'user-a',
        retailerId: 'retailer-1',
        loader: load,
      );
      expect(identical(first, same), isTrue);
      await first;
      expect(loads, 1);

      await cache.load(uid: 'user-b', retailerId: 'retailer-1', loader: load);
      await cache.load(uid: 'user-a', retailerId: 'retailer-2', loader: load);
      expect(loads, 3);

      cache.invalidate(uid: 'user-a', retailerId: 'retailer-1');
      await cache.load(uid: 'user-a', retailerId: 'retailer-1', loader: load);
      expect(loads, 4);
      await cache.load(uid: 'user-b', retailerId: 'retailer-1', loader: load);
      expect(loads, 4);

      int failures = 0;
      Future<RetailerMemory?> failThenSucceed() async {
        failures += 1;
        return failures == 1 ? null : populatedHistory();
      }

      expect(
        await cache.load(
          uid: 'user-c',
          retailerId: 'retailer-1',
          loader: failThenSucceed,
        ),
        isNull,
      );
      expect(
        await cache.load(
          uid: 'user-c',
          retailerId: 'retailer-1',
          loader: failThenSucceed,
        ),
        isNotNull,
      );
      expect(failures, 2);
    },
  );

  test('overlapping refresh failures cannot poison a later retry', () async {
    final RetailerMemoryRequestCache cache = RetailerMemoryRequestCache();
    final List<Completer<RetailerMemory?>> requests =
        <Completer<RetailerMemory?>>[];
    int loads = 0;

    Future<RetailerMemory?> load() {
      loads += 1;
      final Completer<RetailerMemory?> completer = Completer<RetailerMemory?>();
      requests.add(completer);
      return completer.future;
    }

    final Future<RetailerMemory?> first = cache.load(
      uid: 'user-a',
      retailerId: 'retailer-1',
      loader: load,
      forceRefresh: true,
    );
    final Future<RetailerMemory?> second = cache.load(
      uid: 'user-a',
      retailerId: 'retailer-1',
      loader: load,
      forceRefresh: true,
    );
    expect(loads, 2);

    final Future<void> firstFailure = expectLater(
      first,
      throwsA(isA<StateError>()),
    );
    requests[0].completeError(StateError('first refresh failed'));
    await firstFailure;

    final Future<void> secondFailure = expectLater(
      second,
      throwsA(isA<StateError>()),
    );
    requests[1].completeError(StateError('second refresh failed'));
    await secondFailure;

    final Future<RetailerMemory?> retry = cache.load(
      uid: 'user-a',
      retailerId: 'retailer-1',
      loader: load,
    );
    expect(
      loads,
      3,
      reason: 'a failed overlapping refresh must not be replayed as cache',
    );
    requests[2].complete(populatedHistory());
    expect(await retry, isNotNull);
  });

  test('an invalidated in-flight request cannot repopulate history', () async {
    final RetailerMemoryRequestCache cache = RetailerMemoryRequestCache();
    final List<Completer<RetailerMemory?>> requests =
        <Completer<RetailerMemory?>>[];
    int loads = 0;

    Future<RetailerMemory?> load() {
      loads += 1;
      final Completer<RetailerMemory?> completer = Completer<RetailerMemory?>();
      requests.add(completer);
      return completer.future;
    }

    final Future<RetailerMemory?> obsolete = cache.load(
      uid: 'user-a',
      retailerId: 'retailer-1',
      loader: load,
      forceRefresh: true,
    );
    cache.invalidate(uid: 'user-a', retailerId: 'retailer-1');
    final Future<RetailerMemory?> current = cache.load(
      uid: 'user-a',
      retailerId: 'retailer-1',
      loader: load,
      forceRefresh: true,
    );
    expect(loads, 2);

    requests[0].complete(populatedHistory());
    await obsolete;
    final Future<void> currentFailure = expectLater(
      current,
      throwsA(isA<StateError>()),
    );
    requests[1].completeError(StateError('current refresh failed'));
    await currentFailure;

    final Future<RetailerMemory?> retry = cache.load(
      uid: 'user-a',
      retailerId: 'retailer-1',
      loader: load,
    );
    expect(
      loads,
      3,
      reason:
          'invalidated history must not be restored from a superseded request',
    );
    requests[2].complete(populatedHistory());
    expect(await retry, isNotNull);
  });
}
