import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'geoapify_config.dart';

class GeoapifyRoutingClient {
  static const int maxWaypoints = 25;

  GeoapifyRoutingClient({
    String apiKey = GeoapifyConfig.apiKey,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 6),
    http.Client? client,
  }) : _apiKey = apiKey.trim(),
       _endpoint = endpoint ?? Uri.https('api.geoapify.com', '/v1/routing'),
       _client = client;

  final String _apiKey;
  final Uri _endpoint;
  final Duration timeout;
  final http.Client? _client;

  bool get isConfigured => _apiKey.isNotEmpty;

  Future<GeoapifyRouteResult> route(List<LatLng> waypoints) async {
    if (!isConfigured) {
      throw const GeoapifyRoutingException('Geoapify is not configured.');
    }
    if (waypoints.length < 2) {
      throw const GeoapifyRoutingException(
        'At least two waypoints are required.',
      );
    }
    for (final LatLng p in waypoints) {
      if (!p.latitude.isFinite ||
          !p.longitude.isFinite ||
          p.latitude < -90 ||
          p.latitude > 90 ||
          p.longitude < -180 ||
          p.longitude > 180 ||
          (p.latitude == 0 && p.longitude == 0)) {
        throw const GeoapifyRoutingException(
          'A waypoint coordinate is invalid.',
        );
      }
    }
    final bool ownsClient = _client == null;
    final http.Client client = _client ?? http.Client();
    try {
      final List<GeoapifyRouteLeg> legs = <GeoapifyRouteLeg>[];
      for (int start = 0; start < waypoints.length - 1;) {
        final int end = math.min(start + maxWaypoints, waypoints.length) - 1;
        legs.addAll(await _fetch(client, waypoints.sublist(start, end + 1)));
        start = end;
      }
      return GeoapifyRouteResult(legs);
    } on GeoapifyRoutingException {
      rethrow;
    } catch (error) {
      throw GeoapifyRoutingException(
        'Geoapify routing request failed: ${error.runtimeType}.',
      );
    } finally {
      if (ownsClient) client.close();
    }
  }

  Future<List<GeoapifyRouteLeg>> _fetch(
    http.Client client,
    List<LatLng> waypoints,
  ) async {
    final Uri uri = _endpoint.replace(
      queryParameters: <String, String>{
        ..._endpoint.queryParameters,
        'waypoints': waypoints
            .map((LatLng p) => '${p.latitude},${p.longitude}')
            .join('|'),
        'mode': 'drive',
        'apiKey': _apiKey,
      },
    );
    final http.Response response = await client.get(uri).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GeoapifyRoutingException(
        response.statusCode == 429
            ? 'rate limit reached (HTTP 429)'
            : response.statusCode == 401 || response.statusCode == 403
            ? 'the API key was rejected (HTTP ${response.statusCode})'
            : 'routing request failed (HTTP ${response.statusCode})',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const GeoapifyRoutingException('response was not valid JSON');
    }
    return _parse(decoded, waypoints);
  }
}

class GeoapifyRouteLeg {
  const GeoapifyRouteLeg({
    required this.points,
    required this.meters,
    required this.seconds,
  });

  final List<LatLng> points;
  final double meters;
  final double seconds;
}

class GeoapifyRouteResult {
  const GeoapifyRouteResult(this.legs);

  final List<GeoapifyRouteLeg> legs;

  double get meters =>
      legs.fold(0, (double sum, GeoapifyRouteLeg l) => sum + l.meters);
  double get seconds =>
      legs.fold(0, (double sum, GeoapifyRouteLeg l) => sum + l.seconds);
}

class GeoapifyRoutingException implements Exception {
  const GeoapifyRoutingException(this.message);

  final String message;

  @override
  String toString() => 'GeoapifyRoutingException: $message';
}

const GeoapifyRoutingException _malformed = GeoapifyRoutingException(
  'response was malformed',
);

