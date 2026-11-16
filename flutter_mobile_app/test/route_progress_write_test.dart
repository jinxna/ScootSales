import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/services/route_plan_service.dart';

void main() {
  test('a timed-out write reports a locally durable pending state', () async {
    final never = Completer<void>();
    final result = await awaitRouteProgressWrite(
      write: never.future,
      readCachedState: () async => RouteProgressWriteState.pending,
      wait: const Duration(milliseconds: 1),
    );
    expect(result, RouteProgressWriteState.pending);
  });

  test('a timeout without a matching local write remains an error', () async {
    final never = Completer<void>();
    await expectLater(
      awaitRouteProgressWrite(
        write: never.future,
        readCachedState: () async => null,
        wait: const Duration(milliseconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a rejected write is never mislabeled as pending', () async {
    await expectLater(
      awaitRouteProgressWrite(
        write: Future<void>.error(StateError('denied')),
        readCachedState: () async => RouteProgressWriteState.pending,
      ),
      throwsStateError,
    );
  });
}
