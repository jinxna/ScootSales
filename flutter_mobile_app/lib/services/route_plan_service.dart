import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'project_local_store.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/assigned_route_plan.dart';
import '../models/company_lifecycle.dart';
import '../models/route_stop_lifecycle_event.dart';
import '../models/user_model.dart';
import '../models/work_session.dart';
import '../utils/assigned_route_lifecycle.dart';
import '../utils/nearby_retailer.dart';
import '../utils/stop_arrival_identity.dart';
import '../utils/stop_arrival_payload.dart';
import '../utils/location_evidence.dart';
import 'company_api.dart';
import 'company_lifecycle_monitor.dart';
import 'held_work.dart';
import 'route_stop_outbox.dart';
import 'work_session_store.dart';

enum RouteProgressWriteState { synced, pending, needsAttention }

const String selectStopBeforeArrivalMessage =
    'Select this stop before recording an arrival.';

Future<RouteProgressWriteState> awaitRouteProgressWrite({
  required Future<void> write,
  required Future<RouteProgressWriteState?> Function() readCachedState,
  Duration wait = const Duration(seconds: 3),
}) async {
  try {
    await write.timeout(wait);
    return RouteProgressWriteState.synced;
  } on TimeoutException {
    final RouteProgressWriteState? cached = await readCachedState();
    if (cached != null) return cached;
    throw TimeoutException(
      'The route update was not confirmed locally within the expected time.',
      wait,
    );
  }
}

