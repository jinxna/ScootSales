import '../../../../models/route_plan.dart';
import '../../../../services/route_planning_service.dart';
import '../../../../utils/retailer_readiness.dart';
import '../../../../utils/route_ranking_selection.dart';
import 'route_road_refresh.dart';

const int kRouteDayEndMinutes = 18 * 60;

enum RouteCheckKind {
  overLimit,
  lateReturn,
  placedWithNearest,
  noLocation,
  followUpNotPlaced,
  roadEstimate,
}

class RouteCheck {
  const RouteCheck({
    required this.kind,
    required this.message,
    this.dayIndex,
    this.retailerId,
  });

  final RouteCheckKind kind;
  final String message;
  final int? dayIndex;
  final String? retailerId;
}

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

int routeClockMinutes(String value) {
  final List<String> parts = value.split(':');
  return parts.length < 2
      ? 0
      : (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

int routeDayBackAtMinutes(RouteDay day) =>
    routeClockMinutes(day.stops.last.departure) + day.returnTravelMinutes;

String routeDayBackAtLabel(RouteDay day) {
  final int minutes = routeDayBackAtMinutes(day);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

bool routeDayEndsLate(RouteDay day, {required RouteStartPoint? start}) =>
    start != null &&
    day.stops.isNotEmpty &&
    routeDayBackAtMinutes(day) > kRouteDayEndMinutes;

bool routeDayIsEstimate(
  RouteDay day, {
  required RouteStartPoint? start,
  required RouteRoadState state,
}) =>
    state != RouteRoadState.updating &&
    routeDayNeedsRoad(day, start: start) &&
    !routeDayHasRoadMetrics(day);

String _joinNames(List<String> names) => names.length < 2
    ? names.join()
    : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

List<RouteCheck> routePlanChecks(
  RoutePlan plan, {
  required int maxPerDay,
  required CoordinateStatus? Function(RouteStop stop) coordinateStatusFor,
  required RouteRoadState Function(String dayId) roadStateFor,
}) {
  final List<RouteCheck> checks = <RouteCheck>[];
  for (int i = 0; i < plan.days.length; i++) {
    final RouteDay day = plan.days[i];
    final String name = day.dayLabel;
    if (maxPerDay > 0 && day.stops.length > maxPerDay) {
      checks.add(
        RouteCheck(
          kind: RouteCheckKind.overLimit,
          message:
              '$name has ${day.stops.length} stops. The most is $maxPerDay.',
          dayIndex: i,
        ),
      );
    }
    if (routeDayEndsLate(day, start: plan.startPoint)) {
      checks.add(
        RouteCheck(
          kind: RouteCheckKind.lateReturn,
          message: '$name ends at ${routeDayBackAtLabel(day)}, after 18:00.',
          dayIndex: i,
        ),
      );
    }
    for (final RouteStop stop in day.stops) {
      if (stop.reason.contains(kPlacedWithNearestShops)) {
        checks.add(
          RouteCheck(
            kind: RouteCheckKind.placedWithNearest,
            message:
                '${stop.retailerName} was put on $name with the nearest shops. '
                'Check that the day suits it.',
            dayIndex: i,
            retailerId: stop.retailerId,
          ),
        );
      }
      final CoordinateStatus? status = coordinateStatusFor(stop);
      if (status == CoordinateStatus.missing ||
          status == CoordinateStatus.invalid) {
        checks.add(
          RouteCheck(
            kind: RouteCheckKind.noLocation,
            message:
                '${stop.retailerName} on $name has no usable map location.',
            dayIndex: i,
            retailerId: stop.retailerId,
          ),
        );
      }
    }
  }
  for (final RouteFollowUpNotPlaced row in plan.followUpsNotPlaced) {
    if (row.choice.isNotEmpty) continue;
    final DateTime? date = routeDateFromKey(row.followUpDate);
    final int day = date == null
        ? -1
        : plan.days.indexWhere(
            (RouteDay d) => routeDateKey(d.date) == routeDateKey(date),
          );
    checks.add(
      RouteCheck(
        kind: RouteCheckKind.followUpNotPlaced,
        message:
            'The follow-up visit to ${row.retailerName} on '
            '${date == null ? row.followUpDate : '${date.day} ${_months[date.month - 1]}'} '
            'is not on the route.',
        dayIndex: day < 0 ? null : day,
        retailerId: row.retailerId,
      ),
    );
  }
  final List<int> estimateDays = <int>[
    for (int i = 0; i < plan.days.length; i++)
      if (routeDayIsEstimate(
        plan.days[i],
        start: plan.startPoint,
        state: roadStateFor(plan.days[i].dayId),
      ))
        i,
  ];
  if (estimateDays.isNotEmpty) {
    checks.add(
      RouteCheck(
        kind: RouteCheckKind.roadEstimate,
        message:
            'Distances on '
            '${_joinNames(<String>[for (final int i in estimateDays) plan.days[i].dayLabel])} '
            'are straight-line estimates.',
        dayIndex: estimateDays.first,
      ),
    );
  }
  return checks;
}
