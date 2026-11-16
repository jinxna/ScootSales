import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/demo_data.dart';

class AssignedRoutePlan {
  AssignedRoutePlan({
    required this.id,
    required this.weekStart,
    required this.weekEnd,
    required this.status,
    required this.source,
    required this.salesmanUid,
    required this.salesmanCode,
    required this.salesmanName,
    required this.branchId,
    required this.isDemo,
    required this.days,
    this.optimisationMethod = '',
    this.publishedAt,
    this.createdByRole = '',
  });

  final String id;
  final DateTime? weekStart;
  final DateTime? weekEnd;
  final String status;
  final String source;
  final String salesmanUid;
  final String salesmanCode;
  final String salesmanName;
  final String branchId;
  final bool isDemo;
  final List<AssignedRouteDay> days;
  final String optimisationMethod;
  final DateTime? publishedAt;
  final String createdByRole;

  List<AssignedRouteStop> get stops =>
      days.expand((AssignedRouteDay day) => day.stops).toList(growable: false);

  factory AssignedRoutePlan.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return AssignedRoutePlan.fromMap(doc.id, doc.data() ?? <String, dynamic>{});
  }

  factory AssignedRoutePlan.fromMap(String id, Map<String, dynamic> data) {
    final rawDays = data['days'];
    final String planId = (data['planId'] ?? id).toString().trim();
    final Map<String, dynamic> identityData = <String, dynamic>{
      ...data,
      'planId': planId,
    };
    final String optimisationMethod = _text(
      data['optimisationMethod'] ?? data['optimizationMethod'],
    );
    return AssignedRoutePlan(
      id: planId,
      weekStart: _toDate(data['weekStart']),
      weekEnd: _toDate(data['weekEnd']),
      status: _text(data['status'], fallback: 'draft'),
      source: _text(data['source'], fallback: 'dashboard'),
      salesmanUid: _text(data['salesmanUid']),
      salesmanCode: _text(data['salesmanCode'] ?? data['salesman_code']),
      salesmanName: _text(data['salesmanName'], fallback: 'Salesman'),
      branchId: _text(data['branchId'] ?? data['branch_id']),
      isDemo: isDemoRecord(identityData),
      optimisationMethod: optimisationMethod,
      publishedAt: _toDate(data['publishedAt']),
      createdByRole: _text(data['createdByRole']),
      days: rawDays is List
          ? rawDays
                .whereType<Map<dynamic, dynamic>>()
                .map(
                  (item) =>
                      AssignedRouteDay.fromMap(
                        Map<String, dynamic>.from(item),
                        fallbackEstimateSource: optimisationMethod,
                      ),
                )
                .toList()
          : <AssignedRouteDay>[],
    );
  }

  Map<String, dynamic> toCacheMap() => <String, dynamic>{
    'planId': id,
    if (weekStart != null) 'weekStart': weekStart!.toIso8601String(),
    if (weekEnd != null) 'weekEnd': weekEnd!.toIso8601String(),
    'status': status,
    'source': source,
    'salesmanUid': salesmanUid,
    'salesmanCode': salesmanCode,
    'salesmanName': salesmanName,
    'branchId': branchId,
    'isDemo': isDemo,
    if (optimisationMethod.isNotEmpty)
      'optimisationMethod': optimisationMethod,
    if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
    if (createdByRole.isNotEmpty) 'createdByRole': createdByRole,
    'days': days.map((AssignedRouteDay day) => day.toCacheMap()).toList(),
  };

  AssignedRouteDay? dayFor(DateTime date) {
    final wanted = DateTime(date.year, date.month, date.day);
    for (final day in days) {
      final dayDate = day.date;
      if (dayDate == null) continue;
      if (DateTime(dayDate.year, dayDate.month, dayDate.day) == wanted) {
        return day;
      }
    }
    return null;
  }

  String get sourceLabel {
    final lower = source.toLowerCase();
    if (lower.contains('supervisor')) return 'Assigned by Supervisor';
    if (lower.contains('mobile')) return 'Personal Plan';
    return switch (createdByRole.toLowerCase()) {
      'supervisor' => 'Assigned by Supervisor',
      'admin' => 'Assigned by Admin',
      'branch_manager' => 'Assigned by Branch Manager',
      _ => 'Assigned route',
    };
  }
}

