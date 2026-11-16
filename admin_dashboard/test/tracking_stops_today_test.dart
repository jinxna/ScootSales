import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/route_plan.dart';
import 'package:flutter_web_app/pages/admin/views/salesman_activity_page.dart';

Map<String, dynamic> _day(DateTime date, int stops) => <String, dynamic>{
  'date': date,
  'stops': <Map<String, dynamic>>[
    for (int i = 0; i < stops; i++)
      <String, dynamic>{
        'retailerId': 'R${date.day}-$i',
        'retailerName': 'Shop $i',
        'lat': 1.5,
        'lng': 110.3,
      },
  ],
};

void main() {
  test('the planned stops for today come from today in the week plan', () {
    final RoutePlan plan = RoutePlan.fromMap('P1', <String, dynamic>{
      'status': 'published',
      'days': <Map<String, dynamic>>[
        _day(DateTime.utc(2026, 11, 8, 16), 6),
        _day(DateTime.utc(2026, 11, 9, 16), 4),
        _day(DateTime.utc(2026, 11, 10, 16), 7),
        _day(DateTime.utc(2026, 11, 12, 16), 5),
      ],
    });

    expect(routeStopsPlannedOn(plan, DateTime.utc(2026, 11, 10, 3)), 4);
    expect(routeStopsPlannedOn(plan, DateTime.utc(2026, 11, 10, 15, 59)), 4);
    expect(routeStopsPlannedOn(plan, DateTime.utc(2026, 11, 10, 16)), 7);
    expect(routeStopsPlannedOn(plan, DateTime.utc(2026, 11, 12, 3)), 0);
  });

  test(
    'today counts the stops of the published plan for today when next week is already published',
    () {
      final RoutePlan thisWeek = RoutePlan.fromMap('P1', <String, dynamic>{
        'status': 'published',
        'weekStart': DateTime.utc(2026, 11, 8, 16),
        'days': <Map<String, dynamic>>[
          _day(DateTime.utc(2026, 11, 8, 16), 6),
          _day(DateTime.utc(2026, 11, 9, 16), 4),
        ],
      });
      final RoutePlan nextWeek = RoutePlan.fromMap('P2', <String, dynamic>{
        'status': 'published',
        'weekStart': DateTime.utc(2026, 11, 15, 16),
        'days': <Map<String, dynamic>>[_day(DateTime.utc(2026, 11, 15, 16), 9)],
      });
      final RoutePlan draftForToday = RoutePlan.fromMap('P3', <String, dynamic>{
        'status': 'draft',
        'weekStart': DateTime.utc(2026, 11, 8, 16),
        'days': <Map<String, dynamic>>[_day(DateTime.utc(2026, 11, 9, 16), 3)],
      });
      final DateTime today = DateTime.utc(2026, 11, 10, 3);

      expect(routeStopsPlannedToday(<RoutePlan>[thisWeek, nextWeek], today), 4);
      expect(routeStopsPlannedToday(<RoutePlan>[nextWeek, thisWeek], today), 4);
      expect(
        routeStopsPlannedToday(<RoutePlan>[
          thisWeek,
          nextWeek,
          draftForToday,
        ], today),
        4,
      );
      expect(routeStopsPlannedToday(<RoutePlan>[nextWeek], today), 0);
    },
  );
}