class RouteHeartbeatPacer {
  RouteHeartbeatPacer({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const Duration interval = Duration(minutes: 5);

  final DateTime Function() _now;
  final Map<String, DateTime> _lastSentAt = <String, DateTime>{};
  Timer? _timer;
  String _key = '';

  String get key => _key;

  void start(String key, bool Function() send) {
    if (_key == key && _timer != null) return;
    _timer?.cancel();
    _key = key;
    _schedule(key, send, _waitBeforeNext(key));
  }

  Duration _waitBeforeNext(String key) {
    final DateTime? last = _lastSentAt[key];
    if (last == null) return Duration.zero;
    final Duration wait = interval - _now().difference(last);
    if (wait.isNegative) return Duration.zero;
    return wait > interval ? interval : wait;
  }

  void _schedule(String key, bool Function() send, Duration wait) {
    _timer = Timer(wait, () {
      if (_waitBeforeNext(key) == Duration.zero && send()) {
        _lastSentAt[key] = _now();
      }
      final Duration next = _waitBeforeNext(key);
      _schedule(key, send, next == Duration.zero ? interval : next);
    });
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  void stop() {
    pause();
    _key = '';
  }
}

const int _publishedRouteReadLimit = 200;

class RoutePlanService {
  RoutePlanService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;
  late final ProjectLocalStore _store = ProjectLocalStore(
    projectId: _db.app.options.projectId,
  );
  late final WorkSessionStore _workSessions = WorkSessionStore(
    projectId: _store.projectId,
  );
  late final RouteStopOutbox _stopOutbox = RouteStopOutbox(
    projectId: _store.projectId,
  );

  Query<Map<String, dynamic>> _publishedRoutesFor(String field, String value) =>
      _db
          .collection('route_plans')
          .where(field, isEqualTo: value)
          .where('status', isEqualTo: 'published')
          .limit(_publishedRouteReadLimit);

  static Map<String, String> _routeSources(UserModel user) => <String, String>{
    'salesmanUid': user.uid.trim(),
    'salesmanCode': user.identityCode,
  }..removeWhere((String _, String value) => value.isEmpty);

  static List<AssignedRoutePlan> _usablePublishedRoutes(
    Iterable<AssignedRoutePlan> plans,
  ) =>
      plans
          .where(
            (plan) => plan.status.toLowerCase() == 'published' && !plan.isDemo,
          )
          .toList()
        ..sort((a, b) {
          final aDate = a.weekStart ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bDate = b.weekStart ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bDate.compareTo(aDate);
        });

  Future<List<AssignedRoutePlan>> readAssignedPublishedRoutesFromServer(
    UserModel user,
  ) async {
    final byId = <String, AssignedRoutePlan>{};
    var answered = false;
    FirebaseException? denied;
    for (final MapEntry<String, String> source in _routeSources(user).entries) {
      try {
        final snapshot = await _publishedRoutesFor(
          source.key,
          source.value,
        ).get(const GetOptions(source: Source.server));
        answered = true;
        for (final doc in snapshot.docs) {
          byId[doc.id] = AssignedRoutePlan.fromFirestore(doc);
        }
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
        denied ??= error;
      }
    }
    if (!answered) {
      throw denied ??
          StateError('No route identity is available for this user.');
    }
    return _usablePublishedRoutes(byId.values);
  }

  Stream<List<AssignedRoutePlan>> watchAssignedPublishedRoutes(UserModel user) {
    final current = _store.lease(user.uid);
    late final StreamController<List<AssignedRoutePlan>> controller;
    final cachedById = <String, AssignedRoutePlan>{};
    final sourceMaps = <String, Map<String, AssignedRoutePlan>>{};
    final serverSources = <String>{};
    final activeSources = <String>{};
    final subscriptions =
        <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
    Timer? saveTimer;
    List<AssignedRoutePlan>? pendingSave;

    void flushSave() {
      saveTimer?.cancel();
      saveTimer = null;
      final List<AssignedRoutePlan>? plans = pendingSave;
      pendingSave = null;
      if (plans != null && current()) {
        unawaited(_saveRouteCache(user.uid, plans));
      }
    }

    void emit({bool persist = false}) {
      if (!current()) return;
      if (activeSources.isNotEmpty &&
          serverSources.containsAll(activeSources)) {
        cachedById.clear();
      }
      final byId = <String, AssignedRoutePlan>{...cachedById};
      for (final source in sourceMaps.values) {
        byId.addAll(source);
      }
      final plans = _usablePublishedRoutes(byId.values);
      if (!controller.isClosed) controller.add(plans);
      if (persist) {
        pendingSave = plans;
        saveTimer?.cancel();
        saveTimer = Timer(const Duration(seconds: 2), flushSave);
      }
    }

    Future<void> cancelSubscriptions() async {
      for (final sub in subscriptions) {
        await sub.cancel();
      }
      subscriptions.clear();
    }

    void listenTo(String field, String value) {
      final safe = value.trim();
      if (safe.isEmpty) return;
      activeSources.add(field);
      final sub = _publishedRoutesFor(field, safe)
          .snapshots(includeMetadataChanges: true)
          .listen(
            (snapshot) {
              if (!current()) return;
              sourceMaps[field] = <String, AssignedRoutePlan>{
                for (final doc in snapshot.docs)
                  doc.id: AssignedRoutePlan.fromFirestore(doc),
              };
              if (!snapshot.metadata.isFromCache) {
                serverSources.add(field);
              }
              emit(persist: !snapshot.metadata.isFromCache);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!controller.isClosed) {
                controller.addError(error, stackTrace);
              }
            },
          );
      subscriptions.add(sub);
    }

    controller = StreamController<List<AssignedRoutePlan>>(
      onListen: () {
        _routeSources(user).forEach(listenTo);
        unawaited(
          _loadRouteCache(user.uid).then((plans) {
            if (controller.isClosed || !current()) return;
            if (activeSources.isNotEmpty &&
                serverSources.containsAll(activeSources)) {
              return;
            }
            for (final plan in plans.where((plan) => !plan.isDemo)) {
              cachedById[plan.id] = plan;
            }
            emit();
          }),
        );
      },
      onCancel: () async {
        flushSave();
        await cancelSubscriptions();
      },
    );
    return controller.stream;
  }

  Stream<RouteProgress> watchProgress({
    required String planId,
    required String salesmanUid,
  }) {
    final String canonicalId = _progressId(planId, salesmanUid);
    final StreamController<RouteProgress> controller =
        StreamController<RouteProgress>();
    QuerySnapshot<Map<String, dynamic>>? parentSnapshot;
    QuerySnapshot<Map<String, dynamic>>? stopsSnapshot;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? parentSub;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? stopsSub;

    void emit() {
      if (parentSnapshot == null ||
          stopsSnapshot == null ||
          controller.isClosed) {
        return;
      }
      final QuerySnapshot<Map<String, dynamic>> parent = parentSnapshot!;
      final QuerySnapshot<Map<String, dynamic>> stops = stopsSnapshot!;
      if (parent.docs.length > 1 ||
          (parent.docs.isNotEmpty && parent.docs.single.id != canonicalId)) {
        controller.addError(
          const FormatException('Route progress identity is inconsistent.'),
        );
        return;
      }
      final Map<String, Map<String, dynamic>> canonical =
          <String, Map<String, dynamic>>{};
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in stops.docs) {
        final Map<String, dynamic> data = doc.data();
        final String stopId = (data['stopId'] ?? '').toString().trim();
        if (stopId.isEmpty ||
            data['planId'] != planId.trim() ||
            data['salesmanUid'] != salesmanUid.trim() ||
            doc.id !=
                StopArrivalIdentity.documentId(
                  planId: planId,
                  salesmanUid: salesmanUid,
                  stopId: stopId,
                )) {
          controller.addError(
            const FormatException('Canonical stop identity is inconsistent.'),
          );
          return;
        }
        canonical[stopId] = data;
      }
      controller.add(
        RouteProgress.fromMap(
          parent.docs.isEmpty ? null : parent.docs.single.data(),
          hasPendingWrites:
              parent.metadata.hasPendingWrites ||
              stops.metadata.hasPendingWrites,
          isFromCache:
              parent.metadata.isFromCache || stops.metadata.isFromCache,
          hasDocument: parent.docs.isNotEmpty,
          canonicalStopDocuments: canonical,
        ),
      );
    }

    controller.onListen = () {
      parentSub = _db
          .collection('route_plan_progress')
          .where('salesmanUid', isEqualTo: salesmanUid.trim())
          .where('planId', isEqualTo: planId.trim())
          .limit(2)
          .snapshots(includeMetadataChanges: true)
          .listen((QuerySnapshot<Map<String, dynamic>> value) {
            parentSnapshot = value;
            emit();
          }, onError: controller.addError);
      stopsSub = _db
          .collection('route_stop_progress')
          .where('salesmanUid', isEqualTo: salesmanUid.trim())
          .where('planId', isEqualTo: planId.trim())
          .limit(100)
          .snapshots(includeMetadataChanges: true)
          .listen((QuerySnapshot<Map<String, dynamic>> value) {
            stopsSnapshot = value;
            emit();
          }, onError: controller.addError);
    };
    controller.onCancel = () async {
      await parentSub?.cancel();
      await stopsSub?.cancel();
    };
    return controller.stream;
  }

  Future<RouteProgressWriteState> acceptRoute({
    required AssignedRoutePlan plan,
    required UserModel user,
  }) {
    return _setRouteStatus(
      plan: plan,
      user: user,
      status: 'accepted',
      timestampField: 'acceptedAt',
    );
  }

  Future<RouteProgressWriteState> startRoute({
    required AssignedRoutePlan plan,
    required UserModel user,
  }) {
    return _setRouteStatus(
      plan: plan,
      user: user,
      status: 'in_progress',
      timestampField: 'startedAt',
      routeSessionState: 'active',
    );
  }

  Future<RouteProgressWriteState> completeRoute({
    required AssignedRoutePlan plan,
    required UserModel user,
  }) {
    return _setRouteStatus(
      plan: plan,
      user: user,
      status: 'completed',
      timestampField: 'completedAt',
      routeSessionState: 'completed',
    );
  }

  Future<RouteProgressWriteState> markRouteSessionActive({
    required AssignedRoutePlan plan,
    required UserModel user,
  }) {
    return _setRouteStatus(
      plan: plan,
      user: user,
      status: 'in_progress',
      timestampField: null,
      routeSessionState: 'active',
    );
  }

  Future<void> recordRouteHeartbeat({
    required AssignedRoutePlan plan,
    required UserModel user,
  }) async {
    _validatePublishedAssignedRoute(plan, user);
    await _progressRef(plan.id, user.uid).update(<String, dynamic>{
      'lastHeartbeatAt': FieldValue.serverTimestamp(),
    });
  }

  Future<RouteProgressWriteState> selectStop({
    required AssignedRoutePlan plan,
    required AssignedRouteStop stop,
    required UserModel user,
    required RouteProgress progress,
  }) async {
    _validatePublishedAssignedRoute(plan, user);
    final bool belongsToPlan = plan.days.any(
      (day) => day.stops.any((routeStop) => routeStop.stopId == stop.stopId),
    );
    if (!belongsToPlan) {
      throw StateError('The selected stop is not part of this route.');
    }
    if (isTerminalStopStatus(progress.statusFor(stop.stopId, stop.status))) {
      throw StateError('Completed or skipped stops cannot be selected.');
    }
    if (!<String>{
      'assigned',
      'accepted',
      'in_progress',
    }.contains(progress.status.trim().toLowerCase())) {
      throw StateError('This route is not available for stop selection.');
    }
    if (progress.selectedStopId == stop.stopId) {
      return progress.hasPendingWrites
          ? RouteProgressWriteState.pending
          : RouteProgressWriteState.synced;
    }

    final int nextSelectionRevision = progress.selectionRevision + 1;
    final DocumentReference<Map<String, dynamic>> reference = _progressRef(
      plan.id,
      user.uid,
    );
    final Map<String, dynamic> payload = <String, dynamic>{
      if (!progress.hasDocument) ...<String, dynamic>{
        ..._baseProgress(plan, user),
        'status': 'assigned',
        'stopProgress': <String, dynamic>{},
        'handledStopIds': <String>[],
      },
      'selectedStopId': stop.stopId,
      'selectionRevision': FieldValue.increment(1),
      'updatedAt': FieldValue.serverTimestamp(),
      'lastSyncedAt': FieldValue.serverTimestamp(),
    };
    return _writeProgress(
      reference: reference,
      payload: payload,
      isApplied: (Map<String, dynamic> data) =>
          data['selectedStopId'] == stop.stopId &&
          data['selectionRevision'] == nextSelectionRevision,
    );
  }

  Future<RouteProgressWriteState> clearStopSelection({
    required AssignedRoutePlan plan,
    required UserModel user,
    required RouteProgress progress,
  }) async {
    _validatePublishedAssignedRoute(plan, user);
    if (progress.selectedStopId.isEmpty) {
      return progress.hasPendingWrites
          ? RouteProgressWriteState.pending
          : RouteProgressWriteState.synced;
    }
    if (!progress.hasDocument) {
      throw StateError(
        'The selected destination has no route progress record.',
      );
    }

    final int nextSelectionRevision = progress.selectionRevision + 1;
    final DocumentReference<Map<String, dynamic>> reference = _progressRef(
      plan.id,
      user.uid,
    );
    return _writeProgress(
      reference: reference,
      payload: <String, dynamic>{
        'selectedStopId': FieldValue.delete(),
        'selectionRevision': nextSelectionRevision,
        'updatedAt': FieldValue.serverTimestamp(),
        'lastSyncedAt': FieldValue.serverTimestamp(),
      },
      isApplied: (Map<String, dynamic> data) =>
          !data.containsKey('selectedStopId') &&
          data['selectionRevision'] == nextSelectionRevision,
    );
  }

  Future<RouteProgressWriteState> updateStopStatus({
    required AssignedRoutePlan plan,
    required AssignedRouteStop stop,
    required UserModel user,
    required RouteProgress progress,
    required String status,
    String? skipReason,
    String? notes,
    StopArrivalEvidence? arrivalEvidence,
  }) async {
    _validatePublishedAssignedRoute(plan, user);
    if (!<String>{'arrived', 'completed', 'skipped'}.contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    if (!plan.stops.any(
      (AssignedRouteStop item) => item.stopId == stop.stopId,
    )) {
      throw StateError('The stop is not part of this published route.');
    }
    if (status == 'arrived' && arrivalEvidence == null) {
      throw ArgumentError('Arrival updates require location evidence.');
    }
    final String uid = user.uid.trim();
    if (!_store.isActive(uid)) {
      throw StateError('The signed-in account changed. Sign in again.');
    }
    final WorkSession? session = await _workSessions.read(uid);
    if (session == null ||
        !session.isAcknowledged ||
        session.endPendingSync ||
        session.sessionId.isEmpty) {
      throw StateError('An acknowledged active work session is required.');
    }
    return _stopOutbox.serializeSession<RouteProgressWriteState>(
      session,
      () async {
        final List<RouteStopLifecycleEvent> queued = await _stopOutbox
            .readForUid(uid, planId: plan.id);
        final RouteStopLifecycleEvent? retry = queued
            .cast<RouteStopLifecycleEvent?>()
            .firstWhere(
              (RouteStopLifecycleEvent? event) =>
                  event != null &&
                  event.stopId == stop.stopId &&
                  event.status == status,
              orElse: () => null,
            );
        if (retry != null) {
          return _flushStopEvent(
            retry,
            plan: plan,
            stop: stop,
            user: user,
            progress: progress,
            allowNeedsAttention: true,
          );
        }
        final List<RouteStopLifecycleEvent> earlier = queued
            .where(
              (RouteStopLifecycleEvent event) =>
                  event.stopId == stop.stopId &&
                  event.state != RouteStopOutboxState.needsAttention,
            )
            .toList(growable: false);
        if (earlier.any(
          (RouteStopLifecycleEvent event) =>
              event.status == 'completed' || event.status == 'skipped',
        )) {
          throw StateError(
            'This stop is already finished and waiting to upload.',
          );
        }

        _validateLocalTransition(
          status,
          stop.stopId,
          progress,
          queuedArrival: earlier.any(
            (RouteStopLifecycleEvent event) => event.status == 'arrived',
          ),
        );
        final String cleanSkipReason = (skipReason ?? '').trim();
        if (status == 'skipped' && cleanSkipReason.isEmpty) {
          throw ArgumentError('A skip reason is required.');
        }
        final Map<String, dynamic> facts = <String, dynamic>{};
        RetailerCoordinateSnapshot? arrivalCoordinates;
        Future<_StopServerState?>? preloadedServer;
        if (status == 'arrived') {
          final StopArrivalEvidence evidence = arrivalEvidence!;
          if (evidence.isVerified) {
            final DeviceLocationFix? fix = evidence.fix;
            if (fix == null || !isReliableArrivalFix(fix)) {
              throw StateError(
                'The GPS fix is stale or outside the accuracy limit.',
              );
            }
            final String referenceMode = evidence.coordinateReferenceMode;
            if (referenceMode == 'published_snapshot_offline') {
              arrivalCoordinates = stop.retailerCoordinateSnapshot;
              if (arrivalCoordinates == null ||
                  !arrivalCoordinates.isVerified ||
                  evidence.retailerCoordinateRevision !=
                      arrivalCoordinates.coordinateRevision ||
                  evidence.retailerCoordinateSource !=
                      arrivalCoordinates.coordinateSource ||
                  evidence.coordinateSnapshotAt == null ||
                  arrivalCoordinates.referenceTime(plan.publishedAt) == null ||
                  !evidence.coordinateSnapshotAt!.isAtSameMomentAs(
                    arrivalCoordinates.referenceTime(plan.publishedAt)!,
                  )) {
                throw StateError(
                  'The verified published coordinate snapshot is unavailable.',
                );
              }
            } else if (referenceMode == 'current_retailer') {
              preloadedServer = _readStopServerState(
                plan: plan,
                user: user,
                stop: stop,
              );
              preloadedServer.ignore();
              arrivalCoordinates = await _readCurrentVerifiedCoordinates(stop);
              final RetailerCoordinateSnapshot? published =
                  stop.retailerCoordinateSnapshot;
              if (published != null &&
                  (!published.isVerified ||
                      published.coordinateRevision !=
                          arrivalCoordinates.coordinateRevision ||
                      published.latitude != arrivalCoordinates.latitude ||
                      published.longitude != arrivalCoordinates.longitude)) {
                throw StateError(
                  'The retailer coordinates changed since publication.',
                );
              }
              if (evidence.retailerCoordinateRevision !=
                      arrivalCoordinates.coordinateRevision ||
                  evidence.retailerCoordinateSource !=
                      arrivalCoordinates.coordinateSource) {
                throw StateError('The retailer coordinate evidence is stale.');
              }
            } else {
              throw StateError(
                'Verified arrival has no valid coordinate reference.',
              );
            }
            final double distance = distanceToStopMeters(
              currentLat: fix.latitude,
              currentLng: fix.longitude,
              stopLat: arrivalCoordinates.latitude!,
              stopLng: arrivalCoordinates.longitude!,
            )!;
            if (distance > kArrivalMaxDistanceMeters ||
                evidence.distanceMeters == null ||
                (evidence.distanceMeters! - distance).abs() > 1) {
              throw StateError(
                'The GPS fix is outside the 75 m arrival boundary.',
              );
            }
          }
          facts.addAll(StopArrivalPayload.occurrenceFields(evidence: evidence));
        } else {
          if (cleanSkipReason.isNotEmpty) facts['skipReason'] = cleanSkipReason;
          final String cleanNotes = (notes ?? '').trim();
          if (cleanNotes.isNotEmpty) facts['notes'] = cleanNotes;
        }

        final WorkSession sequenced = await _workSessions
            .nextRouteStopEventSequence(
              uid: uid,
              sessionId: session.sessionId,
              generation: session.generation,
            );
        final DateTime occurredAt = status == 'arrived'
            ? arrivalEvidence!.fix?.capturedAt.toUtc() ?? DateTime.now().toUtc()
            : DateTime.now().toUtc();
        final RouteStopLifecycleEvent event = RouteStopLifecycleEvent(
          uid: uid,
          planId: plan.id,
          stopId: stop.stopId,
          workSessionId: sequenced.sessionId,
          workSessionGeneration: sequenced.generation,
          sessionEventSequence: sequenced.lastRouteStopEventSequence,
          eventId: _stopEventId(sequenced.sessionId, stop.stopId, status),
          status: status,
          deviceOccurredAt: occurredAt,
          payload: facts,
          expectedSelectedStopId: progress.selectedStopId,
          expectedSelectionRevision: progress.selectionRevision,
          sessionDeviceStartedAt: sequenced.deviceStartedAt,
        );
        await _stopOutbox.put(event);
        if (earlier.isNotEmpty) return RouteProgressWriteState.pending;
        return _flushStopEvent(
          event,
          plan: plan,
          stop: stop,
          user: user,
          progress: progress,
          knownSession: sequenced,
          preloadedServer: preloadedServer,
        );
      },
    );
  }

  Future<void> resumePendingStopEvents({
    required AssignedRoutePlan plan,
    required UserModel user,
    required RouteProgress progress,
  }) async {
    if (progress.isFromCache || !_store.isActive(user.uid)) {
      return;
    }
    final List<RouteStopLifecycleEvent> events = await _stopOutbox.readForUid(
      user.uid,
      planId: plan.id,
    );
    final Set<String> blockedStops = <String>{};
    for (final RouteStopLifecycleEvent event in events) {
      if (blockedStops.contains(event.stopId)) continue;
      final AssignedRouteStop? stop = plan.stops
          .where((AssignedRouteStop item) => item.stopId == event.stopId)
          .cast<AssignedRouteStop?>()
          .firstWhere(
            (AssignedRouteStop? item) => item != null,
            orElse: () => null,
          );
      if (stop == null) {
        await _markStopEventAttention(
          event,
          'The assigned stop is no longer in the route.',
        );
        continue;
      }
      await _stopOutbox.serializeSession<void>(
        WorkSession(
          uid: event.uid,
          sessionId: event.workSessionId,
          generation: event.workSessionGeneration,
          lastFixSequence: 0,
          lastRouteStopEventSequence: event.sessionEventSequence,
          status: WorkSessionLocalStatus.active,
        ),
        () async {
          final RouteProgressWriteState written = await _flushStopEvent(
            event,
            plan: plan,
            stop: stop,
            user: user,
            progress: progress,
            requireServerRead: true,
          );
          if (written != RouteProgressWriteState.synced) {
            blockedStops.add(event.stopId);
          }
        },
      );
    }
  }

  Future<bool> sendWaitingStopEvents({
    required String uid,
    required UserModel? user,
    required WorkSession session,
  }) async {
    bool waiting(RouteStopLifecycleEvent event) =>
        event.workSessionId == session.sessionId &&
        event.workSessionGeneration == session.generation &&
        event.state == RouteStopOutboxState.pending;
    final List<RouteStopLifecycleEvent> events = (await _stopOutbox.readForUid(
      uid,
    )).where(waiting).toList(growable: false);
    if (events.isEmpty) return true;
    if (user == null || user.uid.trim() != uid || !_store.isActive(uid)) {
      return false;
    }
    final Map<String, AssignedRoutePlan>? plans = await _plansForStopEvents(
      user,
      events.map((RouteStopLifecycleEvent event) => event.planId).toSet(),
    );
    if (plans == null) return false;
    final RouteProgress serverOnly = RouteProgress.fromMap(null);
    final Set<String> blockedStops = <String>{};
    for (final RouteStopLifecycleEvent event in events) {
      final String stopKey = '${event.planId}|${event.stopId}';
      if (blockedStops.contains(stopKey)) continue;
      final AssignedRoutePlan? plan = plans[event.planId];
      final AssignedRouteStop? stop = plan?.stops
          .where((AssignedRouteStop item) => item.stopId == event.stopId)
          .cast<AssignedRouteStop?>()
          .firstWhere(
            (AssignedRouteStop? item) => item != null,
            orElse: () => null,
          );
      if (plan == null || stop == null) {
        await _holdOrNeedsAttention(
          event,
          'The assigned stop is no longer in the route.',
        );
        continue;
      }
      final RouteProgressWriteState written = await _stopOutbox
          .serializeSession<RouteProgressWriteState>(
            session,
            () => _flushStopEvent(
              event,
              plan: plan,
              stop: stop,
              user: user,
              progress: serverOnly,
              requireServerRead: true,
            ),
          );
      if (written == RouteProgressWriteState.pending &&
          (await _stopOutbox.readForUid(uid)).any(
            (RouteStopLifecycleEvent row) =>
                row.eventId == event.eventId && waiting(row),
          )) {
        blockedStops.add(stopKey);
      }
    }
    return !(await _stopOutbox.readForUid(uid)).any(waiting);
  }

  Future<Map<String, AssignedRoutePlan>?> _plansForStopEvents(
    UserModel user,
    Set<String> planIds,
  ) async {
    final Map<String, AssignedRoutePlan> plans = <String, AssignedRoutePlan>{
      for (final AssignedRoutePlan plan in await _loadRouteCache(user.uid))
        if (planIds.contains(plan.id)) plan.id: plan,
    };
    if (plans.keys.toSet().containsAll(planIds)) return plans;
    try {
      for (final AssignedRoutePlan plan
          in await readAssignedPublishedRoutesFromServer(
            user,
          ).timeout(const Duration(seconds: 6))) {
        if (planIds.contains(plan.id)) plans[plan.id] = plan;
      }
    } on TimeoutException {
      return null;
    } on FirebaseException catch (error) {
      if (_isOfflineError(error)) return null;
      if (error.code != 'permission-denied') rethrow;
    }
    return plans;
  }

  Future<String?> stopEventAttentionReason({
    required AssignedRoutePlan plan,
    required UserModel user,
    required String stopId,
  }) async {
    final List<RouteStopLifecycleEvent> events = await _stopOutbox.readForUid(
      user.uid,
      planId: plan.id,
    );
    for (final RouteStopLifecycleEvent event in events) {
      if (event.stopId == stopId &&
          event.state == RouteStopOutboxState.needsAttention) {
        return event.lastError;
      }
    }
    return null;
  }

  Future<RouteProgressWriteState> retryPendingStopEvents({
    required AssignedRoutePlan plan,
    required UserModel user,
    required RouteProgress progress,
  }) async {
    if (!_store.isActive(user.uid)) {
      throw StateError('The signed-in account changed. Sign in again.');
    }
    final List<RouteStopLifecycleEvent> events = await _stopOutbox.readForUid(
      user.uid,
      planId: plan.id,
    );
    if (events.isEmpty) return RouteProgressWriteState.synced;
    RouteProgressWriteState result = RouteProgressWriteState.synced;
    final Set<String> blockedStops = <String>{};
    for (RouteStopLifecycleEvent event in events) {
      if (blockedStops.contains(event.stopId)) continue;
      final AssignedRouteStop? stop = plan.stops
          .where((AssignedRouteStop item) => item.stopId == event.stopId)
          .cast<AssignedRouteStop?>()
          .firstWhere(
            (AssignedRouteStop? item) => item != null,
            orElse: () => null,
          );
      if (stop == null) {
        await _markStopEventAttention(
          event,
          'The assigned stop is no longer in the route.',
        );
        result = RouteProgressWriteState.needsAttention;
        blockedStops.add(event.stopId);
        continue;
      }
      if (event.state == RouteStopOutboxState.needsAttention) {
        event = event.copyWith(
          state: RouteStopOutboxState.pending,
          lastError: '',
        );
        await _stopOutbox.update(event);
      }
      final WorkSession lockSession = WorkSession(
        uid: event.uid,
        sessionId: event.workSessionId,
        generation: event.workSessionGeneration,
        lastFixSequence: 0,
        lastRouteStopEventSequence: event.sessionEventSequence,
        status: WorkSessionLocalStatus.active,
      );
      final RouteProgressWriteState written = await _stopOutbox
          .serializeSession<RouteProgressWriteState>(
            lockSession,
            () => _flushStopEvent(
              event,
              plan: plan,
              stop: stop,
              user: user,
              progress: progress,
              requireServerRead: true,
              allowNeedsAttention: true,
            ),
          );
      if (written != RouteProgressWriteState.synced) {
        blockedStops.add(event.stopId);
        if (result != RouteProgressWriteState.needsAttention) result = written;
      }
    }
    return result;
  }

  Future<RouteProgressWriteState> _flushStopEvent(
    RouteStopLifecycleEvent event, {
    required AssignedRoutePlan plan,
    required AssignedRouteStop stop,
    required UserModel user,
    required RouteProgress progress,
    bool requireServerRead = false,
    bool allowNeedsAttention = false,
    WorkSession? knownSession,
    Future<_StopServerState?>? preloadedServer,
  }) async {
    final current = _store.lease(user.uid);
    if (!current()) return RouteProgressWriteState.pending;
    if (event.state == RouteStopOutboxState.needsAttention &&
        !allowNeedsAttention) {
      return RouteProgressWriteState.needsAttention;
    }
    final String uid = user.uid.trim();
    if (event.uid != uid ||
        event.planId != plan.id ||
        event.stopId != stop.stopId ||
        !_store.isActive(uid)) {
      return _markStopEventAttention(
        event,
        'The authenticated account no longer owns this event.',
      );
    }
    final CompanyLifecycle? knownLifecycle =
        CompanyLifecycleMonitor.instance.lifecycle;
    if (knownLifecycle != null &&
        HeldWorkPolicy.routeForStopEvent(
              knownLifecycle,
              sessionStartedAt: event.sessionStartedAtForHeldWork,
              now: DateTime.now().toUtc(),
            ) !=
            HeldRoute.direct) {
      return _holdStopEvent(event);
    }
    final WorkSession? localSession =
        knownSession ?? await _workSessions.read(uid);
    if (!current()) return RouteProgressWriteState.pending;
    final bool currentSession =
        localSession != null &&
        localSession.sessionId == event.workSessionId &&
        localSession.generation == event.workSessionGeneration &&
        (localSession.isAcknowledged
            ? !localSession.endPendingSync
            : localSession.generation > 0 &&
                  localSession.status == WorkSessionLocalStatus.ended &&
                  localSession.endPendingSync);
    final _StopServerState? server;
    try {
      server = preloadedServer != null
          ? await preloadedServer
          : await _readStopServerState(plan: plan, user: user, stop: stop);
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      if (!current()) return RouteProgressWriteState.pending;
      return await _heldOrUndecided(event, error) ??
          await _markStopEventAttention(
            event,
            HeldWorkPolicy.rejectionText('not_on_plan', companyOpen: true),
          );
    }
    if (!current()) return RouteProgressWriteState.pending;
    if (requireServerRead && server == null) {
      return RouteProgressWriteState.pending;
    }
    final Map<String, dynamic>? serverCanonical = server?.canonical;
    final Map<String, dynamic>? canonical =
        serverCanonical ?? progress.canonicalStopFor(stop.stopId);
    if (canonical != null && _canonicalMatchesEvent(canonical, event)) {
      if (serverCanonical == null || server!.canonicalHasPendingWrites) {
        return RouteProgressWriteState.pending;
      }
      await _stopOutbox.remove(event);
      return RouteProgressWriteState.synced;
    }
    if (!currentSession) {
      return _holdOrNeedsAttention(
        event,
        'The originating work session was superseded before recording.',
      );
    }
    if (server != null && !_serverSessionMatches(server.session, event)) {
      return _holdOrNeedsAttention(
        event,
        'The active server work session changed.',
      );
    }
    final Map<String, dynamic> storedParent =
        server?.parent ?? progress.rawData;
    final bool startsRoute = storedParent['status'] == 'accepted';
    final Map<String, dynamic> parent = startsRoute
        ? <String, dynamic>{
            ...storedParent,
            'status': 'in_progress',
            'routeSessionState': 'active',
          }
        : storedParent;
    if (server != null && !_serverRouteMatches(server.route, plan, user)) {
      return _markStopEventAttention(
        event,
        'The published route assignment changed.',
      );
    }
    try {
      _validateTransitionAgainstState(event, parent, canonical, progress);
    } on StateError catch (error) {
      return _markStopEventAttention(event, error.message);
    }

    final int selectionRevision = _nonNegativeInt(parent['selectionRevision']);
    final String selectedStopId = (parent['selectedStopId'] ?? '').toString();
    RouteStopLifecycleEvent attempt = event.copyWith(
      expectedSelectedStopId: selectedStopId,
      expectedSelectionRevision: selectionRevision,
    );
    if (!current()) return RouteProgressWriteState.pending;
    if (attempt.expectedSelectedStopId != event.expectedSelectedStopId ||
        attempt.expectedSelectionRevision != event.expectedSelectionRevision) {
      await _stopOutbox.update(attempt);
    }
    if (!current()) return RouteProgressWriteState.pending;
    final Map<String, dynamic> stopPayload = _buildCanonicalStopPayload(
      attempt,
      plan: plan,
      stop: stop,
      user: user,
      prior: canonical,
      parent: parent,
    );
    final Map<String, dynamic> parentPayload = _buildParentProjection(
      attempt,
      plan: plan,
      user: user,
      parent: parent,
    );
    final String stopDocId = StopArrivalIdentity.documentId(
      planId: plan.id,
      salesmanUid: uid,
      stopId: stop.stopId,
    );
    final DocumentReference<Map<String, dynamic>> stopRef = _db
        .collection('route_stop_progress')
        .doc(stopDocId);
    final DocumentReference<Map<String, dynamic>> parentRef = _progressRef(
      plan.id,
      uid,
    );
    final WriteBatch batch = _db.batch();
    batch.set(stopRef, stopPayload);
    batch.set(parentRef, parentPayload, SetOptions(merge: true));
    try {
      if (startsRoute) {
        await parentRef
            .set(<String, dynamic>{
              ..._baseProgress(plan, user),
              'status': 'in_progress',
              'routeSessionState': 'active',
              'startedAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
              'lastSyncedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 5));
        if (!current()) return RouteProgressWriteState.pending;
      }
      await batch.commit().timeout(const Duration(seconds: 5));
      if (!current()) return RouteProgressWriteState.pending;
      await _stopOutbox.remove(attempt);
      return RouteProgressWriteState.synced;
    } on TimeoutException {
      return RouteProgressWriteState.pending;
    } on FirebaseException catch (error) {
      if (!current()) return RouteProgressWriteState.pending;
      if (_isOfflineError(error)) {
        return RouteProgressWriteState.pending;
      }
      if (error.code == 'permission-denied') {
        final RouteProgressWriteState? kept = await _heldOrUndecided(
          attempt,
          error,
        );
        if (kept != null) return kept;
        final _StopServerState? refreshed;
        try {
          refreshed = await _readStopServerState(
            plan: plan,
            user: user,
            stop: stop,
          );
        } on FirebaseException catch (readError) {
          if (readError.code != 'permission-denied') rethrow;
          return _markStopEventAttention(
            attempt,
            HeldWorkPolicy.rejectionText('not_on_plan', companyOpen: true),
          );
        }
        if (!current()) return RouteProgressWriteState.pending;
        if (refreshed != null &&
            _nonNegativeInt(refreshed.parent['selectionRevision']) !=
                attempt.expectedSelectionRevision) {
          if (attempt.selectionRebaseCount >= 3 ||
              !_serverSessionMatches(refreshed.session, attempt) ||
              !_serverRouteMatches(refreshed.route, plan, user) ||
              !_transitionCanStillApply(
                attempt,
                refreshed.parent,
                refreshed.canonical,
                progress,
              )) {
            return _markStopEventAttention(
              attempt,
              'Selection changed repeatedly or another transition precondition changed.',
            );
          }
          attempt = attempt.copyWith(
            expectedSelectedStopId: (refreshed.parent['selectedStopId'] ?? '')
                .toString(),
            expectedSelectionRevision: _nonNegativeInt(
              refreshed.parent['selectionRevision'],
            ),
            selectionRebaseCount: attempt.selectionRebaseCount + 1,
          );
          await _stopOutbox.update(attempt);
          return _flushStopEvent(
            attempt,
            plan: plan,
            stop: stop,
            user: user,
            progress: progress,
            requireServerRead: true,
          );
        }
        return _markStopEventAttention(
          attempt,
          'The company did not accept this stop update. Ask your administrator.',
        );
      }
      rethrow;
    }
  }

  Future<_StopServerState?> _readStopServerState({
    required AssignedRoutePlan plan,
    required UserModel user,
    required AssignedRouteStop stop,
  }) async {
    final String stopId = StopArrivalIdentity.documentId(
      planId: plan.id,
      salesmanUid: user.uid,
      stopId: stop.stopId,
    );
    try {
      final List<DocumentSnapshot<Map<String, dynamic>>> snapshots =
          await Future.wait(<Future<DocumentSnapshot<Map<String, dynamic>>>>[
            _db
                .collection('route_plans')
                .doc(plan.id)
                .get(const GetOptions(source: Source.server)),
            _progressRef(
              plan.id,
              user.uid,
            ).get(const GetOptions(source: Source.server)),
            _db
                .collection('route_stop_progress')
                .doc(stopId)
                .get(const GetOptions(source: Source.server)),
            _db
                .collection('live_tracking')
                .doc(user.uid)
                .get(const GetOptions(source: Source.server)),
          ]).timeout(const Duration(seconds: 6));
      return _StopServerState(
        route: snapshots[0].data() ?? <String, dynamic>{},
        parent: snapshots[1].data() ?? <String, dynamic>{},
        canonical: snapshots[2].data(),
        canonicalHasPendingWrites: snapshots[2].metadata.hasPendingWrites,
        session: snapshots[3].data() ?? <String, dynamic>{},
      );
    } on FirebaseException catch (error) {
      if (_isOfflineError(error)) return null;
      if (error.code == 'permission-denied' &&
          CompanyLifecycleMonitor.instance.paused) {
        return null;
      }
      rethrow;
    } on TimeoutException {
      return null;
    }
  }

  Future<RetailerCoordinateSnapshot> _readCurrentVerifiedCoordinates(
    AssignedRouteStop stop,
  ) async {
    if (stop.retailerId.trim().isEmpty) {
      throw StateError('The route stop has no retailer identity.');
    }
    final DocumentSnapshot<Map<String, dynamic>> retailer;
    try {
      retailer = await _db
          .collection('retailers')
          .doc(stop.retailerId.trim())
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 6));
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      throw StateError(
        'This retailer record is not in your branch or assigned to you, so its coordinates cannot be checked. Ask your admin to set the retailer branch.',
      );
    }
    final Map<String, dynamic>? data = retailer.data();
    if (!retailer.exists || data == null) {
      throw StateError('The canonical retailer record is unavailable.');
    }
    final RetailerCoordinateSnapshot? current =
        RetailerCoordinateSnapshot.fromRetailerRecord(stop.retailerId, data);
    if (current == null || !current.isVerified) {
      throw StateError('The current retailer coordinates are not verified.');
    }
    return current;
  }

  void _validateLocalTransition(
    String status,
    String stopId,
    RouteProgress progress, {
    bool queuedArrival = false,
  }) {
    final String oldStatus = queuedArrival
        ? 'arrived'
        : progress.statusFor(stopId, 'not_started').toLowerCase();
    if (status == 'arrived' && progress.selectedStopId != stopId) {
      throw StateError(selectStopBeforeArrivalMessage);
    }
    if (status == 'arrived' &&
        oldStatus != 'not_started' &&
        oldStatus != 'pending') {
      throw StateError('Only a pending stop can be marked arrived.');
    }
    if (status == 'completed' && oldStatus != 'arrived') {
      throw StateError(
        'A stop must have accepted arrival evidence before completion.',
      );
    }
    if (status == 'skipped' &&
        !<String>{'not_started', 'pending', 'arrived'}.contains(oldStatus)) {
      throw StateError('A terminal stop cannot be skipped again.');
    }
  }

  void _validateTransitionAgainstState(
    RouteStopLifecycleEvent event,
    Map<String, dynamic> parent,
    Map<String, dynamic>? canonical,
    RouteProgress progress,
  ) {
    final String canonicalStatus = (canonical?['status'] ?? '')
        .toString()
        .toLowerCase();
    final Object? nestedProgress = parent['stopProgress'];
    final Object? nestedStop = nestedProgress is Map
        ? nestedProgress[event.stopId]
        : null;
    final String parentStatus = nestedStop is Map
        ? (nestedStop['status'] ?? '').toString().toLowerCase()
        : '';
    final String status = canonicalStatus.isNotEmpty
        ? canonicalStatus
        : parentStatus.isNotEmpty
        ? parentStatus
        : 'not_started';
    if (status == 'completed' || status == 'skipped') {
      throw StateError('The stop already has a terminal state.');
    }
    if (event.status == 'arrived' &&
        status != 'not_started' &&
        status != 'pending') {
      throw StateError('The stop is no longer pending.');
    }
    if (event.status == 'arrived' &&
        (parent['selectedStopId'] ?? '').toString() != event.stopId) {
      throw StateError('The stop is no longer selected for arrival.');
    }
    if (event.status == 'completed' && status != 'arrived') {
      final Object? nested = parent['stopProgress'];
      final Object? raw = nested is Map ? nested[event.stopId] : null;
      if (raw is! Map || raw['status'] != 'arrived') {
        throw StateError('Completion requires a prior accepted arrival.');
      }
    }
    if (event.status == 'skipped' &&
        !<String>{'not_started', 'pending', 'arrived'}.contains(status)) {
      throw StateError(
        'The stop cannot move to skipped from its current state.',
      );
    }
    if (event.workSessionGeneration <
        _nonNegativeInt(parent['lastSummaryWorkSessionGeneration'])) {
      throw StateError(
        'An unrecorded event from a superseded generation cannot sync.',
      );
    }
  }

  bool _transitionCanStillApply(
    RouteStopLifecycleEvent event,
    Map<String, dynamic> parent,
    Map<String, dynamic>? canonical,
    RouteProgress progress,
  ) {
    try {
      _validateTransitionAgainstState(event, parent, canonical, progress);
      return true;
    } on StateError {
      return false;
    }
  }

  Map<String, dynamic> _buildCanonicalStopPayload(
    RouteStopLifecycleEvent event, {
    required AssignedRoutePlan plan,
    required AssignedRouteStop stop,
    required UserModel user,
    required Map<String, dynamic>? prior,
    required Map<String, dynamic> parent,
  }) {
    final Map<String, dynamic> data = <String, dynamic>{
      if (prior != null) ...prior,
      'lifecycleSchemaVersion': 2,
      'planId': plan.id,
      'salesmanUid': user.uid,
      'salesmanCode': user.identityCode,
      'branchId': plan.branchId,
      'stopId': stop.stopId,
      'retailerId': stop.retailerId,
      'retailerName': stop.retailerName,
      'status': event.status,
      'eventId': event.eventId,
      'workSessionId': event.workSessionId,
      'workSessionGeneration': event.workSessionGeneration,
      'sessionEventSequence': event.sessionEventSequence,
      'deviceOccurredAt': Timestamp.fromDate(event.deviceOccurredAt),
      'receivedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (event.status == 'arrived') {
      final Timestamp occurred = Timestamp.fromDate(event.deviceOccurredAt);
      data.addAll(<String, dynamic>{
        'arrivedAt': occurred,
        'arrivalEventId': event.eventId,
        'arrivalWorkSessionId': event.workSessionId,
        'arrivalWorkSessionGeneration': event.workSessionGeneration,
        'arrivalSessionEventSequence': event.sessionEventSequence,
        'arrivalDeviceOccurredAt': occurred,
        'arrivalReceivedAt': FieldValue.serverTimestamp(),
      });
      for (final MapEntry<String, dynamic> entry in event.payload.entries) {
        data[entry.key] = _firestoreFact(entry.key, entry.value);
      }
    } else if (event.status == 'completed') {
      data['completedAt'] = Timestamp.fromDate(event.deviceOccurredAt);
      _importLegacyArrivalIfNeeded(data, parent, event.stopId);
    } else {
      data['skippedAt'] = Timestamp.fromDate(event.deviceOccurredAt);
      data.addAll(event.payload);
      _importLegacyArrivalIfNeeded(data, parent, event.stopId);
    }
    return data;
  }

  void _importLegacyArrivalIfNeeded(
    Map<String, dynamic> target,
    Map<String, dynamic> parent,
    String stopId,
  ) {
    if (target.containsKey('arrivalMode')) return;
    final Object? rawStops = parent['stopProgress'];
    final Object? rawEntry = rawStops is Map ? rawStops[stopId] : null;
    if (rawEntry is! Map || rawEntry['status'] != 'arrived') return;
    final Object? rawEvidence = rawEntry['arrivalEvidence'];
    if (rawEvidence is Map) {
      target['legacyArrivalEvidence'] = Map<String, dynamic>.from(rawEvidence);
      if (rawEvidence['mode'] != null) {
        target['arrivalMode'] = rawEvidence['mode'];
      }
      if (rawEvidence['failureCode'] != null) {
        target['arrivalFailureCode'] = rawEvidence['failureCode'];
      }
      if (rawEvidence['overrideReasonCode'] != null) {
        target['overrideReasonCode'] = rawEvidence['overrideReasonCode'];
      }
      if (rawEvidence['overrideNote'] != null) {
        target['overrideNote'] = rawEvidence['overrideNote'];
      }
      for (final String key in const <String>[
        'latitude',
        'longitude',
        'accuracyMeters',
        'distanceMeters',
        'isMocked',
      ]) {
        if (rawEvidence.containsKey(key)) {
          final String field = switch (key) {
            'latitude' => 'arrivalLatitude',
            'longitude' => 'arrivalLongitude',
            'accuracyMeters' => 'arrivalAccuracyMeters',
            'distanceMeters' => 'arrivalDistanceMeters',
            'isMocked' => 'arrivalIsMocked',
            _ => key,
          };
          target[field] = rawEvidence[key];
        }
      }
      if (rawEvidence['deviceCapturedAt'] != null) {
        target['arrivalDeviceCapturedAt'] = rawEvidence['deviceCapturedAt'];
      }
    }
    if (rawEntry['arrivedAt'] != null) {
      target['arrivedAt'] = rawEntry['arrivedAt'];
    }
  }

  Map<String, dynamic> _buildParentProjection(
    RouteStopLifecycleEvent event, {
    required AssignedRoutePlan plan,
    required UserModel user,
    required Map<String, dynamic> parent,
  }) {
    final int oldGeneration = _nonNegativeInt(
      parent['lastSummaryWorkSessionGeneration'],
    );
    final int oldSequence = _nonNegativeInt(parent['lastSummaryEventSequence']);
    final bool newer =
        event.workSessionGeneration > oldGeneration ||
        (event.workSessionGeneration == oldGeneration &&
            event.sessionEventSequence > oldSequence);
    final Object? rawHandled = parent['handledStopIds'];
    final Set<String> handled = rawHandled is List
        ? rawHandled.whereType<String>().toSet()
        : <String>{};
    if (event.status == 'completed' || event.status == 'skipped') {
      handled.add(event.stopId);
    }
    final bool routeComplete =
        plan.stops.isNotEmpty &&
        plan.stops.every(
          (AssignedRouteStop item) => handled.contains(item.stopId),
        );
    final bool closesRoute = parent['status'] != 'completed' && routeComplete;
    final Map<String, dynamic> patch = <String, dynamic>{
      ..._baseProgress(plan, user),
      'status': parent['status'] == 'completed' || routeComplete
          ? 'completed'
          : 'in_progress',
      if (closesRoute &&
          const <String>{
            'active',
            'paused',
          }.contains(parent['routeSessionState']))
        'routeSessionState': 'completed',
      'lastStopWriteStopId': event.stopId,
      'lastStopWriteStatus': event.status,
      'lastStopWriteEventId': event.eventId,
      'lastStopWriteWorkSessionGeneration': event.workSessionGeneration,
      'lastStopWriteSequence': event.sessionEventSequence,
      'updatedAt': FieldValue.serverTimestamp(),
      'lastSyncedAt': FieldValue.serverTimestamp(),
    };
    if (newer) {
      patch.addAll(<String, dynamic>{
        'lastStopId': event.stopId,
        'lastStopStatus': event.status,
        'lastStopEventId': event.eventId,
        'lastSummaryWorkSessionGeneration': event.workSessionGeneration,
        'lastSummaryEventSequence': event.sessionEventSequence,
      });
    }
    if (event.status == 'completed' || event.status == 'skipped') {
      patch['handledStopIds'] = FieldValue.arrayUnion(<String>[event.stopId]);
    }
    final int revision = _nonNegativeInt(parent['selectionRevision']);
    if ((event.status == 'completed' || event.status == 'skipped') &&
        (parent['selectedStopId'] ?? '').toString() == event.stopId &&
        revision == event.expectedSelectionRevision &&
        event.expectedSelectedStopId == event.stopId) {
      patch['selectedStopId'] = FieldValue.delete();
      patch['selectionRevision'] = revision + 1;
    }
    return patch;
  }

  bool _canonicalMatchesEvent(
    Map<String, dynamic> canonical,
    RouteStopLifecycleEvent event,
  ) {
    if (canonical['lifecycleSchemaVersion'] != 2 ||
        canonical['status'] != event.status ||
        canonical['eventId'] != event.eventId ||
        canonical['workSessionId'] != event.workSessionId ||
        canonical['workSessionGeneration'] != event.workSessionGeneration ||
        canonical['sessionEventSequence'] != event.sessionEventSequence ||
        !_sameInstant(canonical['deviceOccurredAt'], event.deviceOccurredAt)) {
      return false;
    }
    return event.payload.entries.every(
      (MapEntry<String, dynamic> entry) => _sameFirestoreValue(
        canonical[entry.key],
        _firestoreFact(entry.key, entry.value),
      ),
    );
  }

  bool _serverSessionMatches(
    Map<String, dynamic> session,
    RouteStopLifecycleEvent event,
  ) =>
      session['uid'] == event.uid &&
      session['workSessionStatus'] == 'active' &&
      session['activeSessionId'] == event.workSessionId &&
      session['activeSessionGeneration'] == event.workSessionGeneration;

  bool _serverRouteMatches(
    Map<String, dynamic> route,
    AssignedRoutePlan plan,
    UserModel user,
  ) {
    final Object? rawIds = route['stopIds'];
    final List<String> stopIds = rawIds is List
        ? rawIds.whereType<String>().toList(growable: false)
        : <String>[];
    final String owner = (route['salesmanUid'] ?? route['salesman_uid'] ?? '')
        .toString();
    final String code = (route['salesmanCode'] ?? route['salesman_code'] ?? '')
        .toString();
    return route['status'] == 'published' &&
        route['planId'] == plan.id &&
        (owner == user.uid || (code.isNotEmpty && code == user.identityCode)) &&
        route['branchId'] == plan.branchId &&
        stopIds.toSet().containsAll(
          plan.stops.map((AssignedRouteStop item) => item.stopId),
        );
  }

  Future<RouteProgressWriteState> _holdStopEvent(
    RouteStopLifecycleEvent event,
  ) async {
    if (event.state != RouteStopOutboxState.held) {
      await _stopOutbox.update(
        event.copyWith(state: RouteStopOutboxState.held, lastError: ''),
      );
    }
    unawaited(CompanyLifecycleMonitor.instance.refresh());
    return RouteProgressWriteState.pending;
  }

  Future<RouteProgressWriteState?> _heldOrUndecided(
    RouteStopLifecycleEvent event,
    FirebaseException refusal,
  ) async {
    final CompanyLifecycle? lifecycle = await CompanyLifecycleMonitor.instance
        .refresh(upload: false);
    if (HeldWorkPolicy.classify(refusal, lifecycle?.access) ==
        WriteFailure.held) {
      return _holdStopEvent(event);
    }
    if (lifecycle == null && CompanyApi.instance.enabled) {
      return RouteProgressWriteState.pending;
    }
    if (HeldWorkPolicy.pauseIsLanding(lifecycle)) {
      return RouteProgressWriteState.pending;
    }
    return null;
  }

  Future<RouteProgressWriteState> _holdOrNeedsAttention(
    RouteStopLifecycleEvent event,
    String reason,
  ) async {
    final CompanyLifecycle? lifecycle =
        CompanyLifecycleMonitor.instance.lifecycle ??
        await CompanyLifecycleMonitor.instance.refresh(upload: false);
    if (lifecycle?.cutAt != null) return _holdStopEvent(event);
    return _markStopEventAttention(event, reason);
  }

  Future<RouteProgressWriteState> _markStopEventAttention(
    RouteStopLifecycleEvent event,
    String reason,
  ) async {
    await _stopOutbox.update(
      event.copyWith(
        state: RouteStopOutboxState.needsAttention,
        lastError: reason,
      ),
    );
    return RouteProgressWriteState.needsAttention;
  }

  String _stopEventId(String sessionId, String stopId, String status) {
    final String value = '${sessionId}_${stopId}_$status';
    if (!StopArrivalIdentity.isAcceptableEventId(value)) {
      throw StateError('The work-session event identity is too long.');
    }
    return value;
  }

  bool _isOfflineError(FirebaseException error) => const <String>{
    'unavailable',
    'deadline-exceeded',
    'cancelled',
  }.contains(error.code);

  int _nonNegativeInt(Object? value) =>
      value is num && value.toInt() >= 0 ? value.toInt() : 0;

  Object? _firestoreFact(String key, Object? value) {
    if (value is String &&
        (key == 'arrivalDeviceCapturedAt' ||
            key == 'coordinateSnapshotAt' ||
            key == 'coordinateCheckedAt')) {
      final DateTime? parsed = DateTime.tryParse(value);
      if (parsed != null) return Timestamp.fromDate(parsed.toUtc());
    }
    return value;
  }

  bool _sameInstant(Object? value, DateTime expected) {
    final DateTime? actual = value is Timestamp
        ? value.toDate().toUtc()
        : value is DateTime
        ? value.toUtc()
        : null;
    return actual != null && actual.isAtSameMomentAs(expected.toUtc());
  }

  bool _sameFirestoreValue(Object? actual, Object? expected) {
    if (actual is Timestamp && expected is Timestamp) {
      return actual.toDate().isAtSameMomentAs(expected.toDate());
    }
    if (actual is Map && expected is Map) {
      return jsonEncode(actual) == jsonEncode(expected);
    }
    return actual == expected;
  }

  Future<void> openStopInGoogleMaps(
    AssignedRouteStop stop, {
    DeviceLocationFix? originFix,
  }) async {
    final Map<String, String> parameters = <String, String>{
      'api': '1',
      'travelmode': 'driving',
    };
    if (_hasUsableCoordinates(stop.lat, stop.lng)) {
      parameters['destination'] = '${stop.lat},${stop.lng}';
    } else {
      final String address = stop.address.trim();
      if (address.isEmpty || address.length > 500) return;
      parameters['destination'] = address;
    }
    if (originFix != null && isReliableArrivalFix(originFix)) {
      parameters['origin'] = '${originFix.latitude},${originFix.longitude}';
    }
    final Uri uri = Uri.https('www.google.com', '/maps/dir/', parameters);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> openDayInGoogleMaps(List<AssignedRouteStop> stops) async {
    final usable = stops
        .where(
          (AssignedRouteStop stop) => _hasUsableCoordinates(stop.lat, stop.lng),
        )
        .toList();
    if (usable.isEmpty) return;
    if (usable.length == 1) {
      await openStopInGoogleMaps(usable.first);
      return;
    }
    final origin = usable.first;
    final destination = usable.length > 8 ? usable[8] : usable.last;
    final waypoints = usable
        .skip(1)
        .take(usable.length > 8 ? 7 : usable.length - 2)
        .map((stop) => '${stop.lat},${stop.lng}')
        .join('|');
    final Uri uri = Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'origin': '${origin.lat},${origin.lng}',
      'destination': '${destination.lat},${destination.lng}',
      if (waypoints.isNotEmpty) 'waypoints': waypoints,
      'travelmode': 'driving',
    });
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  bool _hasUsableCoordinates(double latitude, double longitude) =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      !(latitude == 0 && longitude == 0);

  Future<RouteProgressWriteState> _setRouteStatus({
    required AssignedRoutePlan plan,
    required UserModel user,
    required String status,
    required String? timestampField,
    String? routeSessionState,
  }) async {
    if (status == 'in_progress' &&
        !canStartAssignedRoute('accepted', routeStart: plan.weekStart)) {
      throw StateError('This route cannot be started before its start date.');
    }
    final DocumentReference<Map<String, dynamic>> reference = _progressRef(
      plan.id,
      user.uid,
    );
    final Map<String, dynamic> payload = <String, dynamic>{
      ..._baseProgress(plan, user),
      'status': status,
      'routeSessionState': ?routeSessionState,
      if (status == 'accepted') ...<String, dynamic>{
        'stopProgress': <String, dynamic>{},
        'handledStopIds': <String>[],
      },
      ?timestampField: FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'lastSyncedAt': FieldValue.serverTimestamp(),
    };
    return _writeProgress(
      reference: reference,
      payload: payload,
      isApplied: (Map<String, dynamic> data) =>
          data['status'] == status &&
          (routeSessionState == null ||
              data['routeSessionState'] == routeSessionState),
    );
  }

  Future<RouteProgressWriteState> _writeProgress({
    required DocumentReference<Map<String, dynamic>> reference,
    required Map<String, dynamic> payload,
    required bool Function(Map<String, dynamic> data) isApplied,
  }) {
    final Future<void> write = reference.set(payload, SetOptions(merge: true));
    return awaitRouteProgressWrite(
      write: write,
      readCachedState: () async {
        final DocumentSnapshot<Map<String, dynamic>> cached = await reference
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 1));
        final Map<String, dynamic>? data = cached.data();
        if (!cached.exists || data == null || !isApplied(data)) return null;
        return cached.metadata.hasPendingWrites
            ? RouteProgressWriteState.pending
            : RouteProgressWriteState.synced;
      },
    );
  }