class AssignedRouteDay {
  AssignedRouteDay({
    required this.dayId,
    required this.dayLabel,
    required this.date,
    required this.stops,
    required this.totalDistanceKm,
    this.geometry = const <List<double>>[],
    this.estimateSource = '',
    this.geometrySource = '',
  });

  final String dayId;
  final String dayLabel;
  final DateTime? date;
  final List<AssignedRouteStop> stops;
  final double totalDistanceKm;
  final List<List<double>> geometry;
  final String estimateSource;
  final String geometrySource;

  factory AssignedRouteDay.fromMap(
    Map<String, dynamic> data, {
    String fallbackEstimateSource = '',
  }) {
    final rawStops = data['stops'];
    return AssignedRouteDay(
      dayId: _text(data['dayId'] ?? data['day_id']),
      dayLabel: _text(data['dayLabel'], fallback: 'Day'),
      date: _toDate(data['date']),
      totalDistanceKm: _number(data['totalDistanceKm']),
      geometry: _parseRoadGeometry(data['geometry']),
      estimateSource: _text(
        data['estimateSource'],
        fallback: fallbackEstimateSource,
      ),
      geometrySource: _text(
        data['geometrySource'] ?? data['routeGeometrySource'],
      ),
      stops: rawStops is List
          ? rawStops
                .whereType<Map<dynamic, dynamic>>()
                .map((item) => Map<String, dynamic>.from(item))
                .where(
                  (Map<String, dynamic> stop) =>
                      !isDemoRecord(stop, includeNameMarkers: false),
                )
                .map(AssignedRouteStop.fromMap)
                .toList()
          : <AssignedRouteStop>[],
    );
  }

  Map<String, dynamic> toCacheMap() => <String, dynamic>{
    'dayId': dayId,
    'dayLabel': dayLabel,
    if (date != null) 'date': date!.toIso8601String(),
    'totalDistanceKm': totalDistanceKm,
    'geometry': geometry
        .map(
          (List<double> point) => <String, double>{
            'lat': point[0],
            'lng': point[1],
          },
        )
        .toList(growable: false),
    if (estimateSource.isNotEmpty) 'estimateSource': estimateSource,
    if (geometrySource.isNotEmpty) 'geometrySource': geometrySource,
    'stops': stops.map((AssignedRouteStop stop) => stop.toCacheMap()).toList(),
  };
}

List<List<double>> _parseRoadGeometry(Object? raw) {
  if (raw is! List) return const <List<double>>[];
  final List<List<double>> points = <List<double>>[];
  for (final Object? item in raw) {
    Object? rawLatitude;
    Object? rawLongitude;
    if (item is Map) {
      rawLatitude = item['lat'] ?? item['latitude'];
      rawLongitude = item['lng'] ?? item['longitude'];
    } else if (item is List && item.length >= 2) {
      rawLatitude = item[0];
      rawLongitude = item[1];
    } else {
      return const <List<double>>[];
    }
    final double? latitude = _optionalNumber(rawLatitude);
    final double? longitude = _optionalNumber(rawLongitude);
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        (latitude == 0 && longitude == 0)) {
      return const <List<double>>[];
    }
    points.add(<double>[latitude, longitude]);
  }
  return points.length >= 2 ? points : const <List<double>>[];
}

