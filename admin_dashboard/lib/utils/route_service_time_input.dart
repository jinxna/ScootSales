library;

import 'package:latlong2/latlong.dart';

import '../models/route_plan.dart';
import 'route_execution.dart';
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

RouteDay recomputeRouteDay(
  RouteDay day, {
  int serviceMinutes = 20,
  int workdayStartHour = 9,
  Map<String, ServiceTimeStat> learnedServiceTimes =
      const <String, ServiceTimeStat>{},
}) {
  int clock = workdayStartHour * 60;
  double totalKm = 0;
  int totalServiceMinutes = 0;
  final List<RouteStop> stops = <RouteStop>[];
  LatLng? prev;
  for (int i = 0; i < day.stops.length; i++) {
    final RouteStop s = day.stops[i];
    final LatLng pos = LatLng(s.lat, s.lng);
    final double legKm = prev == null ? 0 : _haversineKm(prev, pos);
    totalKm += legKm;
    final int travelMin = estimateRouteTravelMinutes(
      legKm,
      speedKmh: kRecomputeFallbackSpeedKmh,
    );
    clock += travelMin;
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
        legDistanceKm: double.parse(legKm.toStringAsFixed(2)),
        travelMinutesFromPrevious: travelMin,
      ),
    );
    prev = pos;
  }
  return RouteDay(
    dayId: day.dayId,
    dayLabel: day.dayLabel,
    date: day.date,
    stops: stops,
    totalDistanceKm: double.parse(totalKm.toStringAsFixed(2)),
    estimatedServiceMinutes: totalServiceMinutes,
    estimateSource: 'haversine_fallback',
  );
}
