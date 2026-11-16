import 'package:latlong2/latlong.dart';

const List<String> kLatitudeKeys = <String>[
  'latitude',
  'lat',
  'gpsLatitude',
  'gps_latitude',
  'gpsLat',
  'gps_lat',
  'lastLatitude',
  'lastLat',
  'currentLatitude',
  'currentLat',
];
const List<String> kLongitudeKeys = <String>[
  'longitude',
  'lng',
  'lon',
  'gpsLongitude',
  'gps_longitude',
  'gpsLng',
  'gps_lng',
  'lastLongitude',
  'lastLng',
  'currentLongitude',
  'currentLng',
];
const List<String> kNestedCoordinateKeys = <String>[
  'gps',
  'location',
  'coordinates',
  'coordinate',
  'geoPoint',
  'geopoint',
];

LatLng? readLatLng(Map<String, dynamic> row) {
  final LatLng? nested = _firstNestedLatLng(row);
  if (nested != null) return nested;

  final double? lat = _firstCoordinate(row, kLatitudeKeys);
  final double? lng = _firstCoordinate(row, kLongitudeKeys);
  return _validLatLng(lat, lng);
}

bool hasLatLng(Map<String, dynamic> row) => readLatLng(row) != null;

bool hasCoordinateFields(Map<String, dynamic> row) {
  for (final String key in kLatitudeKeys) {
    if (row.containsKey(key)) return true;
  }
  for (final String key in kLongitudeKeys) {
    if (row.containsKey(key)) return true;
  }
  for (final String key in kNestedCoordinateKeys) {
    final Object? value = row[key];
    if (value == null) continue;
    if (value is Map || value is List) return true;
    try {
      final dynamic point = value;
      if (point.latitude is num && point.longitude is num) return true;
    } catch (_) {}
  }
  return false;
}

LatLng? _firstNestedLatLng(Map<String, dynamic> row) {
  for (final String key in kNestedCoordinateKeys) {
    final LatLng? parsed = _latLngFromObject(row[key]);
    if (parsed != null) return parsed;
  }
  return null;
}

LatLng? _latLngFromObject(Object? value) {
  if (value == null) return null;
  if (value is List && value.length >= 2) {
    final double? first = _toDouble(value[0]);
    final double? second = _toDouble(value[1]);
    final LatLng? latLng = _validLatLng(first, second);
    if (latLng != null) return latLng;
    return _validLatLng(second, first);
  }
  if (value is Map) {
    final Map<dynamic, dynamic> map = value;
    final double? lat = _firstCoordinate(map, const <String>[
      'latitude',
      'lat',
      '_latitude',
    ]);
    final double? lng = _firstCoordinate(map, const <String>[
      'longitude',
      'lng',
      'lon',
      '_longitude',
    ]);
    return _validLatLng(lat, lng);
  }

  try {
    final dynamic point = value;
    return _validLatLng(_toDouble(point.latitude), _toDouble(point.longitude));
  } catch (_) {
    return null;
  }
}

double? _firstCoordinate(Map<dynamic, dynamic> row, List<String> keys) {
  double? zero;
  for (final String key in keys) {
    final double? value = _toDouble(row[key]);
    if (value == null) continue;
    if (value != 0) return value;
    zero = value;
  }
  return zero;
}

LatLng? _validLatLng(double? lat, double? lng) {
  if (lat == null || lng == null || (lat == 0 && lng == 0)) return null;
  if (lat.abs() > 90 || lng.abs() > 180) return null;
  return LatLng(lat, lng);
}

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return null;
  if (text.contains(',')) return null;
  final double? parsed = double.tryParse(text);
  return parsed != null && parsed.isFinite ? parsed : null;
}