class AssignedRouteStop {
  AssignedRouteStop({
    required this.stopId,
    required this.dayId,
    required this.retailerId,
    required this.retailerName,
    required this.address,
    required this.lat,
    required this.lng,
    required this.sequence,
    required this.estimatedArrival,
    required this.estimatedDeparture,
    required this.priorityReason,
    required this.status,
    this.travelMinutesFromPrevious = 0,
    this.legDistanceKm = 0,
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
  final String estimatedArrival;
  final String estimatedDeparture;
  final String priorityReason;
  final String status;
  final int travelMinutesFromPrevious;
  final double legDistanceKm;
  final RetailerCoordinateSnapshot? retailerCoordinateSnapshot;

  factory AssignedRouteStop.fromMap(Map<String, dynamic> data) {
    final sequence = _number(data['sequence']).toInt();
    final retailerId = _text(data['retailerId'] ?? data['retailer_id']);
    final dayId = _text(data['dayId'] ?? data['day_id']);
    final generatedStopId =
        '${dayId.isEmpty ? 'day' : dayId}_${sequence}_${retailerId.isEmpty ? 'retailer' : retailerId}';
    final rawStopId = _text(data['stopId'] ?? data['stop_id']);
    final double legDistanceKm = _number(data['legDistanceKm']);
    final Object? rawTravel =
        data['travelMinutesFromPrevious'] ??
        data['travel_minutes_from_previous'];
    final double? parsedTravel = _optionalNumber(rawTravel);
    final int travelMinutesFromPrevious =
        parsedTravel != null && parsedTravel.isFinite && parsedTravel >= 0
        ? parsedTravel.round()
        : _estimateTravelMinutes(legDistanceKm);
    return AssignedRouteStop(
      stopId: (rawStopId.isEmpty ? generatedStopId : rawStopId).trim(),
      dayId: dayId,
      retailerId: retailerId,
      retailerName: _text(data['retailerName'], fallback: 'Retailer'),
      address: _text(data['address']),
      lat: _number(data['lat'] ?? data['latitude']),
      lng: _number(data['lng'] ?? data['longitude']),
      sequence: sequence,
      estimatedArrival: _text(data['estimatedArrival'] ?? data['arrival']),
      estimatedDeparture: _text(
        data['estimatedDeparture'] ?? data['departure'],
      ),
      priorityReason: _text(data['priorityReason'] ?? data['reason']),
      status: _text(data['status'], fallback: 'not_started'),
      travelMinutesFromPrevious: travelMinutesFromPrevious,
      legDistanceKm: legDistanceKm.isFinite && legDistanceKm >= 0
          ? legDistanceKm
          : 0,
      retailerCoordinateSnapshot: RetailerCoordinateSnapshot.tryParse(
        data['retailerCoordinateSnapshot'],
      ),
    );
  }

  Map<String, dynamic> toCacheMap() => <String, dynamic>{
    'stopId': stopId,
    'dayId': dayId,
    'retailerId': retailerId,
    'retailerName': retailerName,
    'address': address,
    'lat': lat,
    'lng': lng,
    'sequence': sequence,
    'estimatedArrival': estimatedArrival,
    'estimatedDeparture': estimatedDeparture,
    'priorityReason': priorityReason,
    'status': status,
    'travelMinutesFromPrevious': travelMinutesFromPrevious,
    'legDistanceKm': legDistanceKm,
    if (retailerCoordinateSnapshot != null)
      'retailerCoordinateSnapshot': retailerCoordinateSnapshot!.toMap(),
  };
}

class RetailerCoordinateSnapshot {
  const RetailerCoordinateSnapshot({
    required this.latitude,
    required this.longitude,
    required this.coordinateStatus,
    required this.coordinateReviewStatus,
    required this.coordinateSource,
    required this.coordinateRevision,
    required this.provenance,
  });

  final double? latitude;
  final double? longitude;
  final String coordinateStatus;
  final String coordinateReviewStatus;
  final String coordinateSource;
  final String coordinateRevision;
  final Map<String, dynamic> provenance;

  bool get hasValidCoordinates {
    final double? lat = latitude;
    final double? lng = longitude;
    return lat != null &&
        lng != null &&
        lat.isFinite &&
        lng.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lng >= -180 &&
        lng <= 180 &&
        !(lat == 0 && lng == 0);
  }

  bool get isVerified {
    if (!hasValidCoordinates) return false;
    final String status = coordinateStatus.toLowerCase();
    if (status == 'verified') return true;
    if (status.isNotEmpty) return false;
    return const <String>{
          'reviewed',
          'verified',
        }.contains(coordinateReviewStatus.toLowerCase()) ||
        coordinateSource.toLowerCase() == 'admin_review';
  }

  DateTime? referenceTime(DateTime? publishedAt) {
    if (publishedAt != null) return publishedAt.toUtc();
    for (final String key in const <String>[
      'coordinateVerifiedAt',
      'coordinateReviewedAt',
    ]) {
      final DateTime? parsed = DateTime.tryParse(
        (provenance[key] ?? '').toString(),
      );
      if (parsed != null) return parsed.toUtc();
    }
    return null;
  }

  static RetailerCoordinateSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw.keys.any((Object? key) => key is! String)) return null;
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    const Set<String> allowedKeys = <String>{
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
      'gps',
      'location',
      'coordinates',
      'coordinate',
      'geoPoint',
      'geopoint',
      'coordinateStatus',
      'coordinateReviewStatus',
      'coordinateSource',
      'coordinateReviewedAt',
      'coordinateReviewedByUid',
      'coordinateReviewedBy',
      'coordinateVerifiedAt',
      'coordinateVerifiedByUid',
      'coordinateVerifiedBy',
      'coordinateRevision',
    };
    if (data.keys.any((String key) => !allowedKeys.contains(key))) return null;

    final (double?, double?) point = _readCoordinatePair(data);
    final RetailerCoordinateSnapshot snapshot = RetailerCoordinateSnapshot(
      latitude: point.$1,
      longitude: point.$2,
      coordinateStatus: _text(data['coordinateStatus']).toLowerCase(),
      coordinateReviewStatus: _text(data['coordinateReviewStatus']),
      coordinateSource: _text(data['coordinateSource']),
      coordinateRevision: _text(data['coordinateRevision']),
      provenance: <String, dynamic>{
        for (final String key in const <String>[
          'coordinateReviewedAt',
          'coordinateReviewedByUid',
          'coordinateReviewedBy',
          'coordinateVerifiedAt',
          'coordinateVerifiedByUid',
          'coordinateVerifiedBy',
        ])
          if (data.containsKey(key)) key: _cacheableSnapshotValue(data[key]),
      },
    );
    return snapshot.hasValidCoordinates ? snapshot : null;
  }

