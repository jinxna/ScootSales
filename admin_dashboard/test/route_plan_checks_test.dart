import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/route_plan.dart';
import 'package:flutter_web_app/pages/admin/views/route_planner/route_plan_checks.dart';
import 'package:flutter_web_app/pages/admin/views/route_planner/route_road_refresh.dart';
import 'package:flutter_web_app/services/route_planning_service.dart';
import 'package:flutter_web_app/utils/retailer_readiness.dart';
import 'package:flutter_web_app/utils/route_ranking_selection.dart';

const RouteStartPoint _start = RouteStartPoint(
  name: 'Swinburne Sarawak',
  lat: 1.5320,
  lng: 110.3570,
);

const List<String> _labels = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

RouteStop _stop(
  String id, {
  String departure = '10:00',
  String reason = 'Reorder overdue.',
}) => RouteStop(
  stopId: id,
  retailerId: id,
  retailerName: 'Shop $id',
  address: '',
  lat: 1.54,
  lng: 110.34,
  sequence: 1,
  arrival: '09:40',
  departure: departure,
  legDistanceKm: 1,
  reason: reason,
  score: 50,
);

RouteDay _day(
  int index,
  List<RouteStop> stops, {
  String estimateSource = 'geoapify_routing',
  int returnTravelMinutes = 10,
}) => RouteDay(
  dayId: 'd$index',
  dayLabel: _labels[index],
  date: DateTime(2026, 11, 23 + index),
  stops: stops,
  totalDistanceKm: 5,
  estimateSource: estimateSource,
  returnTravelMinutes: returnTravelMinutes,
);

RoutePlan _plan(
  Map<int, RouteDay> days, {
  RouteStartPoint? start = _start,
  List<RouteFollowUpNotPlaced> followUps = const <RouteFollowUpNotPlaced>[],
}) => RoutePlan(
  id: 'p1',
  weekStart: DateTime(2026, 11, 23),
  weekEnd: DateTime(2026, 11, 28),
  status: 'draft',
  branchId: 'b1',
  createdByUid: 'admin',
  salesmanUid: 'u1',
  salesmanName: 'Sam',
  optimisationMethod: 'GeoapifyRouting',
  startPoint: start,
  followUpsNotPlaced: followUps,
  days: <RouteDay>[
    for (int i = 0; i < 6; i++) days[i] ?? _day(i, const <RouteStop>[]),
  ],
);

List<RouteCheck> _checks(
  RoutePlan plan, {
  int maxPerDay = 3,
  Map<String, CoordinateStatus> statuses = const <String, CoordinateStatus>{},
  Map<String, RouteRoadState> road = const <String, RouteRoadState>{},
}) => routePlanChecks(
  plan,
  maxPerDay: maxPerDay,
  coordinateStatusFor: (RouteStop s) => statuses[s.retailerId],
  roadStateFor: (String dayId) => road[dayId] ?? RouteRoadState.settled,
);

List<String> _messages(List<RouteCheck> checks) => <String>[
  for (final RouteCheck c in checks) c.message,
];

