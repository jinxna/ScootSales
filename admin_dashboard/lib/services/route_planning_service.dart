import '../utils/collection_rows.dart';
import '../utils/covered_query.dart';
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_plan.dart';
import 'audit_log_service.dart';
import '../utils/geo_field_utils.dart';
import '../utils/order_data_utils.dart' show isOperationalRetailerRecord;
import '../utils/retailer_readiness.dart';
import '../utils/route_execution.dart';
import '../utils/route_ranking_selection.dart';
import '../utils/firestore_query_utils.dart';
import '../utils/firestore_value_equality.dart';
import '../utils/route_regions.dart';
import '../utils/route_service_time_input.dart';
import '../utils/route_stop_order.dart';
import 'geoapify_config.dart';
import 'geoapify_route_matrix_client.dart';
import 'geoapify_routing_client.dart';

const int kRouteAreaMinShops = 2;

const String kPlacedWithNearestShops = 'Placed with the nearest shops.';
const String kPlacedByManager = 'Placed by the manager.';
const String kAddedByManager = 'Added by the manager.';

String routeReasonMovedByManager(String reason) {
  final String kept = reason.replaceAll(kPlacedWithNearestShops, '').trim();
  if (kept.contains(kPlacedByManager) || kept.contains(kAddedByManager)) {
    return kept;
  }
  return '$kept $kPlacedByManager'.trim();
}

class RoutePlanningService {
  Future<List<Map<String, dynamic>>> loadStopArrivalDocuments({
    required List<String> planIds,
    String salesmanCode = '',
    String branchId = '',
  }) async {
    final List<String> ids = planIds
        .map((String id) => id.trim())
        .where((String id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return const <Map<String, dynamic>>[];
    final List<List<Map<String, dynamic>>> chunkRows = await Future.wait(
      chunkFirestoreWhereIn(ids).map((List<String> chunk) async {
        Query<Map<String, dynamic>> query = _db
            .collection('route_stop_progress')
            .where('planId', whereIn: chunk);
        if (salesmanCode.trim().isNotEmpty) {
          query = query.where('salesmanCode', isEqualTo: salesmanCode.trim());
        }
        if (branchId.trim().isNotEmpty) {
          query = query.where('branchId', isEqualTo: branchId.trim());
        }
        final QuerySnapshot<Map<String, dynamic>> snapshot = await query.get(
          const GetOptions(source: Source.server),
        );
        return <Map<String, dynamic>>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
              in snapshot.docs)
            <String, dynamic>{...doc.data(), 'docId': doc.id},
        ];
      }),
    );
    return <Map<String, dynamic>>[for (final rows in chunkRows) ...rows];
  }

  RoutePlanningService({
    String geoapifyApiKey = GeoapifyConfig.apiKey,
    Duration geoapifyTimeout = const Duration(seconds: 4),
    GeoapifyRouteMatrixClient? geoapifyClient,
    GeoapifyRoutingClient? routingClient,
  }) : _geoapifyClient =
           geoapifyClient ??
           GeoapifyRouteMatrixClient(
             apiKey: geoapifyApiKey,
             timeout: geoapifyTimeout,
           ),
       _routingClient =
           routingClient ?? GeoapifyRoutingClient(apiKey: geoapifyApiKey);

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  final GeoapifyRouteMatrixClient _geoapifyClient;
  final GeoapifyRoutingClient _routingClient;

  bool get isRoadRoutingConfigured => _geoapifyClient.isConfigured;

  static const Distance _distance = DistanceHaversine(roundResult: false);

  Future<RoutePlan> generateWeeklyRoute({
    required String salesmanUid,
    String salesmanCode = '',
    required String salesmanName,
    required DateTime weekStart,
    required List<Map<String, dynamic>> retailers,
    required String branchId,
    required String createdByUid,
    String createdByRole = '',
    String source = 'dashboard',
    bool isDemo = false,
    int maxPerDay = 6,
    int serviceMinutes = 20,
    int workdayStartHour = 9,
    RouteStartPoint? depot,
    void Function(String dayId, RouteLegTable table)? onLegTable,
    Map<String, ServiceTimeStat> learnedServiceTimes =
        const <String, ServiceTimeStat>{},
    Map<String, DateTime> lastVisitByRetailer = const <String, DateTime>{},
    RouteRankingInput? ranking,
    Map<String, int> usualOrderWeekdays = const <String, int>{},
    Map<String, DateTime> followUpDates = const <String, DateTime>{},
    Map<String, String> followUpRetailerNames = const <String, String>{},
  }) async {
    final DateTime monday = _mondayOf(weekStart);
    final LatLng? start = depot == null ? null : LatLng(depot.lat, depot.lng);
    final List<_Candidate> scored = _scoreCandidates(
      retailers,
      start,
      lastVisitByRetailer,
    );
    final RouteRankingInput? usedRanking =
        ranking != null &&
            ranking.ranksAnyOf(scored.map((_Candidate c) => c.id))
        ? ranking
        : null;
    final List<_Candidate> candidates = usedRanking == null
        ? scored
        : _inRankingOrder(scored, usedRanking);

    final int capacity = maxPerDay * 6;
    bool followUpDue(_Candidate c) =>
        routeFollowUpDayIndex(followUpDates[c.id], monday) != null;
    final List<_Candidate> selected = <_Candidate>[
      ...candidates.where(followUpDue),
      ...candidates.where((_Candidate c) => !followUpDue(c)),
    ].take(capacity).toList();
    final Map<String, int> placeOf = <String, int>{
      for (int i = 0; i < candidates.length; i++) candidates[i].id: i,
    };

    final Map<String, int> effectiveServiceMinutesByRetailer =
        buildServiceMinutesByRetailer(
          retailerIds: selected.map((_Candidate c) => c.id),
          defaultServiceMinutes: serviceMinutes,
          learnedServiceTimes: learnedServiceTimes,
        );

    final List<List<_Candidate>> buckets = usedRanking == null
        ? assignRegionDays<_Candidate>(
            selected,
            regionOf: (_Candidate c) => c.region,
            scoreOf: (_Candidate c) => c.score,
            preferredDaysOf: (_Candidate c) => c.preferredDays,
            maxPerDay: maxPerDay,
          )
        : _rankedAreaDays(
            selected,
            ranking: usedRanking,
            placeOf: placeOf,
            maxPerDay: maxPerDay,
          );
    final List<RouteFollowUpNotPlaced> followUpsNotPlaced = _applyDayRules(
      buckets,
      placeOf: placeOf,
      monday: monday,
      maxPerDay: maxPerDay,
      usualOrderWeekdays: usualOrderWeekdays,
      followUpDates: followUpDates,
    );
    final Set<String> accountedFor = <String>{
      for (final List<_Candidate> bucket in buckets)
        for (final _Candidate c in bucket) c.id,
      for (final RouteFollowUpNotPlaced row in followUpsNotPlaced)
        row.retailerId,
    };
    final Map<String, String> candidateNames = <String, String>{
      for (final _Candidate c in candidates) c.id: c.name,
    };
    followUpDates.forEach((String retailerId, DateTime date) {
      if (routeFollowUpDayIndex(date, monday) == null ||
          !accountedFor.add(retailerId)) {
        return;
      }
      followUpsNotPlaced.add(
        RouteFollowUpNotPlaced(
          retailerId: retailerId,
          retailerName:
              candidateNames[retailerId] ??
              followUpRetailerNames[retailerId] ??
              retailerId,
          followUpDate: routeDateKey(date),
        ),
      );
    });

    final List<RouteDay?> builtDays = List<RouteDay?>.filled(6, null);
    final List<String?> dayNotes = List<String?>.filled(6, null);

    Future<void> buildPlannedDay(int d) async {
      final DateTime date = monday.add(Duration(days: d));
      final List<_Candidate> dayStops = buckets[d];
      if (dayStops.isEmpty) {
        builtDays[d] = RouteDay(
          dayId: _dayIdFor(d),
          dayLabel: _weekdayLabel(d),
          date: date,
          stops: const <RouteStop>[],
          totalDistanceKm: 0,
          estimatedServiceMinutes: 0,
        );
        return;
      }
      RouteLegTable? table;
      final int pointCount = dayStops.length + (start == null ? 0 : 1);
      if (_geoapifyClient.isConfigured && pointCount >= 2) {
        try {
          table = await _roadLegTable(dayStops, start);
          onLegTable?.call(_dayIdFor(d), table);
        } on GeoapifyRouteMatrixException catch (error) {
          dayNotes[d] =
              'Road times unavailable for ${_weekdayLabel(d)}: ${error.message}';
        }
      }
      final _OrderedDay ordered = _orderDay(dayStops, start, table);
      _OrderedDay drawn = ordered;
      if (_routingClient.isConfigured && pointCount >= 2) {
        try {
          drawn = await _withRoadRoute(ordered, start);
        } on GeoapifyRoutingException catch (error) {
          dayNotes[d] =
              'Road route unavailable for ${_weekdayLabel(d)}: ${error.message}';
        }
      }
      builtDays[d] = _buildDay(
        dayIndex: d,
        date: date,
        ordered: drawn,
        serviceMinutes: serviceMinutes,
        workdayStartHour: workdayStartHour,
        serviceMinutesByRetailer: effectiveServiceMinutesByRetailer,
      );
    }

    int nextDay = 0;
    Future<void> dayLane() async {
      while (nextDay < 6) {
        await buildPlannedDay(nextDay++);
      }
    }

    await Future.wait(<Future<void>>[dayLane(), dayLane()]);
    final List<RouteDay> days = <RouteDay>[for (final d in builtDays) d!];
    final List<String> roadRouteNotes = <String>[
      for (final note in dayNotes)
        if (note != null) note,
    ];

    final bool hasRoutableStops = days.any(
      (RouteDay day) => day.stops.isNotEmpty,
    );
    final String fallbackMethod = isDemo
        ? 'Demo'
        : hasRoutableStops &&
              (_geoapifyClient.isConfigured || _routingClient.isConfigured)
        ? 'GeoapifyConfiguredHaversineFallback'
        : 'HaversineNearestNeighbour';
    final String method = RoutePlan.metricSourceMethodForDays(
      days,
      fallback: fallbackMethod,
    );

    return RoutePlan(
      id: '',
      weekStart: monday,
      weekEnd: monday.add(const Duration(days: 5)),
      status: 'draft',
      branchId: branchId,
      createdByUid: createdByUid,
      createdByRole: createdByRole,
      salesmanUid: salesmanUid,
      salesmanCode: salesmanCode,
      salesmanName: salesmanName,
      source: source,
      isDemo: isDemo,
      optimisationMethod: method,
      days: days,
      roadRouteNotes: roadRouteNotes,
      startPoint: depot,
      selectionMethod: usedRanking == null ? '' : kRouteSelectionRankingOrder,
      rankingId: usedRanking?.rankingId ?? '',
      rankingWeekKey: usedRanking?.weekKey ?? '',
      followUpsNotPlaced: followUpsNotPlaced,
    );
  }

