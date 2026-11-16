import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/assigned_route_plan.dart';
import 'package:fmcg_sales/utils/assigned_route_lifecycle.dart';

void main() {
  test(
    'VP-03 a suggested stop on another day names that day and the Week tab',
    () {
      final AssignedRouteStop stop = AssignedRouteStop(
        stopId: 's1',
        dayId: 'fri',
        retailerId: 'r1',
        retailerName: 'Emart Moyan',
        address: 'Moyan, Kuching',
        lat: 1.5,
        lng: 110.3,
        sequence: 1,
        estimatedArrival: '09:02',
        estimatedDeparture: '09:22',
        priorityReason: '',
        status: 'not_started',
      );
      final AssignedRoutePlan plan = AssignedRoutePlan(
        id: 'p1',
        weekStart: DateTime(2026, 11, 9),
        weekEnd: DateTime(2026, 11, 14),
        status: 'published',
        source: 'dashboard',
        salesmanUid: 'u1',
        salesmanCode: 'S001',
        salesmanName: 'Salesperson',
        branchId: 'b1',
        isDemo: false,
        days: <AssignedRouteDay>[
          AssignedRouteDay(
            dayId: 'fri',
            dayLabel: 'Friday',
            date: DateTime(2026, 11, 13),
            stops: <AssignedRouteStop>[stop],
            totalDistanceKm: 1,
          ),
        ],
      );

      final String otherDay = suggestedStopHint(
        plan,
        stop,
        now: DateTime(2026, 11, 12, 10),
      );
      expect(otherDay, contains('Friday • 13 Nov'));
      expect(otherDay, contains('Week tab'));
      expect(otherDay, contains('not today'));

      expect(
        suggestedStopHint(plan, stop, now: DateTime(2026, 11, 13, 10)),
        'Suggested first pending stop. Tap “Go to this stop” to save it as the destination.',
      );
    },
  );

  test('VP-03 a suggested stop whose day has no date says another day', () {
    final AssignedRouteStop stop = AssignedRouteStop(
      stopId: 's1',
      dayId: 'd2',
      retailerId: 'r1',
      retailerName: 'Emart Moyan',
      address: 'Moyan, Kuching',
      lat: 1.5,
      lng: 110.3,
      sequence: 1,
      estimatedArrival: '09:02',
      estimatedDeparture: '09:22',
      priorityReason: '',
      status: 'not_started',
    );
    final AssignedRoutePlan plan = AssignedRoutePlan(
      id: 'p1',
      weekStart: DateTime(2026, 11, 9),
      weekEnd: DateTime(2026, 11, 14),
      status: 'published',
      source: 'dashboard',
      salesmanUid: 'u1',
      salesmanCode: 'S001',
      salesmanName: 'Salesperson',
      branchId: 'b1',
      isDemo: false,
      days: <AssignedRouteDay>[
        AssignedRouteDay(
          dayId: 'd2',
          dayLabel: 'Day',
          date: null,
          stops: <AssignedRouteStop>[stop],
          totalDistanceKm: 1,
        ),
      ],
    );

    final String hint = suggestedStopHint(
      plan,
      stop,
      now: DateTime(2026, 11, 12, 10),
    );
    expect(hint, contains('It is planned for another day, not today.'));
    expect(hint, isNot(contains('Day,')));
    expect(hint, contains('Week tab'));
    expect(
      routeStopOtherDayLabel(plan, stop, now: DateTime(2026, 11, 12, 10)),
      'another day',
    );
  });
}
