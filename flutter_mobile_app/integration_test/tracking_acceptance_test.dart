import 'dart:convert';

import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:fmcg_sales/main.dart' as app;
import 'package:fmcg_sales/providers/auth_provider.dart';
import 'package:fmcg_sales/providers/gps_provider.dart';

const Duration _quickSignInTimeout = Duration(seconds: 60);
const Duration _authenticatedHomeTimeout = Duration(seconds: 90);
const Duration _trackingObservationWindow = Duration(seconds: 30);
const Duration _platformReadTimeout = Duration(seconds: 5);
const Duration _firestoreReadTimeout = Duration(seconds: 10);

Future<bool> _waitForFinder(
  WidgetTester tester,
  Finder finder, {
  required Duration timeout,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return finder.evaluate().isNotEmpty;
}

Future<Position?> _observeTracking(
  WidgetTester tester,
  GpsProvider gps,
  Duration duration,
) async {
  Position? lastObservedPosition = gps.currentPosition;
  final DateTime deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    lastObservedPosition = gps.currentPosition ?? lastObservedPosition;
  }
  return gps.currentPosition ?? lastObservedPosition;
}

Future<bool?> _readLocationServiceState() async {
  try {
    return await Geolocator.isLocationServiceEnabled().timeout(
      _platformReadTimeout,
    );
  } catch (_) {
    return null;
  }
}

Future<String> _readOsPermission() async {
  try {
    return (await Geolocator.checkPermission().timeout(
      _platformReadTimeout,
    )).name;
  } catch (_) {
    return 'unavailable';
  }
}

DateTime? _timestampValue(Object? value) {
  if (value is Timestamp) return value.toDate().toUtc();
  if (value is DateTime) return value.toUtc();
  if (value is String) return DateTime.tryParse(value)?.toUtc();
  return null;
}

Map<String, Object?> _captureSyncTimestamps(Map<String, dynamic> row) {
  const List<String> allowedFields = <String>[
    'deviceCapturedAt',
    'timestamp',
    'updatedAt',
    'lastSeen',
  ];
  final Map<String, Object?> timestamps = <String, Object?>{};
  for (final String field in allowedFields) {
    if (!row.containsKey(field)) continue;
    timestamps[field] = _timestampValue(row[field])?.toIso8601String();
  }
  return timestamps;
}

Map<String, Object?> _currentRunFreshness({
  required bool? rowPresent,
  required Map<String, Object?> captureSyncTimestampsUtc,
  required String trackingObservationStartedAtUtc,
}) {
  final DateTime? observationStartedAt = DateTime.tryParse(
    trackingObservationStartedAtUtc,
  )?.toUtc();
  final DateTime? deviceCapturedAt = _timestampValue(
    captureSyncTimestampsUtc['deviceCapturedAt'],
  );

  String? serverTimestampField;
  for (final String field in <String>['lastSeen', 'updatedAt', 'timestamp']) {
    if (captureSyncTimestampsUtc.containsKey(field)) {
      serverTimestampField = field;
      break;
    }
  }
  final DateTime? serverSyncedAt = serverTimestampField == null
      ? null
      : _timestampValue(captureSyncTimestampsUtc[serverTimestampField]);

  final bool? deviceCaptureAfterStart =
      observationStartedAt == null || deviceCapturedAt == null
      ? null
      : !deviceCapturedAt.isBefore(observationStartedAt);
  final bool? serverSyncAfterStart =
      observationStartedAt == null || serverSyncedAt == null
      ? null
      : !serverSyncedAt.isBefore(observationStartedAt);

  final String status;
  if (rowPresent != true) {
    status = rowPresent == false ? 'no_row' : 'unavailable';
  } else if (deviceCaptureAfterStart == true && serverSyncAfterStart == true) {
    status = 'current_run_fresh';
  } else if (deviceCaptureAfterStart == false ||
      serverSyncAfterStart == false) {
    status = 'not_current_run';
  } else {
    status = 'timestamps_unavailable';
  }

  return <String, Object?>{
    'status': status,
    'deviceCaptureAfterObservationStart': deviceCaptureAfterStart,
    'serverSyncAfterObservationStart': serverSyncAfterStart,
    'serverTimestampField': serverTimestampField,
  };
}

