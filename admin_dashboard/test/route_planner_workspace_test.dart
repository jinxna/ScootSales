import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/route_plan.dart';
import 'package:flutter_web_app/pages/admin/views/route_planner/route_plan_workspace.dart';
import 'package:flutter_web_app/pages/admin/views/route_planner/route_road_refresh.dart';
import 'package:flutter_web_app/services/geoapify_routing_client.dart';
import 'package:flutter_web_app/services/route_planning_service.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/utils/route_stop_order.dart';
import 'package:latlong2/latlong.dart';

const RouteStartPoint _start = RouteStartPoint(
  name: 'Swinburne Sarawak',
  lat: 1.5320,
  lng: 110.3570,
);

class _FakeRoads extends GeoapifyRoutingClient {
  _FakeRoads() : super(apiKey: 'test-key');

  final List<List<LatLng>> calls = <List<LatLng>>[];
  final List<Completer<GeoapifyRouteResult>> held =
      <Completer<GeoapifyRouteResult>>[];
  bool hold = false;
  bool fail = false;

  static GeoapifyRouteResult _road(List<LatLng> waypoints) =>
      GeoapifyRouteResult(<GeoapifyRouteLeg>[
        for (int i = 1; i < waypoints.length; i++)
          GeoapifyRouteLeg(
            points: <LatLng>[waypoints[i - 1], waypoints[i]],
            meters: 5000,
            seconds: 600,
          ),
      ]);

  @override
  Future<GeoapifyRouteResult> route(List<LatLng> waypoints) {
    calls.add(waypoints);
    if (fail) {
      return Future<GeoapifyRouteResult>.error(
        const GeoapifyRoutingException('The road service is down.'),
      );
    }
    if (!hold) return Future<GeoapifyRouteResult>.value(_road(waypoints));
    final Completer<GeoapifyRouteResult> completer =
        Completer<GeoapifyRouteResult>();
    held.add(completer);
    return completer.future.then((_) => _road(waypoints));
  }
}

RouteStop _stop(int i) => RouteStop(
  stopId: 'mon_$i',
  dayId: 'mon',
  retailerId: 'shop_$i',
  retailerName: 'Shop $i',
  address: '',
  lat: 1.5400 + i * 0.004,
  lng: 110.3400 + i * 0.003,
  sequence: i + 1,
  arrival: '',
  departure: '',
  legDistanceKm: 0,
  reason: '',
  score: 0,
);

RoutePlan _plan(RouteDay day, {RouteStartPoint? start = _start}) => RoutePlan(
  id: '',
  weekStart: DateTime(2026, 11, 23),
  weekEnd: DateTime(2026, 11, 28),
  status: 'draft',
  branchId: 'b1',
  createdByUid: 'admin',
  salesmanUid: 'u1',
  salesmanName: 'Sam',
  optimisationMethod: 'GeoapifyRouting',
  startPoint: start,
  days: <RouteDay>[
    day,
    for (int d = 1; d < 6; d++)
      RouteDay(
        dayId: 'd$d',
        dayLabel: const <String>[
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
        ][d - 1],
        date: DateTime(2026, 11, 23 + d),
        stops: const <RouteStop>[],
        totalDistanceKm: 0,
      ),
  ],
);

class _Host extends StatefulWidget {
  const _Host({required this.service, required this.plan});

  final RoutePlanningService service;
  final RoutePlan plan;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late RoutePlan plan = widget.plan;
  late final RouteRoadRefresher road = RouteRoadRefresher(
    fetch: (RouteDay day) =>
        widget.service.refreshRoadGeometry(day, start: plan.startPoint),
    currentDay: (String id) =>
        plan.days.where((RouteDay d) => d.dayId == id).firstOrNull,
    onRoad: (RouteDay day) => setState(
      () => plan = plan.copyWith(
        days: <RouteDay>[
          for (final RouteDay d in plan.days) d.dayId == day.dayId ? day : d,
        ],
      ),
    ),
    onFailure: (String dayId, Object error, StackTrace stackTrace) {},
  )..addListener(() => setState(() {}));

