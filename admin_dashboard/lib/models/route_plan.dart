import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/route_travel_time.dart';

class RouteStop {
  const RouteStop({
    this.stopId = '',
    this.dayId = '',
    required this.retailerId,
    required this.retailerName,
    required this.address,
    required this.lat,
    required this.lng,
    required this.sequence,
    required this.arrival,
    required this.departure,
    required this.legDistanceKm,
    this.travelMinutesFromPrevious = 0,
    required this.reason,
    required this.score,
    this.status = 'not_started',
    this.retailerCoordinateSnapshot,
  });

  final String stopId;
  final String dayId;
  final String retailerId;
  final String retailerName;
  final String address;
  final double lat;
  final double lng;
  final int sequence;
  final String arrival;
  final String departure;
  final double legDistanceKm;
  final int travelMinutesFromPrevious;
  final String reason;
  final double score;
  final String status;
  final Map<String, dynamic>? retailerCoordinateSnapshot;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'stopId': stopId,
    'dayId': dayId,
    'retailerId': retailerId,
    'retailerName': retailerName,
    'address': address,
    'lat': lat,
    'lng': lng,
    'sequence': sequence,
    'arrival': arrival,
    'departure': departure,
    'estimatedArrival': arrival,
    'estimatedDeparture': departure,
    'legDistanceKm': legDistanceKm,
    'travelMinutesFromPrevious': travelMinutesFromPrevious,
    'reason': reason,
    'priorityReason': reason,
    'score': score,
    'status': status,
    if (retailerCoordinateSnapshot != null)
      'retailerCoordinateSnapshot': retailerCoordinateSnapshot,
  };

  factory RouteStop.fromMap(Map<String, dynamic> map) => RouteStop(
    stopId: _text(map['stopId'] ?? map['stop_id']),
    dayId: _text(map['dayId'] ?? map['day_id']),
    retailerId: _text(map['retailerId']),
    retailerName: _text(map['retailerName'], fallback: 'Retailer'),
    address: _text(map['address']),
    lat: _num(map['lat']),
    lng: _num(map['lng']),
    sequence: _num(map['sequence']).toInt(),
    arrival: _text(map['arrival'] ?? map['estimatedArrival']),
    departure: _text(map['departure'] ?? map['estimatedDeparture']),
    legDistanceKm: _num(map['legDistanceKm']),
    travelMinutesFromPrevious: _travelMinutesFromMap(map),
    reason: _text(map['reason'] ?? map['priorityReason']),
    score: _num(map['score']),
    status: _text(map['status'], fallback: 'not_started'),
    retailerCoordinateSnapshot: map['retailerCoordinateSnapshot'] is Map
        ? Map<String, dynamic>.from(map['retailerCoordinateSnapshot'] as Map)
        : null,
  );

  RouteStop copyWith({
    int? sequence,
    String? arrival,
    String? departure,
    double? legDistanceKm,
    int? travelMinutesFromPrevious,
    Map<String, dynamic>? retailerCoordinateSnapshot,
    bool clearRetailerCoordinateSnapshot = false,
  }) {
    return RouteStop(
      stopId: stopId,
      dayId: dayId,
      retailerId: retailerId,
      retailerName: retailerName,
      address: address,
      lat: lat,
      lng: lng,
      sequence: sequence ?? this.sequence,
      arrival: arrival ?? this.arrival,
      departure: departure ?? this.departure,
      legDistanceKm: legDistanceKm ?? this.legDistanceKm,
      travelMinutesFromPrevious:
          travelMinutesFromPrevious ?? this.travelMinutesFromPrevious,
      reason: reason,
      score: score,
      status: status,
      retailerCoordinateSnapshot: clearRetailerCoordinateSnapshot
          ? null
          : retailerCoordinateSnapshot ?? this.retailerCoordinateSnapshot,
    );
  }
}

int _travelMinutesFromMap(Map<String, dynamic> map) {
  final Object? raw =
      map['travelMinutesFromPrevious'] ?? map['travel_minutes_from_previous'];
  final double? parsed = _optionalNum(raw);
  if (parsed != null && parsed.isFinite && parsed >= 0) {
    return parsed.round();
  }
  return estimateRouteTravelMinutes(_num(map['legDistanceKm']));
}

class RouteDay {
  const RouteDay({
    this.dayId = '',
    required this.dayLabel,
    required this.date,
    required this.stops,
    required this.totalDistanceKm,
    this.estimatedServiceMinutes = 0,
    this.estimateSource = '',
    this.geometry = const <List<double>>[],
    this.geometrySource = '',
  });

  final String dayId;
  final String dayLabel;
  final DateTime date;
  final List<RouteStop> stops;
  final double totalDistanceKm;
  final int estimatedServiceMinutes;
  final String estimateSource;

