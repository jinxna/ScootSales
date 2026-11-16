import 'order_data_utils.dart';

int scoreSheetProductCount(Map<String, dynamic> sheet) {
  final int visibleIds = (sheet['visibleProductIds'] as List?)?.length ?? 0;
  if (visibleIds > 0) return visibleIds;

  for (final String key in <String>[
    'productCount',
    'visibleProductCount',
    'productIds',
    'selectedProducts',
  ]) {
    final Object? value = sheet[key];
    if (value is List) return value.length;
    if (value is num) return value.toInt();
  }
  return 0;
}

bool isArtificialOrderVisit(Map<String, dynamic> row) {
  final String type = dataText(
    pickFirst(row, const <String>['type', 'eventType', 'event_type']),
  ).toLowerCase();
  return type == 'order_submission';
}

bool hasRecordedVisitTiming(Map<String, dynamic> order) {
  final String visitId = dataText(
    pickFirst(order, const <String>['visitId', 'visit_id']),
  );
  if (visitId.isEmpty) return false;

  final Object? started = pickFirst(order, const <String>[
    'arrivalTime',
    'arrival_time',
    'visitStartAt',
    'visitStartedAt',
    'arrivedAt',
  ]);
  final Object? ended = pickFirst(order, const <String>[
    'departureTime',
    'departure_time',
    'visitEndAt',
    'visitEndedAt',
    'completedAt',
  ]);
  return started != null && ended != null;
}

bool isSkippedVisit(Map<String, dynamic> row) {
  for (final String key in const <String>[
    'status',
    'trackingStatus',
    'tracking_status',
  ]) {
    if (dataText(row[key]).toLowerCase() == 'skipped') return true;
  }
  return false;
}

bool isLocationOnlyVisitRow(Map<String, dynamic> row) {
  final Object? source = row['sourceCollection'];
  return source == 'gps_tracking' || source == 'users';
}

const String assignedRouteVisitSource = 'assigned_route';

Map<String, dynamic>? routeStopProgressToVisitRow(Map<String, dynamic> stop) {
  final Object? arrivedAt = stop['arrivedAt'];
  final Object? completedAt = stop['completedAt'];
  final Object? skippedAt = completedAt == null ? stop['skippedAt'] : null;
  if (arrivedAt == null && skippedAt == null) return null;
  final String docId = dataText(stop['docId']);
  final String code = dataText(stop['salesmanCode']);
  final Object? leftAt = completedAt ?? skippedAt;
  return <String, dynamic>{
    'docId': 'route_stop_progress_$docId',
    'bridgeKey': 'route_stop_progress:$docId',
    'sourceCollection': 'route_stop_progress',
    'source': assignedRouteVisitSource,
    'planId': stop['planId'],
    'stopId': stop['stopId'],
    'salesmanUid': stop['salesmanUid'],
    'salesmanCode': code,
    'salesmanId': code.isNotEmpty ? code : dataText(stop['salesmanUid']),
    'branchId': stop['branchId'],
    'retailerId': stop['retailerId'],
    'retailerName': stop['retailerName'],
    'arrivalTime': arrivedAt,
    'arrival_time': arrivedAt,
    'departureTime': leftAt,
    'departure_time': leftAt,
    'createdAt': arrivedAt ?? skippedAt,
    'updatedAt': stop['updatedAt'] ?? leftAt ?? arrivedAt,
    'status': completedAt != null
        ? 'completed'
        : skippedAt != null
        ? 'skipped'
        : 'in progress',
    if (stop['arrivalLatitude'] is num) 'latitude': stop['arrivalLatitude'],
    if (stop['arrivalLongitude'] is num) 'longitude': stop['arrivalLongitude'],
    if (stop['arrivalAccuracyMeters'] is num)
      'accuracyMeters': stop['arrivalAccuracyMeters'],
    if (stop['arrivalMode'] is String) 'arrivalMode': stop['arrivalMode'],
    if (stop['arrivalDistanceMeters'] is num)
      'arrivalDistanceMeters': stop['arrivalDistanceMeters'],
  };
}

DateTime kuchingDayStartUtc(int year, int month, int day) =>
    DateTime.utc(year, month, day).subtract(const Duration(hours: 8));

List<Map<String, dynamic>> dedupeAssignedRouteVisits(
  List<Map<String, dynamic>> rows,
) {
  String? stopKey(Map<String, dynamic> row) {
    final String plan = dataText(row['planId']);
    final String stop = dataText(row['stopId']);
    return plan.isEmpty || stop.isEmpty ? null : '$plan|$stop';
  }

  bool isStopRow(Map<String, dynamic> row) =>
      row['sourceCollection'] == 'route_stop_progress';

  final Set<String> logged = <String>{
    for (final Map<String, dynamic> row in rows)
      if (!isStopRow(row)) ?stopKey(row),
  };
  return rows
      .where((Map<String, dynamic> row) {
        if (!isStopRow(row)) return true;
        final String? key = stopKey(row);
        return key == null || !logged.contains(key);
      })
      .toList(growable: false);
}