  List<List<_Candidate>> _rankedAreaDays(
    List<_Candidate> selected, {
    required RouteRankingInput ranking,
    required Map<String, int> placeOf,
    required int maxPerDay,
  }) {
    bool isRanked(_Candidate c) => ranking.rankByRetailer.containsKey(c.id);
    final Map<String, int> areaSize = <String, int>{};
    for (final _Candidate c in selected.where(isRanked)) {
      areaSize[c.region] = (areaSize[c.region] ?? 0) + 1;
    }
    bool hasArea(_Candidate c) =>
        c.region.trim().isNotEmpty &&
        c.region != kUnzonedRegion &&
        (areaSize[c.region] ?? 0) >= kRouteAreaMinShops;
    final List<List<_Candidate>> buckets = assignRegionDays<_Candidate>(
      selected.where((_Candidate c) => isRanked(c) && hasArea(c)).toList(),
      regionOf: (_Candidate c) => c.region,
      scoreOf: (_Candidate c) => -placeOf[c.id]!.toDouble(),
      preferredDaysOf: (_Candidate c) => c.preferredDays,
      maxPerDay: maxPerDay,
    );
    final int cap = maxPerDay <= 0 ? 1 : maxPerDay;
    bool hasRoom(List<_Candidate> bucket) => bucket.length < cap;
    double metresToDay(_Candidate c, List<_Candidate> bucket) => bucket
        .map(
          (_Candidate other) =>
              _distance.as(LengthUnit.Meter, c.position, other.position),
        )
        .reduce((double a, double b) => a < b ? a : b);
    for (final _Candidate c in selected.where(
      (_Candidate c) => !isRanked(c) || !hasArea(c),
    )) {
      int nearestDay = -1;
      double nearestMetres = double.infinity;
      for (int d = 0; d < buckets.length; d++) {
        if (buckets[d].isEmpty || !hasRoom(buckets[d])) continue;
        final double metres = metresToDay(c, buckets[d]);
        if (metres < nearestMetres) {
          nearestMetres = metres;
          nearestDay = d;
        }
      }
      final int emptyDay = buckets.indexWhere(
        (List<_Candidate> bucket) => bucket.isEmpty,
      );
      final int openDay = buckets.indexWhere(hasRoom);
      final int day = nearestDay >= 0
          ? nearestDay
          : emptyDay >= 0
          ? emptyDay
          : openDay >= 0
          ? openDay
          : buckets.length - 1;
      buckets[day].add(c);
      c.reason = isRanked(c)
          ? '${c.reason.trim()} $kPlacedWithNearestShops'.trim()
          : '$kNotInWeeklyRanking. $kPlacedWithNearestShops';
    }
    return buckets;
  }

  int _nearestDayWithRoom(
    List<List<_Candidate>> buckets, {
    required int target,
    required int cap,
    required int fallback,
  }) {
    int nearest = fallback;
    for (int d = 0; d < buckets.length; d++) {
      if (buckets[d].length < cap &&
          (d - target).abs() < (nearest - target).abs()) {
        nearest = d;
      }
    }
    return nearest;
  }

