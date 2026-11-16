import 'dart:math' as math;

const double kArrivalMaxDistanceMeters = 74.5;

class NearbyStop {
  const NearbyStop({
    required this.stopId,
    required this.retailerName,
    required this.lat,
    required this.lng,
    this.coordinatesVerified = false,
    this.isPending = false,
  });

  final String stopId;
  final String retailerName;
  final double lat;
  final double lng;
  final bool coordinatesVerified;
  final bool isPending;
}

class NearbyHint {
  const NearbyHint({
    required this.stopId,
    required this.retailerName,
    required this.distanceMeters,
  });

  final String stopId;
  final String retailerName;
  final double distanceMeters;

  int get roundedMeters => (distanceMeters / 10).round() * 10;
}

NearbyHint? selectedStopWithinRadius({
  required String selectedStopId,
  required NearbyStop? stop,
  required double currentLat,
  required double currentLng,
  required bool currentFixReliable,
}) {
  if (stop == null ||
      selectedStopId.isEmpty ||
      stop.stopId != selectedStopId ||
      !stop.isPending ||
      !stop.coordinatesVerified ||
      !currentFixReliable ||
      !_validCoord(currentLat, currentLng) ||
      !_validCoord(stop.lat, stop.lng)) {
    return null;
  }
  final double distance = haversineMeters(
    currentLat,
    currentLng,
    stop.lat,
    stop.lng,
  );
  if (distance > kArrivalMaxDistanceMeters) return null;
  return NearbyHint(
    stopId: stop.stopId,
    retailerName: stop.retailerName,
    distanceMeters: distance,
  );
}

double? distanceToStopMeters({
  required double currentLat,
  required double currentLng,
  required double stopLat,
  required double stopLng,
}) {
  if (!_validCoord(currentLat, currentLng) || !_validCoord(stopLat, stopLng)) {
    return null;
  }
  return haversineMeters(currentLat, currentLng, stopLat, stopLng);
}

double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const double earthRadiusMeters = 6371000;
  final double dLat = _toRadians(lat2 - lat1);
  final double dLng = _toRadians(lng2 - lng1);
  final double a =
      (math.sin(dLat / 2) * math.sin(dLat / 2) +
              math.cos(_toRadians(lat1)) *
                  math.cos(_toRadians(lat2)) *
                  math.sin(dLng / 2) *
                  math.sin(dLng / 2))
          .clamp(0, 1)
          .toDouble();
  return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

bool _validCoord(double lat, double lng) =>
    lat.isFinite &&
    lng.isFinite &&
    lat.abs() <= 90 &&
    lng.abs() <= 180 &&
    !(lat == 0 && lng == 0);

double _toRadians(double degrees) => degrees * math.pi / 180;