  Map<String, dynamic> _baseProgress(AssignedRoutePlan plan, UserModel user) {
    final progressId = _progressId(plan.id, user.uid);
    return {
      'progressId': progressId,
      'planId': plan.id,
      'salesmanUid': user.uid,
      'salesmanCode': user.identityCode,
      'branchId': plan.branchId,
      'isOfflineCreated': false,
    };
  }

  void _validatePublishedAssignedRoute(AssignedRoutePlan plan, UserModel user) {
    if (plan.status.trim().toLowerCase() != 'published' ||
        plan.isDemo ||
        user.uid.trim().isEmpty) {
      throw StateError('Only a published assigned route can be selected.');
    }
    final String identityCode = user.identityCode;
    final bool assignedToUser =
        plan.salesmanUid.trim() == user.uid.trim() ||
        (identityCode.isNotEmpty && plan.salesmanCode.trim() == identityCode);
    if (!assignedToUser) {
      throw StateError('This route is not assigned to the signed-in user.');
    }
  }

  DocumentReference<Map<String, dynamic>> _progressRef(
    String planId,
    String salesmanUid,
  ) {
    return _db
        .collection('route_plan_progress')
        .doc(_progressId(planId, salesmanUid));
  }

  String _progressId(String planId, String salesmanUid) {
    return '${planId}_$salesmanUid'.replaceAll('/', '_');
  }

