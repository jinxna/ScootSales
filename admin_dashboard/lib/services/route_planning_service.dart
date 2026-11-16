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
import '../utils/firestore_query_utils.dart';
import '../utils/firestore_value_equality.dart';
import '../utils/route_regions.dart';
import '../utils/route_service_time_input.dart';
import '../utils/route_travel_time.dart';
import 'geoapify_config.dart';
import 'geoapify_route_matrix_client.dart';
import 'geoapify_routing_client.dart';

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

  static const double _fallbackSpeedKmh = kRouteFallbackSpeedKmh;

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
    LatLng? depot,
    Map<String, ServiceTimeStat> learnedServiceTimes =
        const <String, ServiceTimeStat>{},
    Map<String, DateTime> lastVisitByRetailer = const <String, DateTime>{},
  }) async {
    final DateTime monday = _mondayOf(weekStart);
    final List<_Candidate> candidates = _scoreCandidates(
      retailers,
      depot,
      lastVisitByRetailer,
    );

    final int capacity = maxPerDay * 6;
    final List<_Candidate> selected = candidates.take(capacity).toList();

    final Map<String, int> effectiveServiceMinutesByRetailer =
        buildServiceMinutesByRetailer(
          retailerIds: selected.map((_Candidate c) => c.id),
          defaultServiceMinutes: serviceMinutes,
          learnedServiceTimes: learnedServiceTimes,
        );

    final List<List<_Candidate>> buckets = assignRegionDays<_Candidate>(
      selected,
      regionOf: (_Candidate c) => c.region,
      scoreOf: (_Candidate c) => c.score,
      preferredDaysOf: (_Candidate c) => c.preferredDays,
      maxPerDay: maxPerDay,
    );

    final LatLng anchor = depot ?? _centroid(selected);

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
      late final _OrderedDay ordered;
      if (_geoapifyClient.isConfigured) {
        try {
          ordered = await _orderDayByRoad(dayStops, anchor);
        } catch (_) {
          ordered = _orderDay(dayStops, anchor);
        }
      } else {
        ordered = _orderDay(dayStops, anchor);
      }
      _OrderedDay drawn = ordered;
      if (_routingClient.isConfigured) {
        try {
          drawn = await _withRoadRoute(ordered, anchor);
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
    );
  }

  Future<RouteDay> refreshRoadGeometry(
    RouteDay day, {
    required LatLng anchor,
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
    );
    final GeoapifyRouteResult road = await _routingClient.route(<LatLng>[
      anchor,
      for (final RouteStop s in base.stops) LatLng(s.lat, s.lng),
    ]);
    int clock = workdayStartHour * 60;
    double totalKm = 0;
    final List<RouteStop> stops = <RouteStop>[];
    for (int i = 0; i < base.stops.length; i++) {
      final RouteStop s = base.stops[i];
      final double km = road.legs[i].meters / 1000;
      final int travel = (road.legs[i].seconds / 60).round();
      totalKm += km;
      clock += travel;
      final String arrival = _hhmm(clock);
      clock += _minutesOf(s.departure) - _minutesOf(s.arrival);
      stops.add(
        s.copyWith(
          arrival: arrival,
          departure: _hhmm(clock),
          legDistanceKm: double.parse(km.toStringAsFixed(2)),
          travelMinutesFromPrevious: travel,
        ),
      );
    }
    return base.copyWith(
      stops: stops,
      totalDistanceKm: double.parse(totalKm.toStringAsFixed(2)),
      geometry: simplifyRoadGeometry(road.legs),
      geometrySource: 'geoapify_route',
      estimateSource: 'geoapify_routing',
    );
  }

  static int _minutesOf(String hhmm) {
    final List<String> p = hhmm.split(':');
    return p.length < 2
        ? 0
        : (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  Future<_OrderedDay> _withRoadRoute(_OrderedDay ordered, LatLng anchor) async {
    final GeoapifyRouteResult road = await _routingClient.route(<LatLng>[
      anchor,
      for (final _Candidate c in ordered.ordered) c.position,
    ]);
    return _OrderedDay(
      ordered: ordered.ordered,
      legKm: <double>[
        for (final GeoapifyRouteLeg l in road.legs) l.meters / 1000,
      ],
      legMinutes: <int>[
        for (final GeoapifyRouteLeg l in road.legs) (l.seconds / 60).round(),
      ],
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
      if (plan.status == 'approved') 'approvedAt': FieldValue.serverTimestamp(),
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
        final DocumentSnapshot<Map<String, dynamic>> holder =
            await transaction.get(
              _db.collection('route_plans').doc(lockedPlanId),
            );
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
  }) {
    return recomputeRouteDay(
      day,
      serviceMinutes: serviceMinutes,
      workdayStartHour: workdayStartHour,
      learnedServiceTimes: learnedServiceTimes,
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
      if (status == 'approved') 'approvedAt': FieldValue.serverTimestamp(),
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
      } catch (_) {}
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
    final LatLng anchor = depot ?? _centroid(raw);
    for (final _Candidate c in raw) {
      c.distanceKm = _haversineKm(anchor, c.position);
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

  _OrderedDay _orderDay(List<_Candidate> stops, LatLng anchor) {
    if (stops.length <= 1) {
      return _OrderedDay(
        ordered: stops,
        legKm: stops.isEmpty
            ? <double>[]
            : <double>[_haversineKm(anchor, stops.first.position)],
        legMinutes: const <int>[],
        geometry: const <List<double>>[],
      );
    }

    final List<_Candidate> ordered = _nearestNeighbour(stops, anchor);
    final List<double> legKm = <double>[];
    LatLng prev = anchor;
    for (final _Candidate c in ordered) {
      legKm.add(_haversineKm(prev, c.position));
      prev = c.position;
    }
    return _OrderedDay(
      ordered: ordered,
      legKm: legKm,
      legMinutes: const <int>[],
      geometry: const <List<double>>[],
    );
  }

  Future<_OrderedDay> _orderDayByRoad(
    List<_Candidate> stops,
    LatLng anchor,
  ) async {
    final List<LatLng> coordinates = <LatLng>[
      anchor,
      for (final _Candidate stop in stops) stop.position,
    ];
    final GeoapifyRouteMatrixResult table = await _geoapifyClient.matrix(
      coordinates,
    );
    final List<int> remaining = List<int>.generate(stops.length, (int i) => i);
    final List<_Candidate> ordered = <_Candidate>[];
    final List<double> legKm = <double>[];
    final List<int> legMinutes = <int>[];
    int currentMatrixIndex = 0;
    while (remaining.isNotEmpty) {
      int best = remaining.first;
      double bestSeconds = double.infinity;
      for (final int candidate in remaining) {
        final double seconds =
            table.durationsSeconds[currentMatrixIndex][candidate + 1];
        if (seconds < bestSeconds) {
          bestSeconds = seconds;
          best = candidate;
        }
      }
      final int nextMatrixIndex = best + 1;
      ordered.add(stops[best]);
      legKm.add(
        table.distancesMeters[currentMatrixIndex][nextMatrixIndex] / 1000,
      );
      legMinutes.add((bestSeconds / 60).round());
      remaining.remove(best);
      currentMatrixIndex = nextMatrixIndex;
    }
    return _OrderedDay(
      ordered: ordered,
      legKm: legKm,
      legMinutes: legMinutes,
      geometry: const <List<double>>[],
      estimateSource: 'geoapify_matrix',
    );
  }

  List<_Candidate> _nearestNeighbour(List<_Candidate> stops, LatLng anchor) {
    final List<_Candidate> remaining = List<_Candidate>.of(stops);
    final List<_Candidate> ordered = <_Candidate>[];
    LatLng current = anchor;
    while (remaining.isNotEmpty) {
      _Candidate? best;
      double bestKm = double.infinity;
      for (final _Candidate c in remaining) {
        final double km = _haversineKm(current, c.position);
        if (km < bestKm) {
          bestKm = km;
          best = c;
        }
      }
      ordered.add(best!);
      remaining.remove(best);
      current = best.position;
    }
    return ordered;
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
      final double legKm = i < ordered.legKm.length ? ordered.legKm[i] : 0;
      totalKm += legKm;
      final int travelMin = i < ordered.legMinutes.length
          ? ordered.legMinutes[i]
          : (legKm / _fallbackSpeedKmh * 60).round();
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
      totalDistanceKm: double.parse(totalKm.toStringAsFixed(2)),
      estimatedServiceMinutes: totalServiceMinutes,
      estimateSource: ordered.estimateSource,
      geometry: ordered.geometry,
      geometrySource: ordered.geometrySource,
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
    required this.geometry,
    this.geometrySource = '',
    this.estimateSource = 'haversine_fallback',
  });

  final List<_Candidate> ordered;
  final List<double> legKm;
  final List<int> legMinutes;
  final List<List<double>> geometry;
  final String geometrySource;
  final String estimateSource;
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
