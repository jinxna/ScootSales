import 'dart:async';
import 'dart:convert';

import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:fmcg_sales/main.dart' as app;
import 'package:fmcg_sales/models/assigned_route_plan.dart';
import 'package:fmcg_sales/models/route_stop_lifecycle_event.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/models/work_session.dart';
import 'package:fmcg_sales/providers/auth_provider.dart';
import 'package:fmcg_sales/providers/gps_provider.dart';
import 'package:fmcg_sales/services/route_plan_service.dart';
import 'package:fmcg_sales/services/route_stop_outbox.dart';
import 'package:fmcg_sales/services/work_session_store.dart';
import 'package:fmcg_sales/utils/nearby_retailer.dart';
import 'package:fmcg_sales/utils/stop_arrival_identity.dart';

const String _routePlanId = 'route-arrival-acceptance-e2e';
const String _stopAId = 'arrival-stop-a';
const String _stopBId = 'arrival-stop-b';
const String _stopCId = 'arrival-stop-c';
const String _workSessionId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const String _stopAName = 'QA Arrival Retailer A';
const String _stopBName = 'QA Arrival Retailer B';

const double _retailerBLatitude = 1.5535;
const double _retailerBLongitude = 110.3593;

class _ControlledGeolocatorPlatform extends GeolocatorPlatform {
  final StreamController<Position> _positions =
      StreamController<Position>.broadcast(sync: true);
  final StreamController<ServiceStatus> _serviceStatuses =
      StreamController<ServiceStatus>.broadcast(sync: true);
  late Position _latest = _position(
    latitude: _retailerBLatitude + 0.01,
    longitude: _retailerBLongitude,
    accuracyMeters: 5,
    isMocked: true,
  );

  bool get hasPositionListener => _positions.hasListener;

  void emit(Position position) {
    _latest = position;
    if (_positions.hasListener) _positions.add(position);
  }

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => _latest;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async => _latest;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      _positions.stream;

  @override
  Stream<ServiceStatus> getServiceStatusStream() => _serviceStatuses.stream;

  @override
  Future<LocationAccuracyStatus> getLocationAccuracy() async =>
      LocationAccuracyStatus.precise;

  Future<void> dispose() async {
    await _positions.close();
    await _serviceStatuses.close();
  }
}

Position _position({
  required double latitude,
  required double longitude,
  required double accuracyMeters,
  int ageSeconds = 0,
  bool isMocked = false,
}) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: DateTime.now().toUtc().subtract(Duration(seconds: ageSeconds)),
  accuracy: accuracyMeters,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
  isMocked: isMocked,
);

double _longitudeAtDistance(double meters) {
  double low = 0;
  double high = 0.01;
  for (int index = 0; index < 60; index++) {
    final double offset = (low + high) / 2;
    final double distance = distanceToStopMeters(
      currentLat: _retailerBLatitude,
      currentLng: _retailerBLongitude + offset,
      stopLat: _retailerBLatitude,
      stopLng: _retailerBLongitude,
    )!;
    if (distance <= meters) {
      low = offset;
    } else {
      high = offset;
    }
  }
  return _retailerBLongitude + low;
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required Duration timeout,
  required String label,
  void Function()? onTimeout,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  onTimeout?.call();
  fail('Timed out waiting for $label.');
}

Future<void> _tapEnabledButton(
  WidgetTester tester,
  String label, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final Finder buttons = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (Widget widget) =>
          widget is ButtonStyleButton && widget.onPressed != null,
    ),
  );
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (buttons.evaluate().isEmpty) continue;
    final Finder button = buttons.first;
    await _bringOnScreen(tester, button);
    await tester.tap(button);
    return;
  }
  fail('Timed out waiting for the $label button to be enabled.');
}