  void _edit(List<RouteStop> stops) {
    final RouteDay before = plan.days.first;
    final RouteDay after = widget.service.recomputeDay(
      before.copyWith(stops: stops),
      start: plan.startPoint,
      orderMethod: kRouteOrderManual,
    );
    setState(
      () => plan = plan.copyWith(
        days: <RouteDay>[after, ...plan.days.skip(1)],
      ),
    );
    road.schedule(before);
  }

  @override
  void dispose() {
    road.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: RoutePlanWorkspace(
      plan: plan,
      selectedDay: 0,
      onSelectDay: (_) {},
      editable: true,
      maxPerDay: 6,
      coordinateStatusFor: (_) => null,
      segmentBadgeFor: (_) => null,
      onRemoveStop: (int dayIndex, RouteStop stop) => _edit(<RouteStop>[
        for (final RouteStop s in plan.days.first.stops)
          if (s.retailerId != stop.retailerId) s,
      ]),
      onReorderStop: (int dayIndex, int from, int to) {
        final List<RouteStop> stops = List<RouteStop>.of(plan.days.first.stops);
        stops.insert(to > from ? to - 1 : to, stops.removeAt(from));
        _edit(stops);
      },
      roadStateFor: road.stateOf,
      lastRoadDayFor: road.lastRoadDay,
      onRetryRoad: (int dayIndex) => road.retry(plan.days[dayIndex].dayId),
      onOpenBranches: () {},
      onMoveStop: (int fromDay, RouteStop stop, int toDay) {},
    ),
  );
}

Future<(_FakeRoads, RoutePlanningService, RoutePlan)> _roadPlan(
  int stops, {
  RouteStartPoint? start = _start,
}) async {
  final _FakeRoads roads = _FakeRoads();
  final RoutePlanningService service = RoutePlanningService(
    geoapifyApiKey: '',
    routingClient: roads,
  );
  final RouteDay drafted = await service.refreshRoadGeometry(
    RouteDay(
      dayId: 'mon',
      dayLabel: 'Monday',
      date: DateTime(2026, 11, 23),
      stops: <RouteStop>[for (int i = 0; i < stops; i++) _stop(i)],
      totalDistanceKm: 0,
      orderMethod: kRouteOrderExact,
    ),
    start: start,
  );
  return (roads, service, _plan(drafted, start: start));
}

Future<void> _pump(WidgetTester tester, Widget host) async {
  await tester.binding.setSurfaceSize(const Size(1500, 950));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: DsoTheme.light,
      home: Scaffold(body: host),
    ),
  );
  await tester.pump();
}

String _totals(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey<String>('route_day_totals'))).data!;

Future<void> _remove(WidgetTester tester, String name) async {
  await tester.tap(find.byTooltip('Remove $name'));
  await tester.pump();
}