  final List<List<double>> geometry;
  final String geometrySource;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'dayId': dayId,
    'dayLabel': dayLabel,
    'date': Timestamp.fromDate(date),
    'totalRetailers': stops.length,
    'estimatedServiceMinutes': estimatedServiceMinutes,
    'stops': stops.map((RouteStop s) => s.toMap()).toList(),
    'totalDistanceKm': totalDistanceKm,
    if (estimateSource.isNotEmpty) 'estimateSource': estimateSource,
    'geometry': geometry
        .map((List<double> p) => <String, double>{'lat': p[0], 'lng': p[1]})
        .toList(),
    if (geometrySource.isNotEmpty) 'geometrySource': geometrySource,
  };

  factory RouteDay.fromMap(Map<String, dynamic> map) {
    final Object? rawStops = map['stops'];
    final List<RouteStop> stops = rawStops is List
        ? rawStops
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (Map<dynamic, dynamic> e) =>
                    RouteStop.fromMap(Map<String, dynamic>.from(e)),
              )
              .toList()
        : <RouteStop>[];
    final Object? rawGeom = map['geometry'];
    final List<List<double>> geometry = rawGeom is List
        ? rawGeom
              .map((dynamic p) {
                if (p is Map) {
                  return <double>[_num(p['lat']), _num(p['lng'])];
                }
                if (p is List && p.length >= 2) {
                  return <double>[_num(p[0]), _num(p[1])];
                }
                return const <double>[];
              })
              .where((List<double> p) => p.length >= 2)
              .toList()
        : <List<double>>[];
    return RouteDay(
      dayId: _text(map['dayId'] ?? map['day_id']),
      dayLabel: _text(map['dayLabel']),
      date: _date(map['date']) ?? DateTime.now(),
      stops: stops,
      totalDistanceKm: _num(map['totalDistanceKm']),
      estimatedServiceMinutes: _num(map['estimatedServiceMinutes']).toInt(),
      estimateSource: _text(map['estimateSource']),
      geometry: geometry,
      geometrySource: _text(
        map['geometrySource'] ?? map['routeGeometrySource'],
      ),
    );
  }

  RouteDay copyWith({
    List<RouteStop>? stops,
    double? totalDistanceKm,
    String? estimateSource,
    List<List<double>>? geometry,
    String? geometrySource,
  }) {
    return RouteDay(
      dayId: dayId,
      dayLabel: dayLabel,
      date: date,
      stops: stops ?? this.stops,
      totalDistanceKm: totalDistanceKm ?? this.totalDistanceKm,
      estimatedServiceMinutes: estimatedServiceMinutes,
      estimateSource: estimateSource ?? this.estimateSource,
      geometry: geometry ?? this.geometry,
      geometrySource: geometrySource ?? this.geometrySource,
    );
  }
}

bool isProviderRoadGeometry(String source) {
  final String normalized = source.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return normalized == 'osrmroute' || normalized == 'geoapifyroute';
}

