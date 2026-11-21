import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/models/route_plan.dart';
import 'package:flutter_web_app/services/route_planning_service.dart';
import 'package:flutter_web_app/utils/route_ranking_selection.dart';

Map<String, dynamic> _shop(
  String id,
  String region,
  double lat,
  double lng, {
  String day = '',
}) => <String, dynamic>{
  'docId': id,
  'name': id,
  'region': region,
  'latitude': lat,
  'longitude': lng,
  if (day.isNotEmpty) 'preferredVisitDays': <String>[day],
};

const RouteRankingInput _ranking = RouteRankingInput(
  rankingId: 'ranking_1',
  weekKey: '2026-W48',
  rankByRetailer: <String, int>{
    'matang_1': 1,
    'matang_2': 2,
    'tabuan_1': 3,
    'tabuan_2': 4,
    'petra_jaya': 5,
  },
  nameByRetailer: <String, String>{},
  reasonByRetailer: <String, String>{},
);

const String _nearestReason =
    'Not in the weekly ranking. Placed with the nearest shops.';

Future<RoutePlan> _plan(List<Map<String, dynamic>> shops, int maxPerDay) =>
    RoutePlanningService(geoapifyApiKey: '').generateWeeklyRoute(
      salesmanUid: 'u1',
      salesmanName: 'Sam',
      weekStart: DateTime(2026, 11, 23),
      retailers: shops,
      branchId: 'b1',
      createdByUid: 'admin',
      maxPerDay: maxPerDay,
      ranking: _ranking,
    );

int _dayOf(RoutePlan plan, String id) => plan.days.indexWhere(
  (RouteDay day) => day.stops.any((RouteStop stop) => stop.retailerId == id),
);

RouteStop _stop(RoutePlan plan, String id) => plan.days
    .expand((RouteDay day) => day.stops)
    .firstWhere((RouteStop stop) => stop.retailerId == id);

List<List<String>> _days(RoutePlan plan) => <List<String>>[
  for (final RouteDay day in plan.days)
    <String>[for (final RouteStop stop in day.stops) stop.retailerId]..sort(),
];

final List<Map<String, dynamic>> _packed = <Map<String, dynamic>>[
  _shop('matang_1', 'Matang', 1.5650, 110.3100),
  _shop('matang_2', 'Matang', 1.5655, 110.3105),
  _shop('tabuan_1', 'Tabuan', 1.5220, 110.3810),
  _shop('tabuan_2', 'Tabuan', 1.5225, 110.3815),
];

final List<Map<String, dynamic>> _split = <Map<String, dynamic>>[
  _shop('matang_1', 'Matang', 1.5650, 110.3100),
  _shop('matang_2', 'Matang', 1.5655, 110.3105),
  _shop('tabuan_1', 'Tabuan', 1.5220, 110.3810, day: 'Wednesday'),
  _shop('tabuan_2', 'Tabuan', 1.5225, 110.3815, day: 'Wednesday'),
];

void main() {
  test(
    'a full Monday sends an unranked shop to the next day with room, not to a day of its own',
    () async {
      final RoutePlan plan = await _plan(<Map<String, dynamic>>[
        ..._packed,
        _shop('swinburne', 'Kuching Central', 1.5320, 110.3570),
      ], 3);

      expect(_days(plan), <List<String>>[
        <String>['matang_1', 'matang_2', 'tabuan_1'],
        <String>['swinburne', 'tabuan_2'],
        <String>[],
        <String>[],
        <String>[],
        <String>[],
      ]);
      expect(_stop(plan, 'swinburne').reason, _nearestReason);
    },
  );

  final List<(String, Map<String, dynamic>, int)> nearest =
      <(String, Map<String, dynamic>, int)>[
        (
          'an unranked shop near Tabuan joins the Tabuan day',
          _shop('swinburne', 'Kuching Central', 1.5320, 110.3570),
          2,
        ),
        (
          'an unranked shop near Matang joins the Matang day',
          _shop('near_matang', 'Petra Jaya', 1.5640, 110.3150),
          0,
        ),
        (
          'a ranked shop in an area of its own near Matang joins the Matang day',
          _shop('petra_jaya', 'Petra Jaya', 1.5640, 110.3200),
          0,
        ),
      ];
  for (final (String name, Map<String, dynamic> shop, int day) in nearest) {
    test('$name when two days have room', () async {
      final RoutePlan plan = await _plan(<Map<String, dynamic>>[
        ..._split,
        shop,
      ], 6);
      final String id = shop['docId'] as String;

      expect(_dayOf(plan, 'matang_1'), 0);
      expect(_dayOf(plan, 'tabuan_1'), 2);
      expect(_dayOf(plan, id), day);
      expect(_stop(plan, id).reason, endsWith('Placed with the nearest shops.'));
    });
  }

  test('a nearest day that is full sends the shop to the next nearest day',
      () async {
    final RoutePlan plan = await _plan(<Map<String, dynamic>>[
      ..._split,
      _shop('swinburne', 'Kuching Central', 1.5320, 110.3570),
      _shop('near_tabuan', 'Pending', 1.5230, 110.3800),
    ], 3);

    expect(_dayOf(plan, 'swinburne'), 2);
    expect(_dayOf(plan, 'near_tabuan'), 0);
    for (final RouteDay day in plan.days) {
      expect(day.stops.length, lessThanOrEqualTo(3), reason: day.dayLabel);
    }
  });

  test('one ranked shop and one unranked shop share one day', () async {
    final RoutePlan plan = await _plan(<Map<String, dynamic>>[
      _shop('matang_1', 'Matang', 1.5650, 110.3100),
      _shop('swinburne', 'Kuching Central', 1.5320, 110.3570),
    ], 6);

    expect(_dayOf(plan, 'swinburne'), _dayOf(plan, 'matang_1'));
  });
}