void main() {
  const Duration debounce = Duration(milliseconds: 600);

  testWidgets(
    'an edit fetches road distances by itself and keeps the last road totals while it waits',
    (WidgetTester tester) async {
      final (_FakeRoads roads, RoutePlanningService service, RoutePlan plan) =
          await _roadPlan(3);
      expect(plan.days.first.totalDistanceKm, 20.0);
      roads.calls.clear();
      roads.hold = true;
      await _pump(tester, _Host(service: service, plan: plan));
      expect(_totals(tester), '20.0 km · 40 min travel');

      await _remove(tester, 'Shop 1');
      expect(
        _totals(tester),
        '20.0 km · 40 min travel · Updating road distances…',
      );
      expect(find.text('Updating road distances…'), findsOneWidget);
      expect(roads.calls, isEmpty);

      await tester.pump(debounce);
      expect(roads.calls, hasLength(1));
      expect(roads.calls.single, <LatLng>[
        const LatLng(1.5320, 110.3570),
        LatLng(_stop(0).lat, _stop(0).lng),
        LatLng(_stop(2).lat, _stop(2).lng),
        const LatLng(1.5320, 110.3570),
      ]);

      roads.held.single.complete(const GeoapifyRouteResult(<GeoapifyRouteLeg>[]));
      await tester.pump();
      await tester.pump();
      expect(_totals(tester), '15.0 km · 30 min travel');
      expect(find.text('Updating road distances…'), findsNothing);
      expect(find.text('Distances are straight-line estimates.'), findsNothing);
      expect(find.text('Refresh road route'), findsNothing);
    },
  );

  testWidgets('two quick edits send one request', (WidgetTester tester) async {
    final (_FakeRoads roads, RoutePlanningService service, RoutePlan plan) =
        await _roadPlan(4);
    roads.calls.clear();
    await _pump(tester, _Host(service: service, plan: plan));

    await _remove(tester, 'Shop 1');
    await tester.pump(const Duration(milliseconds: 300));
    await _remove(tester, 'Shop 2');
    await tester.pump(debounce);
    await tester.pump();

    expect(roads.calls, hasLength(1));
    expect(_totals(tester), '15.0 km · 30 min travel');
  });

  testWidgets('a stale answer is dropped when a later edit is on its way', (
    WidgetTester tester,
  ) async {
    final (_FakeRoads roads, RoutePlanningService service, RoutePlan plan) =
        await _roadPlan(4);
    roads.calls.clear();
    roads.hold = true;
    await _pump(tester, _Host(service: service, plan: plan));

    await _remove(tester, 'Shop 1');
    await tester.pump(debounce);
    await _remove(tester, 'Shop 2');
    await tester.pump(debounce);
    expect(roads.calls, hasLength(2));

    roads.held.first.complete(const GeoapifyRouteResult(<GeoapifyRouteLeg>[]));
    await tester.pump();
    await tester.pump();
    expect(
      _totals(tester),
      '25.0 km · 50 min travel · Updating road distances…',
    );

    roads.held.last.complete(const GeoapifyRouteResult(<GeoapifyRouteLeg>[]));
    await tester.pump();
    await tester.pump();
    expect(_totals(tester), '15.0 km · 30 min travel');
  });

  testWidgets(
    'a road failure shows one straight-line line with Try again, and Try again fetches road distances',
    (WidgetTester tester) async {
      final (_FakeRoads roads, RoutePlanningService service, RoutePlan plan) =
          await _roadPlan(3);
      roads.calls.clear();
      roads.fail = true;
      await _pump(tester, _Host(service: service, plan: plan));

      await _remove(tester, 'Shop 1');
      await tester.pump(debounce);
      await tester.pump();
      expect(find.text('Distances are straight-line estimates.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(_totals(tester), isNot(contains('15.0 km')));

      roads.fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(roads.calls, hasLength(2));
      expect(find.text('Distances are straight-line estimates.'), findsNothing);
      expect(_totals(tester), '15.0 km · 30 min travel');
    },
  );

  test('legs already fetched are reused without a new request', () async {
    final (_FakeRoads roads, RoutePlanningService service, RoutePlan plan) =
        await _roadPlan(3);
    expect(roads.calls, hasLength(1));
    final RouteDay day = plan.days.first;
    final RouteDay swapped = day.copyWith(
      stops: <RouteStop>[day.stops[1], day.stops[0], day.stops[2]],
    );

    await service.refreshRoadGeometry(swapped, start: _start);
    expect(roads.calls, hasLength(2));
    final RouteDay back = await service.refreshRoadGeometry(day, start: _start);
    expect(roads.calls, hasLength(2));
    expect(back.totalDistanceKm, 20.0);
  });

  test(
    'a day emptied while its road request runs is settled, and a save does not wait for that request',
    () async {
      RouteDay current = RouteDay(
        dayId: 'mon',
        dayLabel: 'Monday',
        date: DateTime(2026, 11, 23),
        stops: <RouteStop>[_stop(0)],
        totalDistanceKm: 0,
      );
      final Completer<RouteDay> held = Completer<RouteDay>();
      final RouteRoadRefresher road = RouteRoadRefresher(
        fetch: (RouteDay day) => held.future,
        currentDay: (String id) => current,
        onRoad: (RouteDay day) {},
        onFailure: (String dayId, Object error, StackTrace stackTrace) {},
        delay: Duration.zero,
      );
      addTearDown(road.dispose);

      road.schedule(current);
      await Future<void>.delayed(Duration.zero);
      expect(road.stateOf('mon'), RouteRoadState.updating);

      current = current.copyWith(stops: const <RouteStop>[]);
      road.schedule(current);
      await Future<void>.delayed(Duration.zero);
      expect(road.stateOf('mon'), RouteRoadState.settled);
      expect(road.busy, isFalse);
      await road.flush().timeout(const Duration(seconds: 1));

      held.complete(current);
      await Future<void>.delayed(Duration.zero);
      expect(road.stateOf('mon'), RouteRoadState.settled);
    },
  );

  testWidgets(
    'the start is a fixed first row with its departure time and first leg',
    (WidgetTester tester) async {
      final (_, RoutePlanningService service, RoutePlan plan) = await _roadPlan(
        2,
      );
      await _pump(tester, _Host(service: service, plan: plan));

      expect(find.text('Start: Swinburne Sarawak'), findsOneWidget);
      expect(
        find.text(
          'Leaves 09:00 · first leg 5.0 km, 10 min, counted in the day total',
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('route_start_row')),
          matching: find.byType(ReorderableDragStartListener),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('route_start_row')),
          matching: find.byType(IconButton),
        ),
        findsNothing,
      );
      expect(
        find.textContaining('End: back at Swinburne Sarawak'),
        findsOneWidget,
      );
      expect(find.text('No start point. Set a start point in Branches.'),
          findsNothing);
    },
  );

  testWidgets('a branch without a start point says where to set one', (
    WidgetTester tester,
  ) async {
    final (_, RoutePlanningService service, RoutePlan plan) = await _roadPlan(
      2,
      start: null,
    );
    await _pump(tester, _Host(service: service, plan: plan));

    expect(
      find.text('No start point. Set a start point in Branches.'),
      findsOneWidget,
    );
    expect(find.text('Open Branches'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('route_start_row')), findsNothing);
  });

  for (final Size size in const <Size>[
    Size(1366, 768),
    Size(1500, 950),
    Size(390, 844),
  ]) {
    testWidgets(
      'at ${size.width.toInt()} x ${size.height.toInt()} the page scrolls to the last stop and the end row',
      (WidgetTester tester) async {
        final (_, RoutePlanningService service, RoutePlan plan) =
            await _roadPlan(9);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: DsoTheme.light,
            home: Scaffold(
              body: _Host(service: service, plan: plan),
            ),
          ),
        );
        await tester.pump();

        await tester.dragUntilVisible(
          find.textContaining('End: back at Swinburne Sarawak'),
          find.byType(SingleChildScrollView).first,
          const Offset(0, -300),
        );
        expect(find.text('Shop 8'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(find.byType(Scrollable), findsWidgets);
        expect(
          tester
              .widgetList<ReorderableListView>(find.byType(ReorderableListView))
              .single
              .physics,
          isA<NeverScrollableScrollPhysics>(),
        );
      },
    );
  }

  testWidgets('move and remove targets are at least 40 px', (
    WidgetTester tester,
  ) async {
    final (_, RoutePlanningService service, RoutePlan plan) = await _roadPlan(
      2,
    );
    final RoutePlan twoDays = plan.copyWith(
      days: <RouteDay>[...plan.days],
    );
    await _pump(tester, _Host(service: service, plan: twoDays));

    final Size remove = tester.getSize(find.byTooltip('Remove Shop 0'));
    expect(remove.width, greaterThanOrEqualTo(40));
    expect(remove.height, greaterThanOrEqualTo(40));
    final Size move = tester.getSize(
      find.byTooltip('Move Shop 0 to another day'),
    );
    expect(move.width, greaterThanOrEqualTo(40));
    expect(move.height, greaterThanOrEqualTo(40));
  });
}
