import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/assigned_route_plan.dart';
import 'package:fmcg_sales/models/route_stop_lifecycle_event.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/services/route_plan_service.dart';
import 'package:fmcg_sales/services/route_stop_outbox.dart';
import 'package:fmcg_sales/utils/assigned_route_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

RouteStopLifecycleEvent _event(String stopId, {required String lastError}) =>
    RouteStopLifecycleEvent(
      uid: 'u1',
      planId: 'p',
      stopId: stopId,
      workSessionId: 'w',
      workSessionGeneration: 1,
      sessionEventSequence: int.parse(stopId.substring(1)),
      eventId: 'e-$stopId',
      status: 'arrived',
      deviceOccurredAt: DateTime.utc(2026, 1, 1),
      payload: const <String, dynamic>{},
      expectedSelectedStopId: stopId,
      expectedSelectionRevision: 0,
      state: RouteStopOutboxState.needsAttention,
      lastError: lastError,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signInTestUser('u1');
  });

  test('the attention reason is the one of the stop that failed', () async {
    final RouteStopOutbox outbox = RouteStopOutbox(projectId: testProjectId);
    await outbox.put(_event('s1', lastError: 'The stop is no longer pending.'));
    await outbox.put(
      _event('s2', lastError: 'The published route assignment changed.'),
    );
    final AssignedRoutePlan plan = AssignedRoutePlan(
      id: 'p',
      weekStart: DateTime(2026, 1, 5),
      weekEnd: DateTime(2026, 1, 11),
      status: 'published',
      source: 'dashboard',
      salesmanUid: 'u1',
      salesmanCode: 'S001',
      salesmanName: 'Rep',
      branchId: 'b',
      isDemo: false,
      days: const <AssignedRouteDay>[],
    );
    final UserModel user = UserModel(
      uid: 'u1',
      staffId: 'S001',
      name: 'Rep',
      email: 'r@example.test',
      phone: '',
      territory: '',
      role: 'salesman',
      joinedDate: '',
    );
    final RoutePlanService service = RoutePlanService();
    final String? reason = await service.stopEventAttentionReason(
      plan: plan,
      user: user,
      stopId: 's2',
    );
    expect(
      stopAttentionMessage(reason),
      contains('published this route again'),
    );
    expect(
      await service.stopEventAttentionReason(
        plan: plan,
        user: user,
        stopId: 's9',
      ),
      isNull,
    );
  });
}