  static RetailerCoordinateSnapshot? fromRetailerRecord(
    String retailerId,
    Map<String, dynamic> retailer,
  ) {
    final Map<String, dynamic> fields = _retailerCoordinateFields(retailer);
    final RetailerCoordinateSnapshot? point = tryParse(fields);
    if (point == null || !point.isVerified || retailerId.trim().isEmpty) {
      return null;
    }
    final Map<String, dynamic> verifiedSnapshot = <String, dynamic>{
      'latitude': point.latitude,
      'longitude': point.longitude,
      'coordinateStatus': 'verified',
    };
    const List<String> provenanceKeys = <String>[
      'coordinateReviewStatus',
      'coordinateSource',
      'coordinateReviewedAt',
      'coordinateReviewedByUid',
      'coordinateReviewedBy',
      'coordinateVerifiedAt',
      'coordinateVerifiedByUid',
      'coordinateVerifiedBy',
    ];
    for (final String key in provenanceKeys) {
      if (retailer.containsKey(key) && retailer[key] != null) {
        verifiedSnapshot[key] = retailer[key];
      }
    }
    final List<Object?> parts = <Object?>[
      'retailer-coordinate-v1',
      retailerId.trim(),
      point.latitude,
      point.longitude,
    ];
    for (final String key in <String>['coordinateStatus', ...provenanceKeys]) {
      if (verifiedSnapshot.containsKey(key)) {
        parts.add(<Object?>[
          key,
          _coordinateRevisionValue(verifiedSnapshot[key]),
        ]);
      }
    }
    final String revision =
        'v1:${base64Url.encode(utf8.encode(jsonEncode(parts))).replaceAll('=', '')}';
    return RetailerCoordinateSnapshot(
      latitude: point.latitude,
      longitude: point.longitude,
      coordinateStatus: 'verified',
      coordinateReviewStatus: point.coordinateReviewStatus,
      coordinateSource: point.coordinateSource,
      coordinateRevision: revision,
      provenance: point.provenance,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'latitude': latitude,
    'longitude': longitude,
    if (coordinateStatus.isNotEmpty) 'coordinateStatus': coordinateStatus,
    if (coordinateReviewStatus.isNotEmpty)
      'coordinateReviewStatus': coordinateReviewStatus,
    if (coordinateSource.isNotEmpty) 'coordinateSource': coordinateSource,
    if (coordinateRevision.isNotEmpty) 'coordinateRevision': coordinateRevision,
    ...provenance,
  };
}

(double?, double?) _readCoordinatePair(Map<String, dynamic> row) {
  const List<String> latitudeKeys = <String>[
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
  const List<String> longitudeKeys = <String>[
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
  for (final String key in const <String>[
    'gps',
    'location',
    'coordinates',
    'coordinate',
    'geoPoint',
    'geopoint',
  ]) {
    final Object? value = row[key];
    if (value is List && value.length >= 2) {
      final double? first = _optionalNumber(value[0]);
      final double? second = _optionalNumber(value[1]);
      if (_validCoordinatePair(first, second)) return (first, second);
      if (_validCoordinatePair(second, first)) return (second, first);
    } else if (value is Map) {
      final (double?, double?) nested = _readCoordinatePair(
        Map<String, dynamic>.from(value),
      );
      if (_validCoordinatePair(nested.$1, nested.$2)) return nested;
    } else if (value != null) {
      try {
        final dynamic point = value;
        final double? lat = _optionalNumber(point.latitude);
        final double? lng = _optionalNumber(point.longitude);
        if (_validCoordinatePair(lat, lng)) return (lat, lng);
      } catch (_) {
      }
    }
  }
  double? firstCoordinate(List<String> keys) {
    for (final String key in keys) {
      final double? value = _optionalNumber(row[key]);
      if (value != null) return value;
    }
    return null;
  }

  final double? lat = firstCoordinate(latitudeKeys);
  final double? lng = firstCoordinate(longitudeKeys);
  return _validCoordinatePair(lat, lng) ? (lat, lng) : (null, null);
}

Map<String, dynamic> _retailerCoordinateFields(Map<String, dynamic> retailer) {
  const List<String> keys = <String>[
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
    'gps',
    'location',
    'coordinates',
    'coordinate',
    'geoPoint',
    'geopoint',
    'coordinateStatus',
    'coordinateReviewStatus',
    'coordinateSource',
    'coordinateReviewedAt',
    'coordinateReviewedByUid',
    'coordinateReviewedBy',
    'coordinateVerifiedAt',
    'coordinateVerifiedByUid',
    'coordinateVerifiedBy',
  ];
  return <String, dynamic>{
    for (final String key in keys)
      if (retailer.containsKey(key)) key: retailer[key],
  };
}

Object? _coordinateRevisionValue(Object? value) {
  if (value is Timestamp) return '${value.seconds}:${value.nanoseconds}';
  if (value is DateTime) return value.toUtc().microsecondsSinceEpoch;
  if (value == null || value is num || value is String || value is bool) {
    return value;
  }
  return value.toString();
}

bool _validCoordinatePair(double? latitude, double? longitude) =>
    latitude != null &&
    longitude != null &&
    latitude.isFinite &&
    longitude.isFinite &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180 &&
    !(latitude == 0 && longitude == 0);

Object? _cacheableSnapshotValue(Object? value) {
  if (value is Timestamp) return value.toDate().toUtc().toIso8601String();
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  return value.toString();
}

int _estimateTravelMinutes(double distanceKm) {
  if (!distanceKm.isFinite || distanceKm <= 0) return 0;
  return (distanceKm / 28 * 60).round();
}

double? _optionalNumber(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

class RouteProgress {
  RouteProgress({
    required this.status,
    required this.stopProgress,
    this.arrivalModes = const <String, String>{},
    this.selectedStopId = '',
    this.routeSessionState = 'untracked',
    this.selectionRevision = 0,
    this.canonicalStopDocuments = const <String, Map<String, dynamic>>{},
    this.rawData = const <String, dynamic>{},
    this.hasDocument = false,
    this.lastSyncedAt,
    this.hasPendingWrites = false,
    this.isFromCache = false,
  });

  final String status;
  final Map<String, String> stopProgress;
  final Map<String, String> arrivalModes;
  final String selectedStopId;
  final String routeSessionState;
  final int selectionRevision;
  final Map<String, Map<String, dynamic>> canonicalStopDocuments;
  final Map<String, dynamic> rawData;
  final bool hasDocument;
  final DateTime? lastSyncedAt;
  final bool hasPendingWrites;
  final bool isFromCache;

  factory RouteProgress.fromMap(
    Map<String, dynamic>? data, {
    bool hasPendingWrites = false,
    bool isFromCache = false,
    bool? hasDocument,
    Map<String, Map<String, dynamic>> canonicalStopDocuments =
        const <String, Map<String, dynamic>>{},
  }) {
    final raw = data?['stopProgress'];
    final progress = <String, String>{};
    final arrivalModes = <String, String>{};
    final Object? rawSelectionRevision = data?['selectionRevision'];
    final int selectionRevision =
        rawSelectionRevision is int && rawSelectionRevision >= 0
        ? rawSelectionRevision
        : 0;
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is Map) {
          progress[key.toString()] = _text(
            value['status'],
            fallback: 'not_started',
          );
          final Object? rawEvidence = value['arrivalEvidence'];
          if (rawEvidence is Map) {
            final String mode = _text(rawEvidence['mode']);
            if (mode.isNotEmpty) arrivalModes[key.toString()] = mode;
          }
        } else {
          progress[key.toString()] = _text(value, fallback: 'not_started');
        }
      });
    }
    final String lastStopId = _text(data?['lastStopId']);
    final String lastStopStatus = _text(data?['lastStopStatus']);
    if (lastStopId.isNotEmpty &&
        lastStopStatus.isNotEmpty &&
        _text(progress[lastStopId], fallback: 'not_started') == 'not_started') {
      progress[lastStopId] = lastStopStatus;
    }
    for (final MapEntry<String, Map<String, dynamic>> entry
        in canonicalStopDocuments.entries) {
      final Map<String, dynamic> canonical = entry.value;
      final int schemaVersion = canonical['lifecycleSchemaVersion'] is num
          ? (canonical['lifecycleSchemaVersion'] as num).toInt()
          : 0;
      final String canonicalStatus = _text(canonical['status']).toLowerCase();
      if (schemaVersion == 2 &&
          <String>{
            'arrived',
            'completed',
            'skipped',
          }.contains(canonicalStatus)) {
        progress[entry.key] = canonicalStatus;
      } else if (canonicalStatus == 'arrived') {
        final String parentStatus = _text(progress[entry.key]).toLowerCase();
        if (!<String>{'completed', 'skipped'}.contains(parentStatus)) {
          progress[entry.key] = 'arrived';
        }
      }
      final String mode = _text(canonical['arrivalMode']);
      if (mode.isNotEmpty) arrivalModes[entry.key] = mode;
    }
    return RouteProgress(
      status: _text(data?['status'], fallback: 'assigned'),
      stopProgress: progress,
      arrivalModes: arrivalModes,
      selectedStopId: _text(data?['selectedStopId']),
      routeSessionState: _text(
        data?['routeSessionState'],
        fallback: 'untracked',
      ),
      selectionRevision: selectionRevision,
      canonicalStopDocuments: canonicalStopDocuments,
      rawData: data == null
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(data),
      hasDocument: hasDocument ?? data != null,
      lastSyncedAt: _toDate(data?['lastSyncedAt']),
      hasPendingWrites: hasPendingWrites,
      isFromCache: isFromCache,
    );
  }

  String statusFor(String stopId, String fallback) {
    return stopProgress[stopId] ?? fallback;
  }

  String arrivalModeFor(String stopId) => arrivalModes[stopId] ?? '';

  Map<String, dynamic>? canonicalStopFor(String stopId) =>
      canonicalStopDocuments[stopId];
}

String _text(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

double _number(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().replaceAll(',', '').trim()) ?? 0;
}

DateTime? _toDate(Object? value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is num) {
    final n = value.toInt();
    return DateTime.fromMillisecondsSinceEpoch(n > 9999999999 ? n : n * 1000);
  }
  return DateTime.tryParse(value.toString().trim());
}