  Future<List<AssignedRoutePlan>> _loadRouteCache(String uid) async {
    try {
      final encoded = await _store.read(
        uid,
        'assigned_routes',
        legacyKey: _routeCacheKey(uid),
      );
      if (encoded == null || encoded.isEmpty) {
        return const <AssignedRoutePlan>[];
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return const <AssignedRoutePlan>[];
      return decoded
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .map(
            (row) => AssignedRoutePlan.fromMap(
              (row['planId'] ?? '').toString(),
              row,
            ),
          )
          .where((plan) => plan.id.isNotEmpty && !plan.isDemo)
          .toList(growable: false);
    } catch (_) {
      return const <AssignedRoutePlan>[];
    }
  }

  static final Map<String, String> _lastRouteCacheWrite = <String, String>{};

  Future<void> _saveRouteCache(
    String uid,
    List<AssignedRoutePlan> plans,
  ) async {
    try {
      final String encoded = jsonEncode(
        plans.take(30).map((plan) => plan.toCacheMap()).toList(growable: false),
      );
      final String memoKey = _store.key(uid, 'assigned_routes');
      if (_lastRouteCacheWrite[memoKey] == encoded) return;
      await _store.write(uid, 'assigned_routes', encoded);
      _lastRouteCacheWrite[memoKey] = encoded;
    } catch (_) {}
  }

  String _routeCacheKey(String uid) => 'assigned_route_cache_v1_$uid';
}

class _StopServerState {
  const _StopServerState({
    required this.route,
    required this.parent,
    required this.canonical,
    required this.canonicalHasPendingWrites,
    required this.session,
  });

  final Map<String, dynamic> route;
  final Map<String, dynamic> parent;
  final Map<String, dynamic>? canonical;
  final bool canonicalHasPendingWrites;
  final Map<String, dynamic> session;
}
