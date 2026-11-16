import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/services/guided_visit_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('the same stop is isolated between salespeople', () async {
    await GuidedVisitSessionStore.markOrderSubmitted(
      salesmanUid: 'session-user-a',
      routePlanId: 'shared-plan',
      routeStopId: 'shared-stop',
    );

    signInTestUser('session-user-a');
    final own = await GuidedVisitSessionStore.read(
      salesmanUid: 'session-user-a',
      routePlanId: 'shared-plan',
      routeStopId: 'shared-stop',
    );
    signInTestUser('session-user-b');
    final other = await GuidedVisitSessionStore.read(
      salesmanUid: 'session-user-b',
      routePlanId: 'shared-plan',
      routeStopId: 'shared-stop',
    );

    expect(own.orderSubmitted, isTrue);
    expect(other.orderSubmitted, isFalse);
    expect(other.orderAbsenceVerified, isFalse);
    expect(other.outcomeRecorded, isFalse);
  });

  test(
    'collision-prone punctuation and Unicode identities stay distinct',
    () async {
      await GuidedVisitSessionStore.markOrderAbsenceVerified(
        salesmanUid: 'session-unicode-user',
        routePlanId: 'route/a',
        routeStopId: 'stop:é',
      );

      final collidingUnderLegacySanitizing = await GuidedVisitSessionStore.read(
        salesmanUid: 'session-unicode-user',
        routePlanId: 'route a',
        routeStopId: 'stop é',
      );
      expect(collidingUnderLegacySanitizing.orderAbsenceVerified, isFalse);
    },
  );

  test('clearing one user cannot clear another user state', () async {
    for (final uid in <String>['session-clear-a', 'session-clear-b']) {
      await GuidedVisitSessionStore.markOutcomeRecorded(
        salesmanUid: uid,
        routePlanId: 'clear-plan',
        routeStopId: 'clear-stop',
      );
    }
    await GuidedVisitSessionStore.clear(
      salesmanUid: 'session-clear-b',
      routePlanId: 'clear-plan',
      routeStopId: 'clear-stop',
    );

    signInTestUser('session-clear-a');
    expect(
      (await GuidedVisitSessionStore.read(
        salesmanUid: 'session-clear-a',
        routePlanId: 'clear-plan',
        routeStopId: 'clear-stop',
      )).outcomeRecorded,
      isTrue,
    );
    signInTestUser('session-clear-b');
    expect(
      (await GuidedVisitSessionStore.read(
        salesmanUid: 'session-clear-b',
        routePlanId: 'clear-plan',
        routeStopId: 'clear-stop',
      )).outcomeRecorded,
      isFalse,
    );
  });

  test('completion pending is durable and independently clearable', () async {
    const uid = 'session-pending-user';
    signInTestUser(uid);
    await GuidedVisitSessionStore.markCompletionPending(
      salesmanUid: uid,
      routePlanId: 'pending-plan',
      routeStopId: 'pending-stop',
    );
    expect(
      (await GuidedVisitSessionStore.read(
        salesmanUid: uid,
        routePlanId: 'pending-plan',
        routeStopId: 'pending-stop',
      )).completionPending,
      isTrue,
    );

    await GuidedVisitSessionStore.clearCompletionPending(
      salesmanUid: uid,
      routePlanId: 'pending-plan',
      routeStopId: 'pending-stop',
    );
    expect(
      (await GuidedVisitSessionStore.read(
        salesmanUid: uid,
        routePlanId: 'pending-plan',
        routeStopId: 'pending-stop',
      )).completionPending,
      isFalse,
    );
  });
}