Future<Map<String, Object?>> _readOwnLiveTrackingRow(String uid) async {
  try {
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await FirebaseFirestore.instance
            .collection('live_tracking')
            .doc(uid)
            .get(const GetOptions(source: Source.server))
            .timeout(_firestoreReadTimeout);
    final Map<String, dynamic>? row = snapshot.data();
    return <String, Object?>{
      'readStatus': 'readable',
      'rowPresent': snapshot.exists,
      'captureSyncTimestampsUtc': row == null
          ? <String, Object?>{}
          : _captureSyncTimestamps(row),
    };
  } on FirebaseException catch (error) {
    return <String, Object?>{
      'readStatus': error.code == 'permission-denied'
          ? 'permission_denied'
          : 'unavailable',
      'rowPresent': null,
      'readErrorCode': error.code,
      'captureSyncTimestampsUtc': <String, Object?>{},
    };
  } catch (_) {
    return <String, Object?>{
      'readStatus': 'unavailable',
      'rowPresent': null,
      'captureSyncTimestampsUtc': <String, Object?>{},
    };
  }
}

String _firstUnconfirmedBoundary({
  required bool loginProfileReached,
  required bool? locationServiceEnabled,
  required String osPermission,
  required GpsTrackingState gpsState,
  required bool positionArrived,
  required bool? reliableFix,
  required String liveTrackingReadStatus,
  required String currentRunFreshnessStatus,
}) {
  if (!loginProfileReached) return 'session';
  if (gpsState == GpsTrackingState.disabledByUser) {
    return 'profile_sharing_disabled_session';
  }

  final bool permissionUnavailable =
      osPermission != LocationPermission.whileInUse.name &&
      osPermission != LocationPermission.always.name;
  final bool providerPermissionDenied =
      gpsState == GpsTrackingState.permissionDenied ||
      gpsState == GpsTrackingState.permissionDeniedForever;
  if (locationServiceEnabled != true ||
      permissionUnavailable ||
      providerPermissionDenied ||
      gpsState == GpsTrackingState.serviceDisabled) {
    return 'permission_services';
  }

  if (!positionArrived) return 'fix';
  if (reliableFix != true) return 'reliable_fix_filter';
  if (liveTrackingReadStatus != 'readable' ||
      currentRunFreshnessStatus != 'current_run_fresh') {
    return 'firestore_row_or_rule';
  }
  return 'dashboard_handoff';
}

