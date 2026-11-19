library;

import 'package:latlong2/latlong.dart';

import '../models/route_plan.dart';
import 'route_execution.dart';
import 'route_stop_order.dart';
import 'route_travel_time.dart';

const double kRecomputeFallbackSpeedKmh = kRouteFallbackSpeedKmh;

const Distance _recomputeDistance = DistanceHaversine(roundResult: false);

double _haversineKm(LatLng a, LatLng b) =>
    _recomputeDistance.as(LengthUnit.Kilometer, a, b);

String _hhmm(int minutesOfDay) {
  final int m = minutesOfDay % (24 * 60);
  final int h = m ~/ 60;
  final int min = m % 60;
  return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
}

int effectiveServiceMinutes({
  required int defaultServiceMinutes,
  ServiceTimeStat? stat,
}) {
  if (stat != null &&
      stat.hasEstimate &&
      stat.confidence >= confidenceHighFloor) {
    final int rounded = stat.meanServiceMinutes!.round();
    return rounded < 1 ? 1 : rounded;
  }
  return defaultServiceMinutes < 1 ? 1 : defaultServiceMinutes;
}

Map<String, int> buildServiceMinutesByRetailer({
  required Iterable<String> retailerIds,
  required int defaultServiceMinutes,
  required Map<String, ServiceTimeStat> learnedServiceTimes,
}) {
  final Map<String, int> result = <String, int>{};
  for (final String rawId in retailerIds) {
    final String id = rawId.trim();
    if (id.isEmpty || result.containsKey(id)) continue;
    result[id] = effectiveServiceMinutes(
      defaultServiceMinutes: defaultServiceMinutes,
      stat: learnedServiceTimes[id],
    );
  }
  return result;
}

({double km, int minutes}) routeLegBetween({
  required String? fromStopId,
  required LatLng from,
  required String? toStopId,
  required LatLng to,
  RouteLegTable? legTable,
}) {
  if (legTable != null) {
    return (
      km: legTable.metersBetween(fromStopId, toStopId) / 1000,
      minutes: (legTable.secondsBetween(fromStopId, toStopId) / 60).round(),
    );
  }
  final double km = _haversineKm(from, to);
  return (
    km: km,
    minutes: estimateRouteTravelMinutes(
      km,
      speedKmh: kRecomputeFallbackSpeedKmh,
    ),
  );
}

RouteLegTable? routeLegTableFor(
  RouteDay day, {
  required RouteStartPoint? start,
  required RouteLegTable? legTable,
}) {
  if (legTable == null) return null;
  final bool usable = legTable.covers(
    day.stops.map((RouteStop stop) => stop.retailerId),
    withStart: start != null,
  );
  return usable ? legTable : null;
}

RouteOrderResult shortestRouteDayOrder(
  RouteDay day, {
  required RouteStartPoint? start,
  required RouteLegTable? legTable,
}) {
  final RouteLegTable? table = routeLegTableFor(
    day,
    start: start,
    legTable: legTable,
  );
  final LatLng? startPosition = start == null
      ? null
      : LatLng(start.lat, start.lng);
  String? idOf(int node) =>
      node == kRouteStartNode ? null : day.stops[node].retailerId;
  LatLng positionOf(int node) => node == kRouteStartNode
      ? startPosition!
      : LatLng(day.stops[node].lat, day.stops[node].lng);
  return bestStopOrder(
    stopCount: day.stops.length,
    hasStart: start != null,
    cost: (int from, int to) => table != null
        ? table.secondsBetween(idOf(from), idOf(to))
        : _haversineKm(positionOf(from), positionOf(to)),
  );
}

int routeDayTravelMinutes(
  List<RouteStop> stops, {
  required RouteStartPoint? start,
  required RouteLegTable? legTable,
}) {
  int total = 0;
  String? previousId;
  LatLng? previous = start == null ? null : LatLng(start.lat, start.lng);
  for (final RouteStop stop in stops) {
    final LatLng position = LatLng(stop.lat, stop.lng);
    if (previous != null) {
      total += routeLegBetween(
        fromStopId: previousId,
        from: previous,
        toStopId: stop.retailerId,
        to: position,
        legTable: legTable,
      ).minutes;
    }
    previousId = stop.retailerId;
    previous = position;
  }
  if (start != null && stops.isNotEmpty) {
    total += routeLegBetween(
      fromStopId: previousId,
      from: previous!,
      toStopId: null,
      to: LatLng(start.lat, start.lng),
      legTable: legTable,
    ).minutes;
  }
  return total;
}

RouteDay recomputeRouteDay(
  RouteDay day, {
  int serviceMinutes = 20,
  int workdayStartHour = 9,
  Map<String, ServiceTimeStat> learnedServiceTimes =
      const <String, ServiceTimeStat>{},
  RouteStartPoint? start,
  RouteLegTable? legTable,
  String orderMethod = kRouteOrderManual,
}) {
  final RouteLegTable? table = routeLegTableFor(
    day,
    start: start,
    legTable: legTable,
  );
  int clock = workdayStartHour * 60;
  double totalKm = 0;
  int totalServiceMinutes = 0;
  final List<RouteStop> stops = <RouteStop>[];
  String? previousId;
  LatLng? previous = start == null ? null : LatLng(start.lat, start.lng);
  for (int i = 0; i < day.stops.length; i++) {
    final RouteStop s = day.stops[i];
    final LatLng pos = LatLng(s.lat, s.lng);
    final ({double km, int minutes}) leg = previous == null
        ? (km: 0, minutes: 0)
        : routeLegBetween(
            fromStopId: previousId,
            from: previous,
            toStopId: s.retailerId,
            to: pos,
            legTable: table,
          );
    totalKm += leg.km;
    clock += leg.minutes;
    final String arrival = _hhmm(clock);
    final int stopServiceMinutes = effectiveServiceMinutes(
      defaultServiceMinutes: serviceMinutes,
      stat: learnedServiceTimes[s.retailerId],
    );
    clock += stopServiceMinutes;
    totalServiceMinutes += stopServiceMinutes;
    final String departure = _hhmm(clock);
    stops.add(
      s.copyWith(
        sequence: i + 1,
        arrival: arrival,
        departure: departure,
        legDistanceKm: double.parse(leg.km.toStringAsFixed(2)),
        travelMinutesFromPrevious: leg.minutes,
      ),
    );
    previousId = s.retailerId;
    previous = pos;
  }
  final ({double km, int minutes}) back = start == null || stops.isEmpty
      ? (km: 0, minutes: 0)
      : routeLegBetween(
          fromStopId: previousId,
          from: previous!,
          toStopId: null,
          to: LatLng(start.lat, start.lng),
          legTable: table,
        );
  totalKm += back.km;
  return RouteDay(
    dayId: day.dayId,
    dayLabel: day.dayLabel,
    date: day.date,
    stops: stops,
    totalDistanceKm: double.parse(totalKm.toStringAsFixed(2)),
    estimatedServiceMinutes: totalServiceMinutes,
    estimateSource: table == null ? 'haversine_fallback' : 'geoapify_matrix',
    orderMethod: stops.isEmpty ? '' : orderMethod,
    returnLegDistanceKm: double.parse(back.km.toStringAsFixed(2)),
    returnTravelMinutes: back.minutes,
  );
}
