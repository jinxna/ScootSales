import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/models/route_plan.dart';
import 'package:flutter_web_app/services/route_planning_service.dart';

List<Map<String, dynamic>> _retailers() => <Map<String, dynamic>>[
  for (int i = 0; i < 7; i++)
    <String, dynamic>{
      'docId': 'r$i',
      'name': 'Shop $i',
      'latitude': 1.55 + i * 0.0001,
      'longitude': 110.35,
    },
];

Future<Set<String>> _plannedIds(
  Map<String, DateTime> lastVisitByRetailer,
) async {
  final RoutePlan plan = await RoutePlanningService(geoapifyApiKey: '')
      .generateWeeklyRoute(
        salesmanUid: 'u1',
        salesmanName: 'Sam',
        weekStart: DateTime(2026, 11, 9),
        retailers: _retailers(),
        branchId: 'b1',
        createdByUid: 'admin',
        maxPerDay: 1,
        lastVisitByRetailer: lastVisitByRetailer,
      );
  return <String>{
    for (final RouteDay day in plan.days)
      for (final RouteStop stop in day.stops) stop.retailerId,
  };
}

void main() {
  test('a shop visited yesterday is left out when the week has no room for all',
      () async {
    final DateTime yesterday = DateTime.now().subtract(const Duration(days: 1));

    final Set<String> companyOne = await _plannedIds(<String, DateTime>{
      'r3': yesterday,
    });
    final Set<String> companyTwo = await _plannedIds(<String, DateTime>{
      'r5': yesterday,
    });

    expect(companyOne, hasLength(6));
    expect(companyOne, isNot(contains('r3')));
    expect(companyTwo, hasLength(6));
    expect(companyTwo, isNot(contains('r5')));
    expect(companyTwo, contains('r3'));
  });
}