  List<RouteFollowUpNotPlaced> _applyDayRules(
    List<List<_Candidate>> buckets, {
    required Map<String, int> placeOf,
    required DateTime monday,
    required int maxPerDay,
    required Map<String, int> usualOrderWeekdays,
    required Map<String, DateTime> followUpDates,
  }) {
    final int cap = maxPerDay <= 0 ? 1 : maxPerDay;
    final List<_Candidate> inPlaceOrder =
        <_Candidate>[for (final List<_Candidate> bucket in buckets) ...bucket]
          ..sort(
            (_Candidate a, _Candidate b) =>
                placeOf[a.id]!.compareTo(placeOf[b.id]!),
          );
    int? followUpDay(_Candidate c) =>
        routeFollowUpDayIndex(followUpDates[c.id], monday);
    int dayOf(_Candidate c) =>
        buckets.indexWhere((List<_Candidate> bucket) => bucket.contains(c));

    for (final _Candidate c in inPlaceOrder) {
      final int? weekday = usualOrderWeekdays[c.id];
      if (weekday == null || weekday < 1 || weekday > buckets.length) continue;
      final int usual = weekday - 1;
      c.reason = _withLabel(
        c.reason,
        'Usual order day: ${_weekdayLabel(usual)}',
      );
      if (followUpDay(c) != null) continue;
      final int from = dayOf(c);
      if (from == usual) continue;
      if (buckets[usual].length < cap) {
        buckets[from].remove(c);
        buckets[usual].add(c);
        continue;
      }
      final List<_Candidate> areaOnly =
          buckets[usual]
              .where(
                (_Candidate other) =>
                    followUpDay(other) == null &&
                    usualOrderWeekdays[other.id] != weekday &&
                    placeOf[other.id]! > placeOf[c.id]!,
              )
              .toList()
            ..sort(
              (_Candidate a, _Candidate b) =>
                  placeOf[b.id]!.compareTo(placeOf[a.id]!),
            );
      if (areaOnly.isEmpty) continue;
      final _Candidate displaced = areaOnly.first;
      buckets[from].remove(c);
      buckets[usual].remove(displaced);
      buckets[usual].add(c);
      final int moveTo = _nearestDayWithRoom(
        buckets,
        target: usual,
        cap: cap,
        fallback: from,
      );
      buckets[moveTo].add(displaced);
    }

    final List<RouteFollowUpNotPlaced> notPlaced = <RouteFollowUpNotPlaced>[];
    for (final _Candidate c in inPlaceOrder) {
      final int? target = followUpDay(c);
      if (target == null) continue;
      final DateTime date = followUpDates[c.id]!;
      c.reason = _withLabel(c.reason, routeFollowUpLabel(date, monday));
      final int from = dayOf(c);
      if (from == target) continue;
      if (buckets[target].length < cap) {
        buckets[from].remove(c);
        buckets[target].add(c);
        continue;
      }
      final List<_Candidate> movable =
          buckets[target]
              .where((_Candidate other) => followUpDay(other) == null)
              .toList()
            ..sort(
              (_Candidate a, _Candidate b) =>
                  placeOf[b.id]!.compareTo(placeOf[a.id]!),
            );
      buckets[from].remove(c);
      if (movable.isEmpty) {
        notPlaced.add(
          RouteFollowUpNotPlaced(
            retailerId: c.id,
            retailerName: c.name,
            followUpDate: routeDateKey(date),
          ),
        );
        continue;
      }
      final _Candidate displaced = movable.first;
      buckets[target].remove(displaced);
      buckets[target].add(c);
      final int moveTo = _nearestDayWithRoom(
        buckets,
        target: target,
        cap: cap,
        fallback: from,
      );
      buckets[moveTo].add(displaced);
    }
    return notPlaced;
  }

  String _withLabel(String reason, String label) {
    final String text = reason.trim();
    if (text.toLowerCase().startsWith('prioritised:') && text.endsWith('.')) {
      return '${text.substring(0, text.length - 1)}, $label.';
    }
    return text.isEmpty ? '$label.' : '$text $label.';
  }

  List<_Candidate> _inRankingOrder(
    List<_Candidate> scored,
    RouteRankingInput ranking,
  ) {
    final List<_Candidate> ranked =
        scored
            .where((_Candidate c) => ranking.rankByRetailer.containsKey(c.id))
            .toList()
          ..sort(
            (_Candidate a, _Candidate b) => ranking.rankByRetailer[a.id]!
                .compareTo(ranking.rankByRetailer[b.id]!),
          );
    final List<_Candidate> ordered = <_Candidate>[
      ...ranked,
      ...scored.where(
        (_Candidate c) => !ranking.rankByRetailer.containsKey(c.id),
      ),
    ];
    for (final _Candidate c in ordered) {
      c.reason = ranking.reasonFor(c.id, c.reason);
    }
    return ordered;
  }

  RouteStop stopForRetailer(
    Map<String, dynamic> retailer, {
    required int dayIndex,
    required Set<String> takenStopIds,
    required String reason,
  }) {
    final List<_Candidate> one = _scoreCandidates(
      <Map<String, dynamic>>[retailer],
      null,
      const <String, DateTime>{},
    );
    if (one.isEmpty) {
      throw StateError('This shop has no coordinates.');
    }
    final _Candidate c = one.first;
    return RouteStop(
      stopId: freeStopId(dayIndex, c.id, takenStopIds),
      dayId: dayIdFor(dayIndex),
      retailerId: c.id,
      retailerName: c.name,
      address: c.address,
      lat: c.position.latitude,
      lng: c.position.longitude,
      sequence: 0,
      arrival: '',
      departure: '',
      legDistanceKm: 0,
      reason: reason,
      score: 0,
      retailerCoordinateSnapshot: c.retailerCoordinateSnapshot,
    );
  }

  String freeStopId(int dayIndex, String retailerId, Set<String> taken) {
    int sequence = 1;
    while (taken.contains(_stopIdFor(dayIndex, sequence, retailerId))) {
      sequence++;
    }
    return _stopIdFor(dayIndex, sequence, retailerId);
  }

  String dayIdFor(int dayIndex) => _dayIdFor(dayIndex);

  Future<RouteDay> refreshRoadGeometry(
    RouteDay day, {
    required RouteStartPoint? start,
    int serviceMinutes = 20,
    int workdayStartHour = 9,
    Map<String, ServiceTimeStat> learnedServiceTimes =
        const <String, ServiceTimeStat>{},
  }) async {
    final RouteDay base = recomputeDay(
      day,
      serviceMinutes: serviceMinutes,
      workdayStartHour: workdayStartHour,
      learnedServiceTimes: learnedServiceTimes,
      start: start,
      orderMethod: day.orderMethod,
    );
    final LatLng? startPosition = start == null
        ? null
        : LatLng(start.lat, start.lng);
    final GeoapifyRouteResult road = await _roadRoute(
      _roundTripWaypoints(<LatLng>[
        for (final RouteStop s in base.stops) LatLng(s.lat, s.lng),
      ], startPosition),
    );
    final _RoadLegs legs = _RoadLegs.read(
      road,
      base.stops.length,
      startPosition,
    );
    int clock = workdayStartHour * 60;
    final List<RouteStop> stops = <RouteStop>[];
    for (int i = 0; i < base.stops.length; i++) {
      final RouteStop s = base.stops[i];
      clock += legs.minutes[i];
      final String arrival = _hhmm(clock);
      clock += _minutesOf(s.departure) - _minutesOf(s.arrival);
      stops.add(
        s.copyWith(
          arrival: arrival,
          departure: _hhmm(clock),
          legDistanceKm: double.parse(legs.km[i].toStringAsFixed(2)),
          travelMinutesFromPrevious: legs.minutes[i],
        ),
      );
    }
    return base.copyWith(
      stops: stops,
      totalDistanceKm: double.parse(legs.totalKm.toStringAsFixed(2)),
      geometry: simplifyRoadGeometry(road.legs),
      geometrySource: 'geoapify_route',
      estimateSource: 'geoapify_routing',
      returnLegDistanceKm: double.parse(legs.returnKm.toStringAsFixed(2)),
      returnTravelMinutes: legs.returnMinutes,
    );
  }