void main() {
  test('a clean draft has nothing to check', () {
    final RoutePlan plan = _plan(<int, RouteDay>{
      0: _day(0, <RouteStop>[_stop('a'), _stop('b')]),
      3: _day(3, <RouteStop>[_stop('c')]),
    });
    expect(_checks(plan), isEmpty);
  });

  test('a day over the stop limit is named with its count and the limit', () {
    final RouteDay full = _day(1, <RouteStop>[
      _stop('a'),
      _stop('b'),
      _stop('c'),
      _stop('d'),
    ]);
    final List<RouteCheck> checks = _checks(_plan(<int, RouteDay>{1: full}));
    expect(_messages(checks), <String>['Tuesday has 4 stops. The most is 3.']);
    expect(checks.single.kind, RouteCheckKind.overLimit);
    expect(checks.single.dayIndex, 1);

    final RouteDay fixed = full.copyWith(stops: full.stops.sublist(0, 3));
    expect(_checks(_plan(<int, RouteDay>{1: fixed})), isEmpty);
  });

  test('no stop limit set means no over-limit line', () {
    final RoutePlan plan = _plan(<int, RouteDay>{
      0: _day(0, <RouteStop>[_stop('a'), _stop('b')]),
    });
    expect(_checks(plan, maxPerDay: 0), isEmpty);
  });

  test('a day that ends after 18:00 says when it ends', () {
    final RoutePlan late = _plan(<int, RouteDay>{
      2: _day(2, <RouteStop>[
        _stop('a', departure: '18:05'),
      ], returnTravelMinutes: 20),
    });
    final List<RouteCheck> checks = _checks(late);
    expect(_messages(checks), <String>[
      'Wednesday ends at 18:25, after 18:00.',
    ]);
    expect(checks.single.kind, RouteCheckKind.lateReturn);
    expect(checks.single.dayIndex, 2);

    final RoutePlan onTime = _plan(<int, RouteDay>{
      2: _day(2, <RouteStop>[
        _stop('a', departure: '17:40'),
      ], returnTravelMinutes: 20),
    });
    expect(_checks(onTime), isEmpty);
  });

  test('without a start point the end time is not judged', () {
    final RoutePlan plan = _plan(<int, RouteDay>{
      0: _day(0, <RouteStop>[
        _stop('a', departure: '19:00'),
        _stop('b', departure: '19:30'),
      ]),
    }, start: null);
    expect(_checks(plan), isEmpty);
  });

  test('a shop with a missing or unusable location is named with its day', () {
    final RoutePlan plan = _plan(<int, RouteDay>{
      0: _day(0, <RouteStop>[_stop('a'), _stop('b')]),
      4: _day(4, <RouteStop>[_stop('c'), _stop('d'), _stop('e')]),
    });
    final List<RouteCheck> checks = _checks(
      plan,
      statuses: <String, CoordinateStatus>{
        'a': CoordinateStatus.missing,
        'b': CoordinateStatus.needsReview,
        'c': CoordinateStatus.candidate,
        'd': CoordinateStatus.invalid,
        'e': CoordinateStatus.verified,
      },
    );
    expect(_messages(checks), <String>[
      'Shop a on Monday has no usable map location.',
      'Shop d on Friday has no usable map location.',
    ]);
    expect(checks.map((RouteCheck c) => c.retailerId), <String>['a', 'd']);
    expect(checks.map((RouteCheck c) => c.dayIndex), <int>[0, 4]);
    expect(
      checks.every((RouteCheck c) => c.kind == RouteCheckKind.noLocation),
      isTrue,
    );
  });

  test('a shop placed with the nearest shops is named with its day', () {
    final RoutePlan plan = _plan(<int, RouteDay>{
      3: _day(3, <RouteStop>[
        _stop('a'),
        _stop('b', reason: '$kNotInWeeklyRanking. $kPlacedWithNearestShops'),
      ]),
    });
    final List<RouteCheck> checks = _checks(plan);
    expect(_messages(checks), <String>[
      'Shop b was put on Thursday with the nearest shops. Check that the day suits it.',
    ]);
    expect(checks.single.kind, RouteCheckKind.placedWithNearest);
    expect(checks.single.retailerId, 'b');
    expect(checks.single.dayIndex, 3);
  });

  test(
    'a shop the manager moved to another day is no longer said to be put there with the nearest shops',
    () {
      final RouteStop drafted = _stop(
        'b',
        reason: '$kNotInWeeklyRanking. $kPlacedWithNearestShops',
      );
      final RouteStop moved = drafted.copyWith(
        reason: routeReasonMovedByManager(drafted.reason),
      );
      expect(moved.reason, '$kNotInWeeklyRanking. Placed by the manager.');
      final RoutePlan plan = _plan(<int, RouteDay>{
        1: _day(1, <RouteStop>[_stop('a'), moved]),
      });
      expect(_checks(plan), isEmpty);
      expect(
        routeReasonMovedByManager('Reorder overdue.'),
        'Reorder overdue. Placed by the manager.',
      );
      expect(
        routeReasonMovedByManager(routeReasonMovedByManager(drafted.reason)),
        '$kNotInWeeklyRanking. Placed by the manager.',
      );
    },
  );

  test(
    'a shop the manager added and then moved keeps one sentence saying the manager added it',
    () {
      const String added = 'Reorder overdue. Added by the manager.';
      expect(routeReasonMovedByManager(added), added);
      expect(
        routeReasonMovedByManager(routeReasonMovedByManager(added)),
        added,
      );
      expect(
        routeReasonMovedByManager('Added by the manager.'),
        'Added by the manager.',
      );
    },
  );

  test(
    'a follow-up with no choice yet is listed; a placed or left-out one is not',
    () {
      final RoutePlan plan = _plan(
        <int, RouteDay>{
          0: _day(0, <RouteStop>[_stop('a')]),
        },
        followUps: const <RouteFollowUpNotPlaced>[
          RouteFollowUpNotPlaced(
            retailerId: 'f1',
            retailerName: 'Farley Matang',
            followUpDate: '2026-11-25',
          ),
          RouteFollowUpNotPlaced(
            retailerId: 'f2',
            retailerName: 'Emart Moyan',
            followUpDate: '2026-11-26',
            choice: RouteFollowUpNotPlaced.placed,
          ),
          RouteFollowUpNotPlaced(
            retailerId: 'f3',
            retailerName: 'Everwin',
            followUpDate: '2026-12-01',
            choice: RouteFollowUpNotPlaced.leftOut,
          ),
          RouteFollowUpNotPlaced(
            retailerId: 'f4',
            retailerName: 'AEON',
            followUpDate: '2026-12-02',
          ),
        ],
      );
      final List<RouteCheck> checks = _checks(plan);
      expect(_messages(checks), <String>[
        'The follow-up visit to Farley Matang on 25 Nov is not on the route.',
        'The follow-up visit to AEON on 2 Dec is not on the route.',
      ]);
      expect(checks.map((RouteCheck c) => c.dayIndex), <int?>[2, null]);
      expect(checks.map((RouteCheck c) => c.retailerId), <String>['f1', 'f4']);
    },
  );

  test('days with straight-line distances are listed in one line', () {
    final RoutePlan plan = _plan(<int, RouteDay>{
      0: _day(0, <RouteStop>[_stop('a')], estimateSource: ''),
      1: _day(1, <RouteStop>[_stop('b')], estimateSource: 'haversine'),
      2: _day(2, <RouteStop>[_stop('c')], estimateSource: 'haversine'),
      3: _day(3, <RouteStop>[_stop('d')], estimateSource: 'geoapify_matrix'),
    });
    final List<RouteCheck> checks = _checks(
      plan,
      road: <String, RouteRoadState>{
        'd1': RouteRoadState.failed,
        'd2': RouteRoadState.updating,
      },
    );
    expect(_messages(checks), <String>[
      'Distances on Monday and Tuesday are straight-line estimates.',
    ]);
    expect(checks.single.kind, RouteCheckKind.roadEstimate);
    expect(checks.single.dayIndex, 0);
  });

  test('three estimate days read as a list', () {
    final RoutePlan plan = _plan(<int, RouteDay>{
      0: _day(0, <RouteStop>[_stop('a')], estimateSource: ''),
      2: _day(2, <RouteStop>[_stop('b')], estimateSource: ''),
      5: _day(5, <RouteStop>[_stop('c')], estimateSource: ''),
    });
    expect(_messages(_checks(plan)), <String>[
      'Distances on Monday, Wednesday and Saturday are straight-line estimates.',
    ]);
  });

  test('one stop with no start point needs no road, so it is no estimate', () {
    final RoutePlan plan = _plan(<int, RouteDay>{
      0: _day(0, <RouteStop>[_stop('a')], estimateSource: ''),
    }, start: null);
    expect(_checks(plan), isEmpty);
  });

  test('lines come day by day, then follow-ups, then distances', () {
    final RoutePlan plan = _plan(
      <int, RouteDay>{
        0: _day(0, <RouteStop>[
          _stop('a'),
          _stop('b'),
          _stop('c', reason: kPlacedWithNearestShops),
          _stop('d', departure: '18:30'),
        ], estimateSource: ''),
        1: _day(1, <RouteStop>[_stop('e')]),
      },
      followUps: const <RouteFollowUpNotPlaced>[
        RouteFollowUpNotPlaced(
          retailerId: 'f1',
          retailerName: 'Farley Matang',
          followUpDate: '2026-11-24',
        ),
      ],
    );
    final List<RouteCheck> checks = _checks(
      plan,
      statuses: <String, CoordinateStatus>{'e': CoordinateStatus.missing},
    );
    expect(checks.map((RouteCheck c) => c.kind), <RouteCheckKind>[
      RouteCheckKind.overLimit,
      RouteCheckKind.lateReturn,
      RouteCheckKind.placedWithNearest,
      RouteCheckKind.noLocation,
      RouteCheckKind.followUpNotPlaced,
      RouteCheckKind.roadEstimate,
    ]);
    expect(checks.map((RouteCheck c) => c.dayIndex), <int?>[0, 0, 0, 1, 1, 0]);
  });
}