List<GeoapifyRouteLeg> _parse(Object? decoded, List<LatLng> waypoints) {
  if (decoded is! Map) throw _malformed;
  final Object? features = decoded['features'];
  if (features is! List || features.isEmpty || features.first is! Map) {
    throw _malformed;
  }
  final Map feature = features.first as Map;
  final Object? geometry = feature['geometry'];
  final Object? properties = feature['properties'];
  if (geometry is! Map ||
      geometry['type'] != 'MultiLineString' ||
      properties is! Map) {
    throw _malformed;
  }
  final Object? lines = geometry['coordinates'];
  final Object? rawLegs = properties['legs'];
  final int expected = waypoints.length - 1;
  if (lines is! List ||
      rawLegs is! List ||
      lines.length != expected ||
      rawLegs.length != expected) {
    throw _malformed;
  }
  final List<GeoapifyRouteLeg> legs = <GeoapifyRouteLeg>[];
  for (int i = 0; i < expected; i++) {
    final Object? line = lines[i];
    final Object? leg = rawLegs[i];
    if (line is! List || line.length < 2 || leg is! Map) throw _malformed;
    final Object? distance = leg['distance'];
    final Object? time = leg['time'];
    if (distance is! num ||
        time is! num ||
        !distance.isFinite ||
        !time.isFinite ||
        distance < 0 ||
        time < 0) {
      throw _malformed;
    }
    final List<LatLng> points = <LatLng>[];
    for (final Object? raw in line) {
      if (raw is! List || raw.length < 2 || raw[0] is! num || raw[1] is! num) {
        throw _malformed;
      }
      final double lon = (raw[0] as num).toDouble();
      final double lat = (raw[1] as num).toDouble();
      if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
        throw _malformed;
      }
      points.add(LatLng(lat, lon));
    }
    if (const Distance().as(LengthUnit.Meter, points.first, waypoints[i]) >
        1000) {
      throw const GeoapifyRoutingException(
        'response geometry does not match the waypoints',
      );
    }
    legs.add(
      GeoapifyRouteLeg(
        points: points,
        meters: distance.toDouble(),
        seconds: time.toDouble(),
      ),
    );
  }
  return legs;
}

List<List<double>> simplifyRoadGeometry(
  List<GeoapifyRouteLeg> legs, {
  int maxPoints = 600,
  double toleranceDegrees = 0.00005,
}) {
  if (legs.isEmpty) return const <List<double>>[];
  List<List<LatLng>> simplified = <List<LatLng>>[
    for (final GeoapifyRouteLeg leg in legs)
      _douglasPeucker(leg.points, toleranceDegrees),
  ];
  int total =
      simplified.fold(0, (int s, List<LatLng> l) => s + l.length) -
      (simplified.length - 1);
  if (total > maxPoints) {
    final int perLeg = math.max(2, (maxPoints - 1) ~/ simplified.length + 1);
    simplified = <List<LatLng>>[
      for (final List<LatLng> leg in simplified)
        leg.length <= perLeg
            ? leg
            : <LatLng>[
                for (int i = 0; i < perLeg; i++)
                  leg[(i * (leg.length - 1) / (perLeg - 1)).round()],
              ],
    ];
  }
  final List<List<double>> out = <List<double>>[];
  for (int i = 0; i < simplified.length; i++) {
    for (int j = i == 0 ? 0 : 1; j < simplified[i].length; j++) {
      out.add(<double>[simplified[i][j].latitude, simplified[i][j].longitude]);
    }
  }
  return out;
}

List<LatLng> _douglasPeucker(List<LatLng> pts, double tolerance) {
  if (pts.length < 3) return pts;
  final List<bool> keep = List<bool>.filled(pts.length, false);
  keep[0] = keep[pts.length - 1] = true;
  final List<(int, int)> stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (int a, int b) = stack.removeLast();
    double worst = 0;
    int index = -1;
    for (int i = a + 1; i < b; i++) {
      final double d = _segmentDistance(pts[i], pts[a], pts[b]);
      if (d > worst) {
        worst = d;
        index = i;
      }
    }
    if (index != -1 && worst > tolerance) {
      keep[index] = true;
      stack.add((a, index));
      stack.add((index, b));
    }
  }
  return <LatLng>[
    for (int i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}

double _segmentDistance(LatLng p, LatLng a, LatLng b) {
  final double dx = b.longitude - a.longitude;
  final double dy = b.latitude - a.latitude;
  final double len2 = dx * dx + dy * dy;
  double t = len2 == 0
      ? 0
      : ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
            len2;
  t = t.clamp(0.0, 1.0);
  final double cx = a.longitude + t * dx;
  final double cy = a.latitude + t * dy;
  final double ex = p.longitude - cx;
  final double ey = p.latitude - cy;
  return math.sqrt(ex * ex + ey * ey);
}