  static int _minutesOf(String hhmm) {
    final List<String> p = hhmm.split(':');
    return p.length < 2
        ? 0
        : (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  static List<LatLng> _roundTripWaypoints(List<LatLng> stops, LatLng? start) =>
      <LatLng>[if (start != null) start, ...stops, if (start != null) start];

  final Map<String, GeoapifyRouteLeg> _roadLegCache =
      <String, GeoapifyRouteLeg>{};

  static String _legKey(LatLng from, LatLng to) =>
      '${from.latitude.toStringAsFixed(6)},${from.longitude.toStringAsFixed(6)}'
      '>${to.latitude.toStringAsFixed(6)},${to.longitude.toStringAsFixed(6)}';

  Future<GeoapifyRouteResult> _roadRoute(List<LatLng> waypoints) async {
    final List<String> keys = <String>[
      for (int i = 1; i < waypoints.length; i++)
        _legKey(waypoints[i - 1], waypoints[i]),
    ];
    if (keys.isNotEmpty && keys.every(_roadLegCache.containsKey)) {
      return GeoapifyRouteResult(<GeoapifyRouteLeg>[
        for (final String key in keys) _roadLegCache[key]!,
      ]);
    }
    final GeoapifyRouteResult road = await _routingClient.route(waypoints);
    if (road.legs.length == keys.length) {
      for (int i = 0; i < keys.length; i++) {
        _roadLegCache[keys[i]] = road.legs[i];
      }
    }
    return road;
  }

  Future<_OrderedDay> _withRoadRoute(_OrderedDay ordered, LatLng? start) async {
    final GeoapifyRouteResult road = await _roadRoute(
      _roundTripWaypoints(<LatLng>[
        for (final _Candidate c in ordered.ordered) c.position,
      ], start),
    );
    final _RoadLegs legs = _RoadLegs.read(road, ordered.ordered.length, start);
    return _OrderedDay(
      ordered: ordered.ordered,
      legKm: legs.km,
      legMinutes: legs.minutes,
      returnKm: legs.returnKm,
      returnMinutes: legs.returnMinutes,
      orderMethod: ordered.orderMethod,
      geometry: simplifyRoadGeometry(road.legs),
      geometrySource: 'geoapify_route',
      estimateSource: 'geoapify_routing',
    );
  }

  Future<String> savePlan(RoutePlan plan) async {
    final Map<String, dynamic> data = plan.toMap();
    if (plan.id.isEmpty) {
      if (plan.status != 'draft') {
        throw StateError(
          'A route plan must be saved as draft before approval.',
        );
      }
      final DocumentReference<Map<String, dynamic>> ref = _db
          .collection('route_plans')
          .doc();
      await ref.set(<String, dynamic>{
        ...data,
        'planId': ref.id,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        if (plan.status == 'approved')
          'approvedAt': FieldValue.serverTimestamp(),
        if (plan.status == 'published')
          'publishedAt': FieldValue.serverTimestamp(),
      });
      unawaited(
        AuditLogService.instance.record(
          action: 'created',
          entityType: 'route_plan',
          entityId: ref.id,
          summary:
              'Created draft route for ${plan.salesmanName} '
              '(${_dateKey(plan.weekStart)})',
        ),
      );
      return ref.id;
    }
    if (plan.status == 'published') {
      return _publishPlan(plan);
    }
    await _db.collection('route_plans').doc(plan.id).update(<String, dynamic>{
      ...data,
      'planId': plan.id,
      'updatedAt': FieldValue.serverTimestamp(),
      if (plan.status == 'approved') ...<String, dynamic>{
        'approvedAt': FieldValue.serverTimestamp(),
        'approvedByUid': FirebaseAuth.instance.currentUser?.uid ?? '',
      },
    });
    unawaited(
      AuditLogService.instance.record(
        action: plan.status == 'approved' ? 'approved' : 'updated',
        entityType: 'route_plan',
        entityId: plan.id,
        summary:
            '${plan.status == 'approved' ? 'Approved' : 'Updated'} route for '
            '${plan.salesmanName} (${_dateKey(plan.weekStart)})',
      ),
    );
    return plan.id;
  }

  Future<String> _publishPlan(RoutePlan plan) async {
    final String identity = plan.salesmanUid.trim().isNotEmpty
        ? plan.salesmanUid.trim()
        : plan.salesmanCode.trim();
    if (identity.isEmpty) {
      throw StateError('The route plan has no salesman identity.');
    }

    final String weekKey = _dateKey(plan.weekStart);
    final String keyId = _publicationKey(identity, weekKey);
    final DocumentReference<Map<String, dynamic>> planRef = _db
        .collection('route_plans')
        .doc(plan.id);
    final DocumentReference<Map<String, dynamic>> keyRef = _db
        .collection('route_plan_publication_keys')
        .doc(keyId);
    final String actorUid =
        FirebaseAuth.instance.currentUser?.uid ?? plan.createdByUid;

    final bool didPublish = await _db.runTransaction<bool>((
      Transaction transaction,
    ) async {
      final DocumentSnapshot<Map<String, dynamic>> planSnapshot =
          await transaction.get(planRef);
      if (!planSnapshot.exists) {
        throw StateError('The route plan no longer exists.');
      }
      if (_text(planSnapshot.data()?['status']).toLowerCase() == 'published') {
        return false;
      }
      if (!isPublishableApprovedCopy(plan, planSnapshot.data()!)) {
        throw StateError(
          'This route changed since you opened it. Reload it and approve '
          'the current version before publishing.',
        );
      }
      final DocumentSnapshot<Map<String, dynamic>> keySnapshot =
          await transaction.get(keyRef);
      final Map<String, dynamic>? keyData = keySnapshot.data();
      final String lockedPlanId = '${keyData?['planId'] ?? ''}'.trim();
      final bool active = keyData?['active'] != false;
      if (active && lockedPlanId.isNotEmpty && lockedPlanId != plan.id) {
        final DocumentSnapshot<Map<String, dynamic>> holder = await transaction
            .get(_db.collection('route_plans').doc(lockedPlanId));
        final bool holderPublished =
            holder.exists &&
            _text(holder.data()?['status']).toLowerCase() == 'published';
        if (holderPublished) {
          throw StateError(
            'A published route already exists for this salesman and week.',
          );
        }
      }

      final Set<String> retailerIds = <String>{
        for (final RouteDay day in plan.days)
          for (final RouteStop stop in day.stops)
            if (stop.retailerId.trim().isNotEmpty &&
                !stop.retailerId.contains('/'))
              stop.retailerId.trim(),
      };
      final Map<String, Map<String, dynamic>> retailerRecords =
          <String, Map<String, dynamic>>{};
      final List<String> retailerIdList = retailerIds.toList(growable: false);
      final List<DocumentSnapshot<Map<String, dynamic>>> retailerSnapshots =
          await Future.wait(
            retailerIdList.map(
              (String retailerId) =>
                  transaction.get(_db.collection('retailers').doc(retailerId)),
            ),
          );
      for (int i = 0; i < retailerIdList.length; i++) {
        final DocumentSnapshot<Map<String, dynamic>> retailerSnapshot =
            retailerSnapshots[i];
        final Map<String, dynamic>? retailer = retailerSnapshot.data();
        if (retailerSnapshot.exists && retailer != null) {
          retailerRecords[retailerIdList[i]] = retailer;
        }
      }
      final String? blocker = publishBlocker(plan, retailerRecords);
      if (blocker != null) throw StateError(blocker);
      final List<RouteDay> publishedDays = <RouteDay>[
        for (final RouteDay day in plan.days)
          _snapshotRouteDay(day, retailerRecords),
      ];
      final RoutePlan publishPlan = plan.copyWith(days: publishedDays);

      transaction.set(planRef, <String, dynamic>{
        ...publishPlan.toMap(),
        'planId': plan.id,
        'status': 'published',
        'publicationKeyId': keyId,
        'updatedAt': FieldValue.serverTimestamp(),
        'publishedAt': FieldValue.serverTimestamp(),
        'publishedByUid': actorUid,
      }, SetOptions(merge: true));
      transaction.set(keyRef, <String, dynamic>{
        'keyId': keyId,
        'planId': plan.id,
        'salesmanIdentity': identity,
        'salesmanUid': plan.salesmanUid,
        'salesmanCode': plan.salesmanCode,
        'weekKey': weekKey,
        'weekStart': Timestamp.fromDate(plan.weekStart),
        'active': true,
        'updatedByUid': actorUid,
        'updatedAt': FieldValue.serverTimestamp(),
        if (!keySnapshot.exists) 'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    });
    if (!didPublish) return plan.id;
    unawaited(
      AuditLogService.instance.record(
        action: 'published',
        entityType: 'route_plan',
        entityId: plan.id,
        summary:
            'Published route for ${plan.salesmanName} '
            '(${_dateKey(plan.weekStart)})',
        metadata: <String, dynamic>{
          'salesmanUid': plan.salesmanUid,
          'salesmanCode': plan.salesmanCode,
          'weekKey': weekKey,
          'stops': plan.totalStops,
          'optimisationMethod': plan.metricSourceMethod,
        },
      ),
    );
    return plan.id;
  }

  static String? publishBlocker(
    RoutePlan plan,
    Map<String, Map<String, dynamic>> retailerRecords,
  ) {
    for (final RouteDay day in plan.days) {
      for (final RouteStop stop in day.stops) {
        final String id = stop.retailerId.trim();
        if (id.isEmpty) continue;
        final Map<String, dynamic>? retailer = retailerRecords[id];
        if (retailer == null || !isOperationalRetailerRecord(retailer)) {
          return '${stop.retailerName} is no longer an active retailer. '
              'Regenerate the route and approve it again.';
        }
        if (retailerCoordinateStatus(retailer) == CoordinateStatus.verified) {
          final LatLng? verified = readLatLng(retailer);
          if (verified != null &&
              ((verified.latitude - stop.lat).abs() > 1e-6 ||
                  (verified.longitude - stop.lng).abs() > 1e-6)) {
            return 'The location of ${stop.retailerName} changed after this '
                'route was planned. Regenerate the route and approve it again.';
          }
        }
      }
    }
    return null;
  }

  static bool isPublishableApprovedCopy(
    RoutePlan plan,
    Map<String, dynamic> stored,
  ) {
    if (_text(stored['status']).toLowerCase() != 'approved') return false;
    List<Map<String, dynamic>> days(RoutePlan value) => <Map<String, dynamic>>[
      for (final RouteDay day in value.days) day.toMap(),
    ];
    return sameFirestoreValue(
      days(RoutePlan.fromMap(plan.id, stored)),
      days(RoutePlan.fromMap(plan.id, plan.toMap())),
    );
  }

  static String _publicationKey(String identity, String weekKey) {
    final String safeIdentity = identity.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '_',
    );
    return '${safeIdentity}_$weekKey';
  }

  static String _dateKey(DateTime value) {
    final DateTime date = value.toUtc().add(const Duration(hours: 8));
    return '${date.year.toString().padLeft(4, '0')}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}';
  }

  RouteDay recomputeDay(
    RouteDay day, {
    int serviceMinutes = 20,
    int workdayStartHour = 9,
    Map<String, ServiceTimeStat> learnedServiceTimes =
        const <String, ServiceTimeStat>{},
    RouteStartPoint? start,
    RouteLegTable? legTable,
    String orderMethod = kRouteOrderManual,
  }) {
    return recomputeRouteDay(
      day,
      serviceMinutes: serviceMinutes,
      workdayStartHour: workdayStartHour,
      learnedServiceTimes: learnedServiceTimes,
      start: start,
      legTable: legTable,
      orderMethod: orderMethod,
    );
  }

  DocumentReference<Map<String, dynamic>> _keyRefFor(RoutePlan plan) {
    final String identity = plan.salesmanUid.trim().isNotEmpty
        ? plan.salesmanUid.trim()
        : plan.salesmanCode.trim();
    return _db
        .collection('route_plan_publication_keys')
        .doc(_publicationKey(identity, _dateKey(plan.weekStart)));
  }

  static Map<String, dynamic> closedPlanFields(
    String status, {
    bool replaced = false,
  }) => <String, dynamic>{
    'status': status,
    'updatedAt': FieldValue.serverTimestamp(),
    if (replaced) 'replacedAt': FieldValue.serverTimestamp(),
    if (status == 'draft') ...<String, dynamic>{
      'approvedAt': FieldValue.delete(),
      'publishedAt': FieldValue.delete(),
    },
  };

  Future<void> _closePublishedPlan(
    WriteBatch batch,
    RoutePlan plan,
    String status, {
    bool replaced = false,
  }) async {
    final DocumentReference<Map<String, dynamic>> keyRef = _keyRefFor(plan);
    final DocumentSnapshot<Map<String, dynamic>> key = await keyRef.get();
    batch.update(
      _db.collection('route_plans').doc(plan.id),
      closedPlanFields(status, replaced: replaced),
    );
    if (key.exists && '${key.data()?['planId'] ?? ''}' == plan.id) {
      batch.update(keyRef, <String, dynamic>{
        'active': false,
        'updatedByUid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> withdrawPlan(RoutePlan plan) async {
    try {
      final WriteBatch batch = _db.batch();
      await _closePublishedPlan(batch, plan, 'draft');
      await batch.commit();
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        throw const RouteAlreadyAcceptedException();
      }
      rethrow;
    }
    await AuditLogService.instance.record(
      action: 'withdrawn',
      entityType: 'route_plan',
      entityId: plan.id,
      summary:
          'Withdrew published route for ${plan.salesmanName} '
          '(${_dateKey(plan.weekStart)}) to edit',
    );
  }

  Future<void> deleteDraftPlan(RoutePlan plan) async {
    if (plan.id.isEmpty) {
      throw StateError(
        'This draft was never saved, so there is nothing to delete.',
      );
    }
    final DocumentReference<Map<String, dynamic>> planRef = _db
        .collection('route_plans')
        .doc(plan.id);
    await _db.runTransaction<void>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(planRef);
      if (!snapshot.exists) {
        throw StateError('This route plan no longer exists.');
      }
      final String status = _text(snapshot.data()?['status']).toLowerCase();
      if (status != 'draft') {
        throw StateError(
          'Only a draft route can be deleted. This route is $status.',
        );
      }
      transaction.delete(planRef);
    });
    await AuditLogService.instance.record(
      action: 'deleted',
      entityType: 'route_plan',
      entityId: plan.id,
      summary:
          'Deleted draft route for ${plan.salesmanName} '
          '(${_dateKey(plan.weekStart)})',
    );
  }

  Future<String> replacePublishedPlan(RoutePlan plan) async {
    final String actorUid =
        FirebaseAuth.instance.currentUser?.uid ?? plan.createdByUid;
    final DocumentReference<Map<String, dynamic>> copyRef = _db
        .collection('route_plans')
        .doc();
    final RoutePlan copy = RoutePlan(
      id: copyRef.id,
      weekStart: plan.weekStart,
      weekEnd: plan.weekEnd,
      status: 'draft',
      branchId: plan.branchId,
      createdByUid: actorUid,
      createdByRole: plan.createdByRole,
      salesmanUid: plan.salesmanUid,
      salesmanCode: plan.salesmanCode,
      salesmanName: plan.salesmanName,
      source: plan.source,
      planVersion: plan.planVersion,
      isDemo: plan.isDemo,
      optimisationMethod: plan.optimisationMethod,
      days: plan.days,
      roadRouteNotes: plan.roadRouteNotes,
      startPoint: plan.startPoint,
      selectionMethod: plan.selectionMethod,
      rankingId: plan.rankingId,
      rankingWeekKey: plan.rankingWeekKey,
    );
    final WriteBatch batch = _db.batch();
    await _closePublishedPlan(batch, plan, 'archived', replaced: true);
    batch.set(copyRef, <String, dynamic>{
      ...copy.toMap(),
      'planId': copyRef.id,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    await AuditLogService.instance.record(
      action: 'replaced',
      entityType: 'route_plan',
      entityId: plan.id,
      summary:
          'Replaced started route for ${plan.salesmanName} '
          '(${_dateKey(plan.weekStart)}) with a new draft',
      metadata: <String, dynamic>{'newPlanId': copyRef.id},
    );
    return copyRef.id;
  }

  Future<void> updateStatus(String planId, String status) async {
    if (planId.isEmpty) return;
    if (status == 'published') {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await _db
          .collection('route_plans')
          .doc(planId)
          .get();
      if (!snapshot.exists || snapshot.data() == null) {
        throw StateError('The route plan no longer exists.');
      }
      await savePlan(
        RoutePlan.fromMap(planId, snapshot.data()!).copyWith(status: status),
      );
      return;
    }
    await _db.collection('route_plans').doc(planId).set(<String, dynamic>{
      ...closedPlanFields(status),
      if (status == 'draft') 'approvedByUid': FieldValue.delete(),
      if (status == 'approved') ...<String, dynamic>{
        'approvedAt': FieldValue.serverTimestamp(),
        'approvedByUid': FirebaseAuth.instance.currentUser?.uid ?? '',
      },
    }, SetOptions(merge: true));
  }

  Stream<List<Map<String, dynamic>>> watchRetailersAssignedTo({
    required String salesmanCode,
    required String salesmanUid,
    String branchId = '',
  }) {
    final List<String> ids = <String>{
      salesmanCode.trim(),
      salesmanUid.trim(),
    }.where((String id) => id.isNotEmpty).toList(growable: false);
    if (ids.isEmpty) return Stream<List<Map<String, dynamic>>>.value(const []);
    return _db
        .collection('retailers')
        .whereBranchIfProvided(branchId)
        .where('assignedSalesmanId', whereIn: ids)
        .limit(1000)
        .snapshots()
        .map(
          (QuerySnapshot<Map<String, dynamic>> snapshot) =>
              <Map<String, dynamic>>[
                for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
                    in snapshot.docs)
                  <String, dynamic>{...doc.data(), 'docId': doc.id},
              ],
        );
  }

  Future<List<RoutePlan>> loadPlansForSalesman(
    String salesmanUid, {
    String salesmanCode = '',
    String branchId = '',
    bool queryByUid = true,
    bool strict = false,
  }) async {
    final Map<String, RoutePlan> byId = <String, RoutePlan>{};

    Future<void> load(String field, String value) async {
      if (value.trim().isEmpty) return;
      try {
        final Query<Map<String, dynamic>> base = _db
            .collection('route_plans')
            .where(field, isEqualTo: value.trim())
            .whereBranchIfProvided(branchId);
        QuerySnapshot<Map<String, dynamic>> snapshot;
        try {
          snapshot = await base
              .orderBy('weekStart', descending: true)
              .limit(50)
              .get();
        } on FirebaseException catch (error) {
          if (error.code != 'failed-precondition') rethrow;
          snapshot = await base.limit(50).get();
        }
        for (final QueryDocumentSnapshot<Map<String, dynamic>> document
            in snapshot.docs) {
          byId[document.id] = RoutePlan.fromMap(document.id, document.data());
        }
      } catch (_) {
        if (strict) rethrow;
      }
    }

    await Future.wait(<Future<void>>[
      if (queryByUid) load('salesmanUid', salesmanUid),
      load('salesmanCode', salesmanCode),
    ]);
    final List<RoutePlan> plans = byId.values.toList()
      ..sort((RoutePlan a, RoutePlan b) => b.weekStart.compareTo(a.weekStart));
    return plans;
  }

  Stream<List<Map<String, dynamic>>> watchProgressForSalesman(
    String salesmanUid, {
    String salesmanCode = '',
    String branchId = '',
    bool queryByUid = true,
  }) {
    if (salesmanUid.trim().isEmpty && salesmanCode.trim().isEmpty) {
      return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
    }
    final controller = StreamController<List<Map<String, dynamic>>>();
    final sources = <String, String>{
      if (queryByUid && salesmanUid.trim().isNotEmpty)
        'salesmanUid': salesmanUid.trim(),
      if (salesmanCode.trim().isNotEmpty) 'salesmanCode': salesmanCode.trim(),
    };
    final latest = <String, List<Map<String, dynamic>>>{};
    final subscriptions = <StreamSubscription<List<Map<String, dynamic>>>>[];
    for (final entry in sources.entries) {
      final base = _db
          .collection('route_plan_progress')
          .where(entry.key, isEqualTo: entry.value)
          .whereBranchIfProvided(branchId);
      subscriptions.add(
        watchCoveredQuery(
          base.orderBy('updatedAt', descending: true).limit(100),
          probe: base.orderBy(FieldPath.documentId).limit(101),
          limit: 100,
        ).listen((rows) {
          latest[entry.key] = rows;
          if (latest.length != sources.length || controller.isClosed) return;
          final byId = <String, Map<String, dynamic>>{};
          for (final source in latest.values) {
            for (final row in source) {
              byId[row['docId'] as String] = row;
            }
          }
          final merged = byId.values.toList()
            ..sort((a, b) {
              final av = a['updatedAt'];
              final bv = b['updatedAt'];
              return av is Timestamp && bv is Timestamp ? bv.compareTo(av) : 0;
            });
          controller.add(
            CollectionRows(
              merged,
              isComplete: latest.values.every(collectionRowsComplete),
            ),
          );
        }, onError: controller.addError),
      );
    }
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  Future<Map<String, ServiceTimeStat>> loadLearnedServiceTimes({
    required String salesmanUid,
    String salesmanCode = '',
    String branchId = '',
    bool queryByUid = true,
  }) async {
    if (salesmanUid.trim().isEmpty && salesmanCode.trim().isEmpty) {
      return const <String, ServiceTimeStat>{};
    }
    final Map<String, Map<String, dynamic>> byId =
        <String, Map<String, dynamic>>{};

    Future<void> load(String field, String value) async {
      if (value.trim().isEmpty) return;
      try {
        final QuerySnapshot<Map<String, dynamic>> snapshot = await _db
            .collection('route_plan_progress')
            .where(field, isEqualTo: value.trim())
            .whereBranchIfProvided(branchId)
            .limit(100)
            .get();
        for (final QueryDocumentSnapshot<Map<String, dynamic>> document
            in snapshot.docs) {
          byId[document.id] = document.data();
        }
      } catch (_) {}
    }

    await Future.wait(<Future<void>>[
      if (queryByUid) load('salesmanUid', salesmanUid),
      load('salesmanCode', salesmanCode),
    ]);

    final List<Map<String, dynamic>> stopDocuments =
        await loadStopArrivalDocuments(
          planIds: <String>[
            for (final Map<String, dynamic> progress in byId.values)
              (progress['planId'] ?? '').toString(),
          ],
          salesmanCode: salesmanCode,
          branchId: branchId,
        );
    final Map<String, List<Map<String, dynamic>>> stopsByPlan =
        <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> stop in stopDocuments) {
      final String planId = (stop['planId'] ?? '').toString().trim();
      if (planId.isEmpty) continue;
      stopsByPlan.putIfAbsent(planId, () => <Map<String, dynamic>>[]).add(stop);
    }

    final List<StopExecutionEvent> events = <StopExecutionEvent>[
      for (final Map<String, dynamic> progress in byId.values)
        ...mapProgressDocToEvents(
          progress,
          stopDocuments:
              stopsByPlan[(progress['planId'] ?? '').toString().trim()] ??
              const <Map<String, dynamic>>[],
        ),
    ];
    return deriveServiceTimes(events);
  }

  List<_Candidate> _scoreCandidates(
    List<Map<String, dynamic>> retailers,
    LatLng? depot,
    Map<String, DateTime> lastVisitByRetailer,
  ) {
    final List<_Candidate> raw = <_Candidate>[];
    final DateTime now = DateTime.now();
    for (final Map<String, dynamic> r in retailers) {
      final LatLng? ll = readLatLng(r);
      if (ll == null) continue;
      final String id = _text(
        _first(r, const <String>[
          'docId',
          'retailerId',
          'retailer_id',
          'id',
          'code',
          'retailerCode',
          'retailer_code',
          'customerCode',
          'customer_code',
          'storeCode',
          'store_code',
        ]),
      );
      final String name = _text(
        _first(r, const <String>[
          'name',
          'retailerName',
          'retailer_name',
          'outletName',
          'store_name',
        ]),
        fallback: id.isEmpty ? 'Retailer' : id,
      );
      final DateTime? lastVisit = lastVisitByRetailer[id.trim()];
      final double overdueDays = lastVisit == null
          ? 21
          : now.difference(lastVisit).inDays.toDouble().clamp(0, 120);
      final double value = _number(
        _first(r, const <String>[
          'monthlyValue',
          'monthly_value',
          'orderValue',
          'order_value',
          'value',
          'totalSales',
          'total_sales',
        ]),
      );
      final double forecast = _number(
        _first(r, const <String>[
          'forecastDemand',
          'forecast_demand',
          'predictedDemand',
          'predicted_demand',
        ]),
      );
      raw.add(
        _Candidate(
          id: id.isEmpty ? name : id,
          name: name,
          address: _text(
            _first(r, const <String>['address', 'area', 'location']),
          ),
          position: ll,
          overdueDays: overdueDays,
          hasVisitRecord: lastVisit != null,
          value: value,
          forecast: forecast,
          region: resolveRetailerRegion(r),
          priority: retailerPriorityScore(r),
          preferredDays: retailerPreferredVisitDays(r),
          retailerCoordinateSnapshot: _text(r['docId']) == id
              ? _verifiedRetailerCoordinateSnapshot(id, r)
              : null,
        ),
      );
    }
    if (raw.isEmpty) return raw;

    double maxOverdue = 0, maxValue = 0, maxForecast = 0, maxDist = 0;
    double maxPriority = 0;
    final LatLng distanceOrigin = depot ?? _centroid(raw);
    for (final _Candidate c in raw) {
      c.distanceKm = _haversineKm(distanceOrigin, c.position);
      maxOverdue = c.overdueDays > maxOverdue ? c.overdueDays : maxOverdue;
      maxValue = c.value > maxValue ? c.value : maxValue;
      maxForecast = c.forecast > maxForecast ? c.forecast : maxForecast;
      maxDist = c.distanceKm > maxDist ? c.distanceKm : maxDist;
      maxPriority = c.priority > maxPriority ? c.priority : maxPriority;
    }
    for (final _Candidate c in raw) {
      final double nOverdue = maxOverdue == 0 ? 0 : c.overdueDays / maxOverdue;
      final double nValue = maxValue == 0 ? 0 : c.value / maxValue;
      final double nForecast = maxForecast == 0 ? 0 : c.forecast / maxForecast;
      final double nDist = maxDist == 0 ? 0 : c.distanceKm / maxDist;
      final double nPriority = maxPriority == 0 ? 0 : c.priority / maxPriority;
      c.score =
          (0.45 * nOverdue) +
          (0.25 * nForecast) +
          (0.20 * nValue) -
          (0.10 * nDist) +
          (0.30 * nPriority);
      c.reason = _reasonFor(c, nOverdue, nForecast, nValue);
    }
    raw.sort((_Candidate a, _Candidate b) => b.score.compareTo(a.score));
    return raw;
  }

  Map<String, dynamic>? _verifiedRetailerCoordinateSnapshot(
    String retailerId,
    Map<String, dynamic>? retailer,
  ) {
    if (retailer == null ||
        retailerCoordinateStatus(retailer) != CoordinateStatus.verified) {
      return null;
    }
    final LatLng? point = readLatLng(retailer);
    if (point == null || retailerId.trim().isEmpty) return null;

    final Map<String, dynamic> snapshot = <String, dynamic>{
      'latitude': point.latitude,
      'longitude': point.longitude,
      'coordinateStatus': CoordinateStatus.verified.wireValue,
    };
    for (final String key in const <String>[
      'coordinateReviewStatus',
      'coordinateSource',
      'coordinateReviewedAt',
      'coordinateReviewedByUid',
      'coordinateReviewedBy',
      'coordinateVerifiedAt',
      'coordinateVerifiedByUid',
      'coordinateVerifiedBy',
    ]) {
      if (retailer.containsKey(key) && retailer[key] != null) {
        snapshot[key] = retailer[key];
      }
    }

    final List<Object?> revisionParts = <Object?>[
      'retailer-coordinate-v1',
      retailerId.trim(),
      point.latitude,
      point.longitude,
    ];
    for (final String key in const <String>[
      'coordinateStatus',
      'coordinateReviewStatus',
      'coordinateSource',
      'coordinateReviewedAt',
      'coordinateReviewedByUid',
      'coordinateReviewedBy',
      'coordinateVerifiedAt',
      'coordinateVerifiedByUid',
      'coordinateVerifiedBy',
    ]) {
      if (snapshot.containsKey(key)) {
        revisionParts.add(<Object?>[
          key,
          _coordinateRevisionValue(snapshot[key]),
        ]);
      }
    }
    snapshot['coordinateRevision'] =
        'v1:${base64Url.encode(utf8.encode(jsonEncode(revisionParts))).replaceAll('=', '')}';
    return snapshot;
  }

  Object? _coordinateRevisionValue(Object? value) {
    if (value is Timestamp) return '${value.seconds}:${value.nanoseconds}';
    if (value is DateTime) return value.toUtc().microsecondsSinceEpoch;
    if (value is num || value is String || value is bool) return value;
    return value?.toString();
  }

  RouteDay _snapshotRouteDay(
    RouteDay day,
    Map<String, Map<String, dynamic>> retailerRecords,
  ) {
    return day.copyWith(
      stops: day.stops
          .map((RouteStop stop) {
            final Map<String, dynamic>? snapshot =
                _verifiedRetailerCoordinateSnapshot(
                  stop.retailerId,
                  retailerRecords[stop.retailerId.trim()],
                );
            return stop.copyWith(
              retailerCoordinateSnapshot: snapshot,
              clearRetailerCoordinateSnapshot: snapshot == null,
            );
          })
          .toList(growable: false),
    );
  }

  String _reasonFor(
    _Candidate c,
    double nOverdue,
    double nForecast,
    double nValue,
  ) {
    final List<String> parts = <String>[];
    if (nOverdue >= 0.6) {
      parts.add(
        c.hasVisitRecord
            ? 'overdue ${c.overdueDays.toStringAsFixed(0)}d'
            : 'No visit on record',
      );
    }
    if (nForecast >= 0.5) parts.add('high forecast demand');
    if (nValue >= 0.5) parts.add('high value');
    if (parts.isEmpty) parts.add('balances the weekly workload');
    return 'Prioritised: ${parts.join(', ')}.';
  }

  Future<RouteLegTable> _roadLegTable(
    List<_Candidate> stops,
    LatLng? start,
  ) async {
    final GeoapifyRouteMatrixResult table = await _geoapifyClient.matrix(
      <LatLng>[
        if (start != null) start,
        for (final _Candidate stop in stops) stop.position,
      ],
    );
    return RouteLegTable(
      hasStart: start != null,
      stopIds: <String>[for (final _Candidate stop in stops) stop.id],
      seconds: table.durationsSeconds,
      meters: table.distancesMeters,
    );
  }

  _OrderedDay _orderDay(
    List<_Candidate> stops,
    LatLng? start,
    RouteLegTable? table,
  ) {
    String? idOf(int node) => node == kRouteStartNode ? null : stops[node].id;
    LatLng positionOf(int node) =>
        node == kRouteStartNode ? start! : stops[node].position;
    final RouteOrderResult best = bestStopOrder(
      stopCount: stops.length,
      hasStart: start != null,
      cost: (int from, int to) => table != null
          ? table.secondsBetween(idOf(from), idOf(to))
          : _haversineKm(positionOf(from), positionOf(to)),
    );
    ({double km, int minutes}) leg(int from, int to) => routeLegBetween(
      fromStopId: idOf(from),
      from: positionOf(from),
      toStopId: idOf(to),
      to: positionOf(to),
      legTable: table,
    );
    final List<double> legKm = <double>[];
    final List<int> legMinutes = <int>[];
    for (int i = 0; i < best.order.length; i++) {
      final ({double km, int minutes}) step = i > 0
          ? leg(best.order[i - 1], best.order[i])
          : start != null
          ? leg(kRouteStartNode, best.order[i])
          : (km: 0, minutes: 0);
      legKm.add(step.km);
      legMinutes.add(step.minutes);
    }
    final ({double km, int minutes}) back =
        start != null && best.order.isNotEmpty
        ? leg(best.order.last, kRouteStartNode)
        : (km: 0, minutes: 0);
    return _OrderedDay(
      ordered: <_Candidate>[for (final int index in best.order) stops[index]],
      legKm: legKm,
      legMinutes: legMinutes,
      returnKm: back.km,
      returnMinutes: back.minutes,
      orderMethod: best.method,
      geometry: const <List<double>>[],
      estimateSource: table == null ? 'haversine_fallback' : 'geoapify_matrix',
    );
  }

  RouteDay _buildDay({
    required int dayIndex,
    required DateTime date,
    required _OrderedDay ordered,
    required int serviceMinutes,
    required int workdayStartHour,
    Map<String, int> serviceMinutesByRetailer = const <String, int>{},
  }) {
    int clock = workdayStartHour * 60;
    double totalKm = 0;
    int totalServiceMinutes = 0;
    final List<RouteStop> stops = <RouteStop>[];
    for (int i = 0; i < ordered.ordered.length; i++) {
      final _Candidate c = ordered.ordered[i];
      final double legKm = ordered.legKm[i];
      totalKm += legKm;
      final int travelMin = ordered.legMinutes[i];
      clock += travelMin;
      final String arrival = _hhmm(clock);
      final int stopServiceMinutes =
          serviceMinutesByRetailer[c.id] ?? serviceMinutes;
      clock += stopServiceMinutes;
      totalServiceMinutes += stopServiceMinutes;
      final String departure = _hhmm(clock);
      stops.add(
        RouteStop(
          stopId: _stopIdFor(dayIndex, i + 1, c.id),
          dayId: _dayIdFor(dayIndex),
          retailerId: c.id,
          retailerName: c.name,
          address: c.address,
          lat: c.position.latitude,
          lng: c.position.longitude,
          sequence: i + 1,
          arrival: arrival,
          departure: departure,
          legDistanceKm: double.parse(legKm.toStringAsFixed(2)),
          travelMinutesFromPrevious: travelMin,
          reason: c.reason,
          score: double.parse(c.score.toStringAsFixed(3)),
          retailerCoordinateSnapshot: c.retailerCoordinateSnapshot,
        ),
      );
    }
    return RouteDay(
      dayId: _dayIdFor(dayIndex),
      dayLabel: _weekdayLabel(dayIndex),
      date: date,
      stops: stops,
      totalDistanceKm: double.parse(
        (totalKm + ordered.returnKm).toStringAsFixed(2),
      ),
      estimatedServiceMinutes: totalServiceMinutes,
      estimateSource: ordered.estimateSource,
      geometry: ordered.geometry,
      geometrySource: ordered.geometrySource,
      orderMethod: ordered.orderMethod,
      returnLegDistanceKm: double.parse(ordered.returnKm.toStringAsFixed(2)),
      returnTravelMinutes: ordered.returnMinutes,
    );
  }

  double _haversineKm(LatLng a, LatLng b) =>
      _distance.as(LengthUnit.Kilometer, a, b);

  LatLng _centroid(List<_Candidate> items) {
    if (items.isEmpty) return const LatLng(3.139, 101.6869);
    double lat = 0, lng = 0;
    for (final _Candidate c in items) {
      lat += c.position.latitude;
      lng += c.position.longitude;
    }
    return LatLng(lat / items.length, lng / items.length);
  }

  DateTime _mondayOf(DateTime d) {
    final DateTime day = DateTime(d.year, d.month, d.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  String _weekdayLabel(int index) {
    const List<String> labels = <String>[
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ];
    return labels[index.clamp(0, 5)];
  }

  String _dayIdFor(int index) => _weekdayLabel(index).toLowerCase();

  static const int _maxStopIdLength = 51;

  String _stopIdFor(int dayIndex, int sequence, String retailerId) {
    final String slug = retailerId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final String prefix = '${_dayIdFor(dayIndex)}_${sequence}_';
    final String head = slug.isEmpty ? 'retailer' : slug;
    final String stopId = '$prefix$head';
    if (stopId.length <= _maxStopIdLength) return stopId;
    final String digest = _stableDigest('$prefix$head');
    final int room = _maxStopIdLength - prefix.length - digest.length - 1;
    final String kept = head.substring(0, room < 1 ? 1 : room);
    return '$prefix${kept}_$digest';
  }

  static String _stableDigest(String value) {
    int hash = 0x811c9dc5;
    for (final int unit in value.codeUnits) {
      hash = hash ^ unit;
      final int low = hash & 0xFFFF;
      final int high = hash >>> 16;
      hash =
          ((low * 0x01000193) + (((high * 0x01000193) & 0xFFFF) << 16)) &
          0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _hhmm(int minutesOfDay) {
    final int m = minutesOfDay % (24 * 60);
    final int h = m ~/ 60;
    final int min = m % 60;
    return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
  }
}

class _Candidate {
  _Candidate({
    required this.id,
    required this.name,
    required this.address,
    required this.position,
    required this.overdueDays,
    required this.hasVisitRecord,
    required this.value,
    required this.forecast,
    this.region = kUnzonedRegion,
    this.priority = 0,
    this.preferredDays = const <String>[],
    this.retailerCoordinateSnapshot,
  });

  final String id;
  final String name;
  final String address;
  final LatLng position;
  final double overdueDays;
  final bool hasVisitRecord;
  final double value;
  final double forecast;
  final String region;
  final double priority;
  final List<String> preferredDays;
  final Map<String, dynamic>? retailerCoordinateSnapshot;
  double distanceKm = 0;
  double score = 0;
  String reason = '';
}

class _OrderedDay {
  _OrderedDay({
    required this.ordered,
    required this.legKm,
    required this.legMinutes,
    required this.returnKm,
    required this.returnMinutes,
    required this.orderMethod,
    required this.geometry,
    this.geometrySource = '',
    this.estimateSource = 'haversine_fallback',
  });

  final List<_Candidate> ordered;
  final List<double> legKm;
  final List<int> legMinutes;
  final double returnKm;
  final int returnMinutes;
  final String orderMethod;
  final List<List<double>> geometry;
  final String geometrySource;
  final String estimateSource;
}

class _RoadLegs {
  _RoadLegs._(this.km, this.minutes, this.returnKm, this.returnMinutes);

  factory _RoadLegs.read(
    GeoapifyRouteResult road,
    int stopCount,
    LatLng? start,
  ) {
    final int expected = start == null ? stopCount - 1 : stopCount + 1;
    if (road.legs.length != expected) {
      throw GeoapifyRoutingException(
        'The road route has ${road.legs.length} legs, not $expected.',
      );
    }
    double kmOf(GeoapifyRouteLeg leg) => leg.meters / 1000;
    int minutesOf(GeoapifyRouteLeg leg) => (leg.seconds / 60).round();
    final List<GeoapifyRouteLeg> toStops = start == null
        ? road.legs
        : road.legs.sublist(0, stopCount);
    return _RoadLegs._(
      <double>[if (start == null) 0, ...toStops.map(kmOf)],
      <int>[if (start == null) 0, ...toStops.map(minutesOf)],
      start == null ? 0 : kmOf(road.legs.last),
      start == null ? 0 : minutesOf(road.legs.last),
    );
  }

  final List<double> km;
  final List<int> minutes;
  final double returnKm;
  final int returnMinutes;

  double get totalKm =>
      km.fold<double>(0, (double sum, double leg) => sum + leg) + returnKm;
}

extension _BranchScopedQuery on Query<Map<String, dynamic>> {
  Query<Map<String, dynamic>> whereBranchIfProvided(String branchId) {
    final String safeBranchId = branchId.trim();
    if (safeBranchId.isEmpty) return this;
    return where('branchId', isEqualTo: safeBranchId);
  }
}

Object? _first(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    if (!row.containsKey(key)) continue;
    final Object? value = row[key];
    if (value != null && value.toString().trim().isNotEmpty) return value;
  }
  return null;
}

String _text(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

double _number(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(
        value.toString().replaceAll('RM', '').replaceAll(',', '').trim(),
      ) ??
      0;
}

class RouteAlreadyAcceptedException implements Exception {
  const RouteAlreadyAcceptedException();

  @override
  String toString() =>
      'This route was already accepted or started and can no longer be edited.';
}