class RoutePlan {
  const RoutePlan({
    required this.id,
    required this.weekStart,
    required this.weekEnd,
    required this.status,
    required this.branchId,
    required this.createdByUid,
    required this.salesmanUid,
    required this.salesmanName,
    required this.optimisationMethod,
    required this.days,
    this.source = 'dashboard',
    this.createdByRole = '',
    this.salesmanCode = '',
    this.planVersion = 1,
    this.isDemo = false,
    this.roadRouteNotes = const <String>[],
    this.approvedAt,
    this.publishedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final DateTime weekStart;
  final DateTime weekEnd;

  final String status;
  final String branchId;
  final String createdByUid;
  final String createdByRole;
  final String salesmanUid;
  final String salesmanCode;
  final String salesmanName;
  final String source;
  final int planVersion;
  final bool isDemo;

  final String optimisationMethod;
  final List<RouteDay> days;

  String get metricSourceMethod =>
      metricSourceMethodForDays(days, fallback: optimisationMethod);

  static String metricSourceMethodForDays(
    Iterable<RouteDay> days, {
    required String fallback,
  }) {
    final Set<String> sources = <String>{
      for (final RouteDay day in days)
        if (day.stops.isNotEmpty && day.estimateSource.trim().isNotEmpty)
          day.estimateSource.trim(),
    };
    final bool hasMatrix = sources.contains('geoapify_matrix');
    final bool hasRouting = sources.contains('geoapify_routing');
    final bool hasHaversine = sources.contains('haversine_fallback');

    if (hasMatrix && hasRouting) {
      return hasHaversine
          ? 'GeoapifyRoadMixedHaversineFallback'
          : 'GeoapifyRoadMixedSources';
    }
    if (hasRouting) {
      return hasHaversine
          ? 'GeoapifyRoutingMixedHaversineFallback'
          : 'GeoapifyRouting';
    }
    if (hasMatrix) {
      return hasHaversine
          ? 'GeoapifyRouteMatrixMixedHaversineFallback'
          : 'GeoapifyRouteMatrix';
    }
    return fallback;
  }

  final List<String> roadRouteNotes;
  final DateTime? approvedAt;
  final DateTime? publishedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  int get totalStops =>
      days.fold(0, (int sum, RouteDay d) => sum + d.stops.length);

  List<String> get stopIds => <String>[
    for (final RouteDay day in days)
      for (final RouteStop stop in day.stops)
        if (stop.stopId.trim().isNotEmpty) stop.stopId.trim(),
  ];

  double get totalDistanceKm =>
      days.fold(0.0, (double sum, RouteDay d) => sum + d.totalDistanceKm);

  Map<String, dynamic> toMap() => <String, dynamic>{
    if (id.isNotEmpty) 'planId': id,
    'weekStart': Timestamp.fromDate(weekStart),
    'weekEnd': Timestamp.fromDate(weekEnd),
    'status': status,
    'source': source,
    'branchId': branchId,
    'createdByUid': createdByUid,
    'createdByRole': createdByRole,
    'salesmanUid': salesmanUid,
    'salesmanCode': salesmanCode,
    'salesmanName': salesmanName,
    'planVersion': planVersion,
    'isDemo': isDemo,
    'optimisationMethod': metricSourceMethod,
    'days': days.map((RouteDay d) => d.toMap()).toList(),
    'totalStops': totalStops,
    'stopIds': stopIds,
    'stopRetailerIds': <String, String>{
      for (final RouteDay day in days)
        for (final RouteStop stop in day.stops)
          if (stop.stopId.trim().isNotEmpty &&
              stop.retailerId.trim().isNotEmpty)
            stop.stopId.trim(): stop.retailerId.trim(),
    },
    'stopCoordinateSnapshots': <String, Map<String, dynamic>>{
      for (final RouteDay day in days)
        for (final RouteStop stop in day.stops)
          if (stop.stopId.trim().isNotEmpty &&
              stop.retailerCoordinateSnapshot != null)
            stop.stopId.trim(): <String, dynamic>{
              ...stop.retailerCoordinateSnapshot!,
              'retailerId': stop.retailerId.trim(),
            },
    },
    'totalDistanceKm': totalDistanceKm,
    if (approvedAt != null) 'approvedAt': Timestamp.fromDate(approvedAt!),
    if (publishedAt != null) 'publishedAt': Timestamp.fromDate(publishedAt!),
  };

  factory RoutePlan.fromMap(String id, Map<String, dynamic> map) {
    final Object? rawDays = map['days'];
    final List<RouteDay> days = rawDays is List
        ? rawDays
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (Map<dynamic, dynamic> e) =>
                    RouteDay.fromMap(Map<String, dynamic>.from(e)),
              )
              .toList()
        : <RouteDay>[];
    final String storedMethod = _text(
      map['optimisationMethod'],
      fallback: 'NearestNeighbour',
    );
    return RoutePlan(
      id: id,
      weekStart: _date(map['weekStart']) ?? DateTime.now(),
      weekEnd: _date(map['weekEnd']) ?? DateTime.now(),
      status: _text(map['status'], fallback: 'draft'),
      source: _text(map['source'], fallback: 'dashboard'),
      branchId: _text(map['branchId']),
      createdByUid: _text(map['createdByUid']),
      createdByRole: _text(map['createdByRole']),
      salesmanUid: _text(map['salesmanUid']),
      salesmanCode: _text(map['salesmanCode'] ?? map['salesman_code']),
      salesmanName: _text(map['salesmanName'], fallback: 'Salesman'),
      planVersion: _num(map['planVersion']).toInt() == 0
          ? 1
          : _num(map['planVersion']).toInt(),
      isDemo: map['isDemo'] == true,
      optimisationMethod: metricSourceMethodForDays(
        days,
        fallback: storedMethod,
      ),
      days: days,
      approvedAt: _date(map['approvedAt']),
      publishedAt: _date(map['publishedAt']),
      createdAt: _date(map['createdAt']),
      updatedAt: _date(map['updatedAt']),
    );
  }

  RoutePlan copyWith({
    String? status,
    List<RouteDay>? days,
    String? optimisationMethod,
  }) {
    final List<RouteDay> nextDays = days ?? this.days;
    return RoutePlan(
      id: id,
      weekStart: weekStart,
      weekEnd: weekEnd,
      status: status ?? this.status,
      branchId: branchId,
      createdByUid: createdByUid,
      createdByRole: createdByRole,
      salesmanUid: salesmanUid,
      salesmanCode: salesmanCode,
      salesmanName: salesmanName,
      source: source,
      planVersion: planVersion,
      isDemo: isDemo,
      optimisationMethod: metricSourceMethodForDays(
        nextDays,
        fallback: optimisationMethod ?? this.optimisationMethod,
      ),
      days: nextDays,
      roadRouteNotes: roadRouteNotes,
      approvedAt: approvedAt,
      publishedAt: publishedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

String _text(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

double _num(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().trim()) ?? 0;
}

double? _optionalNum(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

DateTime? _date(Object? value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is num) {
    final int n = value.toInt();
    return DateTime.fromMillisecondsSinceEpoch(n > 9999999999 ? n : n * 1000);
  }
  return DateTime.tryParse(value.toString().trim());
}
