import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'geoapify_config.dart';

class GeoapifyRouteMatrixClient {
  static const int maxMatrixCells = 1000;

  GeoapifyRouteMatrixClient({
    String apiKey = GeoapifyConfig.apiKey,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 4),
    http.Client? client,
  }) : _apiKey = apiKey.trim(),
       _endpoint = endpoint ?? Uri.https('api.geoapify.com', '/v1/routematrix'),
       _client = client;

  final String _apiKey;
  final Uri _endpoint;
  final Duration timeout;
  final http.Client? _client;

  bool get isConfigured => _apiKey.isNotEmpty;

  Future<GeoapifyRouteMatrixResult> matrix(List<LatLng> coordinates) async {
    if (!isConfigured) {
      throw const GeoapifyRouteMatrixException('Geoapify is not configured.');
    }
    if (coordinates.isEmpty ||
        coordinates.length * coordinates.length > maxMatrixCells) {
      throw const GeoapifyRouteMatrixException(
        'Geoapify route matrix exceeds the supported cell limit.',
      );
    }
    for (final LatLng point in coordinates) {
      if (!point.latitude.isFinite ||
          !point.longitude.isFinite ||
          point.latitude < -90 ||
          point.latitude > 90 ||
          point.longitude < -180 ||
          point.longitude > 180) {
        throw const GeoapifyRouteMatrixException(
          'Geoapify route matrix coordinate is out of range.',
        );
      }
    }

    final Uri uri = _endpoint.replace(
      queryParameters: <String, String>{
        ..._endpoint.queryParameters,
        'apiKey': _apiKey,
      },
    );
    final List<Map<String, Object>> waypoints = coordinates
        .map(
          (LatLng point) => <String, Object>{
            'location': <double>[point.longitude, point.latitude],
          },
        )
        .toList(growable: false);
    final bool ownsClient = _client == null;
    final http.Client client = _client ?? http.Client();
    try {
      final http.Response response = await client
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, Object>{
              'mode': 'drive',
              'units': 'metric',
              'sources': waypoints,
              'targets': waypoints,
            }),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GeoapifyRouteMatrixException(
          'Geoapify route matrix request failed with HTTP ${response.statusCode}.',
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        throw const GeoapifyRouteMatrixException(
          'Geoapify route matrix response was not valid JSON.',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const GeoapifyRouteMatrixException(
          'Geoapify route matrix response was malformed.',
        );
      }
      return _parseMatrix(decoded['sources_to_targets'], coordinates.length);
    } on GeoapifyRouteMatrixException {
      rethrow;
    } catch (error) {
      throw GeoapifyRouteMatrixException(
        'Geoapify route matrix request failed: ${error.runtimeType}.',
      );
    } finally {
      if (ownsClient) client.close();
    }
  }
}

class GeoapifyRouteMatrixResult {
  const GeoapifyRouteMatrixResult({
    required this.durationsSeconds,
    required this.distancesMeters,
  });

  final List<List<double>> durationsSeconds;
  final List<List<double>> distancesMeters;
}

class GeoapifyRouteMatrixException implements Exception {
  const GeoapifyRouteMatrixException(this.message);

  final String message;

  @override
  String toString() => 'GeoapifyRouteMatrixException: $message';
}

GeoapifyRouteMatrixResult _parseMatrix(Object? value, int size) {
  if (value is! List || value.length != size) {
    throw const GeoapifyRouteMatrixException(
      'Geoapify route matrix is missing or misshapen.',
    );
  }
  final List<List<double>> durations = <List<double>>[];
  final List<List<double>> distances = <List<double>>[];
  for (int sourceIndex = 0; sourceIndex < size; sourceIndex++) {
    final Object? rawRow = value[sourceIndex];
    if (rawRow is! List || rawRow.length != size) {
      throw const GeoapifyRouteMatrixException(
        'Geoapify route matrix is missing or misshapen.',
      );
    }
    final List<double> durationRow = <double>[];
    final List<double> distanceRow = <double>[];
    for (int targetIndex = 0; targetIndex < size; targetIndex++) {
      final Object? rawCell = rawRow[targetIndex];
      if (rawCell is! Map<String, dynamic> ||
          rawCell['source_index'] != sourceIndex ||
          rawCell['target_index'] != targetIndex) {
        throw const GeoapifyRouteMatrixException(
          'Geoapify route matrix cell identity is invalid.',
        );
      }
      final Object? rawTime = rawCell['time'];
      final Object? rawDistance = rawCell['distance'];
      if (rawTime is! num || rawDistance is! num) {
        throw const GeoapifyRouteMatrixException(
          'Geoapify route matrix contains an unreachable or invalid route.',
        );
      }
      final double time = rawTime.toDouble();
      final double distance = rawDistance.toDouble();
      if (!time.isFinite || time < 0 || !distance.isFinite || distance < 0) {
        throw const GeoapifyRouteMatrixException(
          'Geoapify route matrix contains an invalid value.',
        );
      }
      durationRow.add(time);
      distanceRow.add(distance);
    }
    durations.add(List<double>.unmodifiable(durationRow));
    distances.add(List<double>.unmodifiable(distanceRow));
  }
  return GeoapifyRouteMatrixResult(
    durationsSeconds: List<List<double>>.unmodifiable(durations),
    distancesMeters: List<List<double>>.unmodifiable(distances),
  );
}