Future<void> _bringOnScreen(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  final Finder outer = find.byType(NestedScrollView).first;
  for (int step = 0; step < 8; step++) {
    final double bottom = tester.getBottomLeft(outer).dy;
    if (tester.getCenter(finder).dy <= bottom - 24) return;
    await tester.drag(outer, const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void _traceStage(String stage) {
  // ignore: avoid_print
  print('ROUTE_ARRIVAL_STAGE $stage');
}

String _stopDocumentId(String uid, String stopId) =>
    StopArrivalIdentity.documentId(
      planId: _routePlanId,
      salesmanUid: uid,
      stopId: stopId,
    );

Future<Map<String, dynamic>> _readPublishedRoute() async {
  final DocumentSnapshot<Map<String, dynamic>> snapshot =
      await FirebaseFirestore.instance
          .collection('route_plans')
          .doc(_routePlanId)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
  expect(snapshot.exists, isTrue, reason: 'Local route fixture is required.');
  return snapshot.data()!;
}

Future<Map<String, dynamic>?> _readParentIfPresent(String uid) async {
  final QuerySnapshot<Map<String, dynamic>> snapshot = await FirebaseFirestore
      .instance
      .collection('route_plan_progress')
      .where('planId', isEqualTo: _routePlanId)
      .where('salesmanUid', isEqualTo: uid)
      .limit(2)
      .get(const GetOptions(source: Source.server))
      .timeout(const Duration(seconds: 10));
  if (snapshot.docs.isEmpty) return null;
  expect(snapshot.docs, hasLength(1));
  return snapshot.docs.single.data();
}

Future<Map<String, dynamic>> _readParent(String uid) async {
  final Map<String, dynamic>? parent = await _readParentIfPresent(uid);
  expect(parent, isNotNull);
  return parent!;
}

Future<Map<String, dynamic>?> _readCanonical(
  String uid,
  String stopId, {
  bool requireAcknowledged = false,
}) async {
  final DocumentSnapshot<Map<String, dynamic>> snapshot =
      await FirebaseFirestore.instance
          .collection('route_stop_progress')
          .doc(_stopDocumentId(uid, stopId))
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
  if (requireAcknowledged &&
      (snapshot.metadata.hasPendingWrites || snapshot.metadata.isFromCache)) {
    return null;
  }
  return snapshot.data();
}

Future<RouteProgress> _readRouteProgress(
  WidgetTester tester,
  String uid,
) async {
  final RouteProgress? progress = await tester.runAsync(() async {
    final Map<String, dynamic> parent = await _readParent(uid);
    final Map<String, Map<String, dynamic>> canonical =
        <String, Map<String, dynamic>>{};
    for (final String stopId in <String>[_stopAId, _stopBId, _stopCId]) {
      final Map<String, dynamic>? stop = await _readCanonical(uid, stopId);
      if (stop != null) canonical[stopId] = stop;
    }
    return RouteProgress.fromMap(
      parent,
      hasDocument: true,
      canonicalStopDocuments: canonical,
    );
  });
  return progress!;
}

Future<Map<String, dynamic>> _waitForCanonicalStatus(
  WidgetTester tester,
  String uid,
  String stopId,
  String expectedStatus,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 45));
  Map<String, dynamic>? latest;
  while (DateTime.now().isBefore(deadline)) {
    latest = await tester.runAsync<Map<String, dynamic>?>(
      () => _readCanonical(uid, stopId, requireAcknowledged: true),
    );
    if (latest?['status'] == expectedStatus) return latest!;
    await tester.pump(const Duration(milliseconds: 350));
  }
  fail('Canonical stop did not reach the expected lifecycle state.');
}

Future<Map<String, dynamic>> _waitForParentStatus(
  WidgetTester tester,
  String uid,
  String expectedStatus,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
  Map<String, dynamic>? latest;
  while (DateTime.now().isBefore(deadline)) {
    latest = await tester.runAsync<Map<String, dynamic>?>(
      () => _readParentIfPresent(uid),
    );
    if (latest?['status'] == expectedStatus) return latest!;
    await tester.pump(const Duration(milliseconds: 350));
  }
  fail('Route progress did not reach the expected status.');
}

void _emitPosition({
  required _ControlledGeolocatorPlatform platform,
  required double metersFromRetailer,
  required double accuracyMeters,
  int ageSeconds = 0,
}) {
  platform.emit(
    _position(
      latitude: _retailerBLatitude,
      longitude: _longitudeAtDistance(metersFromRetailer),
      accuracyMeters: accuracyMeters,
      ageSeconds: ageSeconds,
    ),
  );
}

Future<void> _rejectArrival(
  WidgetTester tester, {
  required _ControlledGeolocatorPlatform platform,
  required String uid,
  required int buttonOccurrence,
  required double distanceMeters,
  required double accuracyMeters,
  bool captureScreenshot = false,
  int ageSeconds = 0,
}) async {
  _emitPosition(
    platform: platform,
    metersFromRetailer: distanceMeters,
    accuracyMeters: accuracyMeters,
    ageSeconds: ageSeconds,
  );
  final Finder markArrivedButtons = find.widgetWithText(
    OutlinedButton,
    'Mark arrived',
  );
  final Finder markArrivedButton = markArrivedButtons.at(buttonOccurrence);
  await _bringOnScreen(tester, markArrivedButton);
  await tester.pump(const Duration(milliseconds: 300));
  _traceStage('arrival_button_tap_started');
  await tester.tap(markArrivedButton);
  _traceStage('arrival_button_tap_returned');
  _traceStage('arrival_rejection_wait_started');
  await _waitFor(
    tester,
    find.text('Arrival not verified'),
    timeout: const Duration(seconds: 15),
    label: 'the rejected GPS arrival dialog',
  );
  _traceStage('arrival_rejection_dialog_visible_${distanceMeters.toInt()}m');
  if (captureScreenshot) {
    await tester.pump(const Duration(milliseconds: 500));
    _traceStage('arrival_rejection_screenshot_ready');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 8)),
    );
  }
  final Map<String, dynamic>? canonicalBeforeConfirmation = await tester
      .runAsync<Map<String, dynamic>?>(() => _readCanonical(uid, _stopBId));
  expect(canonicalBeforeConfirmation, isNull);
  _traceStage('arrival_rejection_no_write_confirmed');
  await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'confirms the selected arrival and syncs an out-of-order stop exactly once',
    (WidgetTester tester) async {
      const bool useFirebaseEmulator = bool.fromEnvironment(
        'USE_FIREBASE_EMULATOR',
      );
      const String firebaseEmulatorHost = String.fromEnvironment(
        'FIREBASE_EMULATOR_HOST',
      );
      expect(useFirebaseEmulator, isTrue);
      expect(firebaseEmulatorHost, '10.0.2.2');

      final _ControlledGeolocatorPlatform platform =
          _ControlledGeolocatorPlatform();
      final GeolocatorPlatform originalGeolocator = GeolocatorPlatform.instance;
      GeolocatorPlatform.instance = platform;
      addTearDown(() async {
        GeolocatorPlatform.instance = originalGeolocator;
        await FirebaseFirestore.instance.enableNetwork();
        await FirebaseFirestore.instance.waitForPendingWrites().timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        );
        await platform.dispose();
      });

      app.main();
      await tester.pump(const Duration(seconds: 2));
      final Finder quickSignIn = find.text('Salesperson');
      final Finder assignedRouteEntry = find.descendant(
        of: find.byType(ScootBottomNav),
        matching: find.text('Route'),
      );
      final DateTime loginDeadline = DateTime.now().add(
        const Duration(seconds: 60),
      );
      while (DateTime.now().isBefore(loginDeadline) &&
          quickSignIn.evaluate().isEmpty &&
          assignedRouteEntry.evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      if (quickSignIn.evaluate().isNotEmpty) {
        await tester.tap(quickSignIn.first);
      }
      await _waitFor(
        tester,
        assignedRouteEntry,
        timeout: const Duration(seconds: 90),
        label: 'the authenticated salesperson home',
        onTimeout: () {
          final AuthProvider auth = Provider.of<AuthProvider>(
            tester.element(find.byType(app.AuthWrapper)),
            listen: false,
          );
          final UserModel? user = auth.user;
          debugPrint(
            'ROUTE_ARRIVAL_AUTH_DIAGNOSTIC '
            'status=${auth.status.name} '
            'initialising=${auth.initialising} '
            'logged_in=${auth.isLoggedIn} '
            'firebase_user=${FirebaseAuth.instance.currentUser != null} '
            'salesperson=${user?.hasSalespersonRole ?? false} '
            'active=${user?.hasActiveAccount ?? false}',
          );
        },
      );
      _traceStage('authenticated_home');
      final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      expect(uid, isNotEmpty);
      final BuildContext homeContext = tester.element(assignedRouteEntry.first);
      if (!homeContext.mounted) fail('home unmounted');
      final AuthProvider auth = Provider.of<AuthProvider>(
        homeContext,
        listen: false,
      );
      final UserModel user = auth.user!;
      final GpsProvider gps = Provider.of<GpsProvider>(
        homeContext,
        listen: false,
      );
      await gps.setTrackingEnabled(true);
      await const WorkSessionStore().write(
        WorkSession(
          uid: uid,
          sessionId: _workSessionId,
          generation: 1,
          lastFixSequence: 0,
          status: WorkSessionLocalStatus.active,
        ),
      );
      expect(platform.hasPositionListener, isFalse);
      _traceStage('work_session_fixture_ready');

      final Map<String, dynamic> routeBefore = await _readPublishedRoute();
      expect(routeBefore['status'], 'published');
      expect(routeBefore['stopIds'], <String>[_stopAId, _stopBId, _stopCId]);
      final AssignedRoutePlan plan = AssignedRoutePlan.fromMap(
        _routePlanId,
        routeBefore,
      );
      final AssignedRouteStop stopB = plan.stops.singleWhere(
        (AssignedRouteStop stop) => stop.stopId == _stopBId,
      );

      await tester.tap(assignedRouteEntry.first);
      await _waitFor(
        tester,
        find.text(_stopAName),
        timeout: const Duration(seconds: 60),
        label: 'the first published stop',
      );
      await _waitFor(
        tester,
        find.text(_stopBName),
        timeout: const Duration(seconds: 30),
        label: 'stop B',
      );
      _traceStage('published_route_loaded');
      if (!gps.trackingEnabled) {
        await gps.setTrackingEnabled(true);
        _traceStage('location_sharing_turned_on');
      }
      final Finder startWork = find.widgetWithText(OutlinedButton, 'Start');
      final DateTime startDeadline = DateTime.now().add(
        const Duration(seconds: 30),
      );
      while (!gps.hasArrivalReadySession &&
          startWork.evaluate().isEmpty &&
          DateTime.now().isBefore(startDeadline)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      _traceStage(
        gps.hasArrivalReadySession
            ? 'work_session_already_ready'
            : 'start_work_visible_${startWork.evaluate().length}',
      );
      if (!gps.hasArrivalReadySession) await _tapEnabledButton(tester, 'Start');
      final DateTime workDeadline = DateTime.now().add(
        const Duration(seconds: 30),
      );
      while (!gps.hasArrivalReadySession &&
          DateTime.now().isBefore(workDeadline)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(gps.hasArrivalReadySession, isTrue);
      _traceStage('work_session_started');
      await _tapEnabledButton(tester, 'Accept route');
      Map<String, dynamic> parent = await _waitForParentStatus(
        tester,
        uid,
        'accepted',
      );
      _traceStage('route_accepted');
      await tester.pump(const Duration(milliseconds: 300));
      await _tapEnabledButton(tester, 'Start route');
      parent = await _waitForParentStatus(tester, uid, 'in_progress');
      _traceStage('route_started');
      final DateTime heartbeatDeadline = DateTime.now().add(
        const Duration(seconds: 20),
      );
      while (DateTime.now().isBefore(heartbeatDeadline) &&
          !(parent['routeSessionState'] == 'active' &&
              parent['lastHeartbeatAt'] is Timestamp)) {
        await tester.pump(const Duration(milliseconds: 500));
        parent = await _readParent(uid);
      }
      expect(parent['routeSessionState'], 'active');
      expect(parent['lastHeartbeatAt'], isA<Timestamp>());
      _traceStage('route_heartbeat_written');

      final Finder selectButtons = find.text('Go to this stop');
      expect(selectButtons, findsNWidgets(3));
      await tester.ensureVisible(selectButtons.at(1));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(selectButtons.at(1));
      await tester.pump(const Duration(milliseconds: 300));
      final DateTime selectionDeadline = DateTime.now().add(
        const Duration(seconds: 20),
      );
      while (DateTime.now().isBefore(selectionDeadline)) {
        parent = await _readParent(uid);
        if (parent['selectedStopId'] == _stopBId &&
            parent['selectionRevision'] == 1) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(parent['selectedStopId'], _stopBId);
      expect(parent['selectionRevision'], 1);
      final bool selectedBBeforeA = parent['selectedStopId'] == _stopBId;
      _traceStage('stop_b_selected');

      await _rejectArrival(
        tester,
        platform: platform,
        uid: uid,
        buttonOccurrence: 1,
        distanceMeters: 76,
        accuracyMeters: 24,
        captureScreenshot: true,
      );
      _traceStage('distance_76_rejected');
      await _rejectArrival(
        tester,
        platform: platform,
        uid: uid,
        buttonOccurrence: 1,
        distanceMeters: 74,
        accuracyMeters: 26,
      );
      _traceStage('accuracy_26_rejected');
      await _rejectArrival(
        tester,
        platform: platform,
        uid: uid,
        buttonOccurrence: 1,
        distanceMeters: 74,
        accuracyMeters: 24,
        ageSeconds: 31,
      );
      _traceStage('stale_fix_rejected');
      await _rejectArrival(
        tester,
        platform: platform,
        uid: uid,
        buttonOccurrence: 1,
        distanceMeters: 75,
        accuracyMeters: 24,
      );
      _traceStage('distance_75_rejected');
      expect(await _readCanonical(uid, _stopBId), isNull);
      parent = await _readParent(uid);
      expect(parent['lastStopId'], isNot(_stopBId));
      _emitPosition(
        platform: platform,
        metersFromRetailer: kArrivalMaxDistanceMeters,
        accuracyMeters: 25,
      );
      final Finder stopBArrivalButton = find
          .widgetWithText(OutlinedButton, 'Mark arrived')
          .at(1);
      await _bringOnScreen(tester, stopBArrivalButton);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(stopBArrivalButton);
      final Map<String, dynamic> arrived = await _waitForCanonicalStatus(
        tester,
        uid,
        _stopBId,
        'arrived',
      );
      _traceStage('distance_at_limit_arrival_confirmed');
      _traceStage('arrival_confirmed');
      expect(arrived['lifecycleSchemaVersion'], 2);
      expect(arrived['arrivalMode'], 'location_verified');
      expect(arrived['arrivalIsMocked'], isFalse);
      expect(arrived['arrivalAccuracyMeters'], 25);
      expect(
        arrived['arrivalDistanceMeters'],
        lessThanOrEqualTo(kArrivalMaxDistanceMeters),
      );
      parent = await _readParent(uid);
      final DocumentSnapshot<Map<String, dynamic>> parentById =
          await FirebaseFirestore.instance
              .collection('route_plan_progress')
              .doc('${_routePlanId}_$uid')
              .get(const GetOptions(source: Source.server));
      final QuerySnapshot<Map<String, dynamic>> parentByQuery =
          await FirebaseFirestore.instance
              .collection('route_plan_progress')
              .where('planId', isEqualTo: _routePlanId)
              .where('salesmanUid', isEqualTo: uid)
              .limit(2)
              .get(const GetOptions(source: Source.server));
      final int arrivedSequence = (arrived['sessionEventSequence'] as num)
          .toInt();
      final int summarySequence =
          (parent['lastSummaryEventSequence'] as num?)?.toInt() ?? -1;
      final int summaryGeneration =
          (parent['lastSummaryWorkSessionGeneration'] as num?)?.toInt() ?? -1;
      final int lastWriteSequence =
          (parent['lastStopWriteSequence'] as num?)?.toInt() ?? -1;
      final String summaryStop = parent['lastStopId'] == _stopBId
          ? 'stop_match'
          : 'stop_missing_or_other';
      final String summaryStatus = parent['lastStopStatus'] == 'arrived'
          ? 'status_arrived'
          : 'status_other';
      _traceStage(
        'arrival_parent_projection_${summaryStop}_${summaryStatus}_arrival_${arrivedSequence}_summary_${summarySequence}_generation_${summaryGeneration}_write_${lastWriteSequence}_doc_${parentById.exists}_direct_stop_${parentById.data()?['lastStopId'] == _stopBId}_direct_write_${parentById.data()?.containsKey('lastStopWriteSequence') == true}_query_expected_id_${parentByQuery.docs.single.id == '${_routePlanId}_$uid'}_query_direct_same_id_${parentByQuery.docs.single.id == parentById.id}',
      );
      expect(parent['lastStopId'], _stopBId);
      expect(parent['lastStopStatus'], 'arrived');
      expect(parent['selectedStopId'], _stopBId);

      final RoutePlanService service = RoutePlanService();
      final RouteProgress progressBeforeCompletion = await _readRouteProgress(
        tester,
        uid,
      );
      await FirebaseFirestore.instance.disableNetwork();
      _traceStage('offline_completion_begin');
      final RouteProgressWriteState offlineResult = await service
          .updateStopStatus(
            plan: plan,
            stop: stopB,
            user: user,
            progress: progressBeforeCompletion,
            status: 'completed',
          );
      expect(offlineResult, RouteProgressWriteState.pending);
      _traceStage('offline_completion_queued');
      final List<RouteStopLifecycleEvent> queued = await RouteStopOutbox()
          .readForUid(uid, planId: _routePlanId);
      expect(queued, hasLength(1));
      expect(queued.single.stopId, _stopBId);
      expect(queued.single.status, 'completed');
      final String completionEventId = queued.single.eventId;

      await FirebaseFirestore.instance.enableNetwork();
      final RouteProgressWriteState retryResult = await service
          .retryPendingStopEvents(
            plan: plan,
            user: user,
            progress: progressBeforeCompletion,
          );
      expect(retryResult, RouteProgressWriteState.synced);
      _traceStage('offline_completion_replayed');
      final Map<String, dynamic> completed = await _waitForCanonicalStatus(
        tester,
        uid,
        _stopBId,
        'completed',
      );
      expect(completed['eventId'], completionEventId);
      expect(completed['arrivalEventId'], isNotEmpty);
      expect(completed['arrivalMode'], 'location_verified');
      final int completionSequence = completed['sessionEventSequence'] as int;
      expect(
        await service.retryPendingStopEvents(
          plan: plan,
          user: user,
          progress: await _readRouteProgress(tester, uid),
        ),
        RouteProgressWriteState.synced,
      );
      final Map<String, dynamic> afterReplay = (await _readCanonical(
        uid,
        _stopBId,
      ))!;
      expect(afterReplay['status'], 'completed');
      expect(afterReplay['eventId'], completionEventId);
      expect(afterReplay['sessionEventSequence'], completionSequence);
      final Map<String, dynamic> parentAfterCompletion = await _readParent(uid);
      expect(parentAfterCompletion['lastStopId'], _stopBId);
      expect(parentAfterCompletion['lastStopStatus'], 'completed');
      expect(
        (parentAfterCompletion['handledStopIds'] as List),
        contains(_stopBId),
      );

      final Finder selectA = find.text('Go to this stop');
      await _waitFor(
        tester,
        selectA,
        timeout: const Duration(seconds: 20),
        label: 'remaining pending route stops after completing B',
      );
      await _tapEnabledButton(tester, 'Go to this stop');
      await tester.pump(const Duration(milliseconds: 250));
      await _tapEnabledButton(tester, 'Skip');
      await _waitFor(
        tester,
        find.text('Retailer closed'),
        timeout: const Duration(seconds: 10),
        label: 'the skip reason dialog',
      );
      await tester.tap(find.text('Retailer closed'));
      final Map<String, dynamic> skipped = await _waitForCanonicalStatus(
        tester,
        uid,
        _stopAId,
        'skipped',
      );
      expect(skipped['lifecycleSchemaVersion'], 2);
      expect(skipped['skipReason'], 'Retailer closed');
      final Map<String, dynamic> parentAfterSkip = await _readParent(uid);
      expect(parentAfterSkip['lastStopId'], _stopAId);
      expect(parentAfterSkip['lastStopStatus'], 'skipped');
      expect(
        parentAfterSkip['lastSummaryEventSequence'],
        greaterThan(parentAfterCompletion['lastSummaryEventSequence'] as int),
      );
      expect(
        parentAfterSkip['handledStopIds'],
        containsAll(<String>[_stopAId, _stopBId]),
      );
      _traceStage('out_of_order_skip_recorded');

      await _tapEnabledButton(tester, 'Go to this stop');
      await _tapEnabledButton(tester, 'Mark arrived');
      await _waitFor(
        tester,
        find.text('Arrival not verified'),
        timeout: const Duration(seconds: 15),
        label: 'the unverified candidate-pin arrival rejection',
      );
      expect(await _readCanonical(uid, _stopCId), isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      _traceStage('candidate_pin_not_gps_verified');

      final Map<String, dynamic> routeAfter = await _readPublishedRoute();
      expect(routeAfter, equals(routeBefore));
      // ignore: avoid_print
      print(
        'ROUTE_ARRIVAL_TRACE ${jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'fixture': 'route-arrival-acceptance-v1',
          'emulatorOnly': true,
          'positionSource': 'integration_test_geolocator_override',
          'syntheticPositionsAreFieldEvidence': false,
          'routeHeartbeatWritten': true,
          'selectedStopBBeforeA': selectedBBeforeA,
          'distance76Rejected': true,
          'distance75Rejected': true,
          'distanceAtLimitAccepted': true,
          'accuracy26Rejected': true,
          'fixAge31SecondsRejected': true,
          'noWriteBeforeConfirmation': true,
          'verifiedArrivalConfirmed': arrived['arrivalMode'] == 'location_verified',
          'offlineCompletionQueued': true,
          'completionEventAcknowledgedOnce': completed['eventId'] == completionEventId,
          'completedBThenSkippedA': true,
          'unverifiedPinDidNotGpsVerify': true,
          'parentHandledBothStops': true,
          'publishedRouteUnchanged': true,
          'unverifiedBoundaries': <String>['app_process_restart_during_retry', 'second_salesperson_auth_scope', 'concurrent_selection_rebase', 'Android_background_permission_smoke'],
        })}',
      );
    },
  );
}