void _printTrace(Map<String, Object?> trace) {
  // ignore: avoid_print
  print('TRACKING_TRACE ${jsonEncode(trace)}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reports the authenticated salesperson tracking baseline', (
    WidgetTester tester,
  ) async {
    const bool useFirebaseEmulator = bool.fromEnvironment(
      'USE_FIREBASE_EMULATOR',
    );
    const String firebaseEmulatorHost = String.fromEnvironment(
      'FIREBASE_EMULATOR_HOST',
    );

    expect(
      useFirebaseEmulator,
      isTrue,
      reason: 'Tracking diagnostics must fail closed outside emulator mode.',
    );
    expect(
      firebaseEmulatorHost,
      '10.0.2.2',
      reason:
          'The Android device must target the prepared local emulator host.',
    );

    final Map<String, Object?> trace = <String, Object?>{
      'schemaVersion': 1,
      'observedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'emulatorGuard': <String, Object?>{
        'enabled': useFirebaseEmulator,
        'androidHostMatched': firebaseEmulatorHost == '10.0.2.2',
      },
      'quickSignInVisible': false,
      'homeVisible': false,
      'assignedRouteEntryVisible': false,
      'loginProfileReached': false,
      'authStatus': 'not_observed',
      'locationServiceEnabled': null,
      'osPermission': 'not_observed',
      'gpsProvider': <String, Object?>{
        'state': null,
        'isTracking': null,
        'positionArrived': false,
        'fixAgeSeconds': null,
        'accuracyMeters': null,
        'isMocked': null,
        'reliableFix': null,
      },
      'liveTracking': <String, Object?>{
        'readStatus': 'not_attempted',
        'rowPresent': null,
        'captureSyncTimestampsUtc': <String, Object?>{},
      },
      'currentRunFreshness': <String, Object?>{
        'status': 'not_observed',
        'deviceCaptureAfterObservationStart': null,
        'serverSyncAfterObservationStart': null,
        'serverTimestampField': null,
      },
      'writeAttemptStatus': 'not_exposed_by_app',
      'dashboardHandoffObserved': false,
      'firstUnconfirmedBoundary': 'session',
    };

    app.main();
    await tester.pump(const Duration(seconds: 2));

    final Finder quickSignIn = find.text('Salesperson');
    final bool quickSignInVisible = await _waitForFinder(
      tester,
      quickSignIn,
      timeout: _quickSignInTimeout,
    );
    trace['quickSignInVisible'] = quickSignInVisible;

    String? trackingObservationStartedAtUtc;
    bool homeVisible = false;
    bool assignedRouteEntryVisible = false;
    bool loginProfileReached = false;
    String authStatus = 'not_observed';
    GpsProvider? gps;
    String? uid;

    if (quickSignInVisible) {
      trackingObservationStartedAtUtc = DateTime.now()
          .toUtc()
          .toIso8601String();
      trace['trackingObservationStartedAtUtc'] =
          trackingObservationStartedAtUtc;
      await tester.tap(quickSignIn.first);
      assignedRouteEntryVisible = await _waitForFinder(
        tester,
        find.descendant(
          of: find.byType(ScootBottomNav),
          matching: find.text('Route'),
        ),
        timeout: _authenticatedHomeTimeout,
      );
      homeVisible = find.text('Home').evaluate().isNotEmpty;

      if (assignedRouteEntryVisible) {
        final BuildContext homeContext = tester.element(
          find
              .descendant(
                of: find.byType(ScootBottomNav),
                matching: find.text('Route'),
              )
              .first,
        );
        if (!homeContext.mounted) return;
        final AuthProvider auth = Provider.of<AuthProvider>(
          homeContext,
          listen: false,
        );
        gps = Provider.of<GpsProvider>(homeContext, listen: false);
        authStatus = auth.status.name;
        uid = auth.user?.uid;
        loginProfileReached =
            homeVisible && auth.isLoggedIn && uid?.trim().isNotEmpty == true;
      }
    }

    trace['homeVisible'] = homeVisible;
    trace['assignedRouteEntryVisible'] = assignedRouteEntryVisible;
    trace['loginProfileReached'] = loginProfileReached;
    trace['authStatus'] = authStatus;

    if (!loginProfileReached || gps == null || uid == null) {
      trace['firstUnconfirmedBoundary'] = 'session';
      _printTrace(trace);
      expect(
        loginProfileReached,
        isTrue,
        reason: 'The diagnostic must reach the authenticated salesperson home.',
      );
      return;
    }

    final GpsProvider tracking = gps;
    final String signedInUid = uid;
    final String runStartedAtUtc = trackingObservationStartedAtUtc!;
    trace['observationWindowSeconds'] = _trackingObservationWindow.inSeconds;
    final Position? observedPosition = await _observeTracking(
      tester,
      tracking,
      _trackingObservationWindow,
    );

    final bool? locationServiceEnabled = await _readLocationServiceState();
    final String osPermission = await _readOsPermission();
    final bool positionArrived = observedPosition != null;
    final bool? reliableFix = positionArrived
        ? tracking.reliableCurrentPosition != null
        : null;
    final DateTime? capturedAt = observedPosition?.timestamp.toUtc();
    final double? fixAgeSeconds = capturedAt == null
        ? null
        : DateTime.now().toUtc().difference(capturedAt).inMilliseconds / 1000;
    final double? accuracyMeters = observedPosition?.accuracy.isFinite == true
        ? observedPosition!.accuracy
        : null;

    trace['locationServiceEnabled'] = locationServiceEnabled;
    trace['osPermission'] = osPermission;
    trace['gpsProvider'] = <String, Object?>{
      'state': tracking.state.name,
      'isTracking': tracking.isTracking,
      'positionArrived': positionArrived,
      'fixAgeSeconds': fixAgeSeconds,
      'accuracyMeters': accuracyMeters,
      'isMocked': observedPosition?.isMocked,
      'reliableFix': reliableFix,
    };

    final Map<String, Object?> liveTracking = await _readOwnLiveTrackingRow(
      signedInUid,
    );
    trace['liveTracking'] = liveTracking;
    final Map<String, Object?> captureSyncTimestampsUtc =
        liveTracking['captureSyncTimestampsUtc']! as Map<String, Object?>;
    final Map<String, Object?> currentRunFreshness = _currentRunFreshness(
      rowPresent: liveTracking['rowPresent'] as bool?,
      captureSyncTimestampsUtc: captureSyncTimestampsUtc,
      trackingObservationStartedAtUtc: runStartedAtUtc,
    );
    trace['currentRunFreshness'] = currentRunFreshness;
    trace['firstUnconfirmedBoundary'] = _firstUnconfirmedBoundary(
      loginProfileReached: loginProfileReached,
      locationServiceEnabled: locationServiceEnabled,
      osPermission: osPermission,
      gpsState: tracking.state,
      positionArrived: positionArrived,
      reliableFix: reliableFix,
      liveTrackingReadStatus: liveTracking['readStatus']! as String,
      currentRunFreshnessStatus: currentRunFreshness['status']! as String,
    );

    trace['observedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    _printTrace(trace);
  });
}
