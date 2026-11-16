import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:geolocator/geolocator.dart';

import '../models/user_model.dart';
import '../models/tracking_control.dart';
import '../models/work_session.dart';
import '../services/company_lifecycle_monitor.dart';
import '../services/firestore_service.dart';
import '../services/gps_backlog.dart';
import '../services/work_session_store.dart';
import '../services/project_local_store.dart';
import '../utils/location_evidence.dart';
import '../utils/location_fix.dart';

enum GpsTrackingState {
  idle,
  disabledByUser,
  notAllowed,
  startingSession,
  checking,
  tracking,
  syncPending,
  sessionSuperseded,
  sessionEnded,
  sessionEndPending,
  controlPending,
  syncFailed,
  companyPaused,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  unreliableFix,
  error,
}

const Duration _trackingFixMaxAge = Duration(minutes: 2);
const double _trackingFixMaxAccuracyMeters = 100;
const double _movementThresholdMeters = 15;
const Duration _breadcrumbMinimumInterval = Duration(minutes: 5);

class GpsPermissionRequestGate {
  GpsPermissionRequestGate({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  Future<LocationPermission?>? _active;

  Future<LocationPermission?> resolve(
    Future<LocationPermission?> Function() request,
  ) {
    final Future<LocationPermission?>? active = _active;
    if (active != null) return active;

    final Completer<LocationPermission?> completer =
        Completer<LocationPermission?>();
    final Future<LocationPermission?> pending = completer.future;
    _active = pending;

    Timer? timer;
    void finish(LocationPermission? value) {
      timer?.cancel();
      if (identical(_active, pending)) _active = null;
      if (!completer.isCompleted) completer.complete(value);
    }

    timer = Timer(timeout, () => finish(null));
    request().then<void>(
      (LocationPermission? value) => finish(value),
      onError: (Object _) => finish(null),
    );
    return pending;
  }
}

class GpsProvider extends ChangeNotifier {
  GpsProvider({FirestoreService? firestoreService})
    : _firestoreService = firestoreService;

  static const MethodChannel _notificationChannel = MethodChannel(
    'my.scootsales.app/notifications',
  );

  FirestoreService? _firestoreService;

  Position? _currentPosition;
  bool _isTracking = false;
  bool _trackingEnabled = true;
  bool _trackingRequested = false;
  bool _awaitingImmediateUpload = false;
  int _retryAttempt = 0;
  int _uploadRetryAttempt = 0;
  GpsTrackingState _state = GpsTrackingState.idle;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<ServiceStatus>? _serviceStatusSubscription;
  StreamSubscription<TrackingControl>? _controlSubscription;
  Timer? _uploadTimer;
  Timer? _retryTimer;
  Future<void>? _startFuture;
  Future<void>? _uploadFuture;
  Future<void>? _controlApplyFuture;
  final GpsPermissionRequestGate _permissionGate = GpsPermissionRequestGate();
  final ProjectLocalStore _localStore = ProjectLocalStore();
  late final WorkSessionStore _workSessionStore = WorkSessionStore(
    projectId: _localStore.projectId,
  );
  late final GpsBacklogStore _backlog = GpsBacklogStore(
    projectId: _localStore.projectId,
  );
  Future<void>? _backlogFlush;
  WorkSession? _workSession;
  UserModel? _sessionUser;
  bool _sessionNeedsSync = false;
  bool _heldPointsBlockStart = false;
  bool _controlUpdateInProgress = false;
  Position? _pendingUploadPosition;
  int? _pendingUploadSequence;
  DateTime? _lastUploadedCapturedAt;
  double? _lastUploadedLatitude;
  double? _lastUploadedLongitude;
  String _controlSubscriptionUid = '';
  String _controlSubscriptionSessionId = '';
  int _controlSubscriptionGeneration = 0;
  int? _startFutureGeneration;
  int _trackingGeneration = 0;

  @visibleForTesting
  void showSyncPendingForTest({bool heldPoints = false, WorkSession? session}) {
    _heldPointsBlockStart = heldPoints;
    _workSession = session;
    _setState(GpsTrackingState.syncPending);
  }

  @visibleForTesting
  bool isCurrentTrackingGeneration({
    required bool trackingRequested,
    required int expectedGeneration,
    required int currentGeneration,
  }) {
    return trackingRequested && expectedGeneration == currentGeneration;
  }

  Position? get currentPosition => _currentPosition;
  Position? get reliableCurrentPosition {
    final Position? value = _currentPosition;
    if (value == null || !_isUsableTrackingFix(value, now: DateTime.now())) {
      return null;
    }
    return value;
  }

  bool get isTracking => _isTracking;
  bool get trackingEnabled => _trackingEnabled;
  GpsTrackingState get state => _state;
  WorkSession? get workSession => _workSession;
  String get workSessionId => _workSession?.sessionId ?? '';
  int get workSessionGeneration => _workSession?.generation ?? 0;
  TrackingMode get trackingMode =>
      _workSession?.trackingMode ?? TrackingMode.batterySaver;
  int get trackingControlRevision => _workSession?.controlRevision ?? 0;
  int get appliedControlRevision => _workSession?.appliedControlRevision ?? 0;
  bool get trackingControlNeedsAck =>
      trackingControlRevision > appliedControlRevision;
  bool get hasAcknowledgedWorkSession =>
      _workSession?.isAcknowledged == true &&
      _workSession?.status == WorkSessionLocalStatus.active;

  bool get hasActiveWorkSession =>
      _workSession?.status == WorkSessionLocalStatus.active &&
      _workSession?.endPendingSync != true;

  bool get hasArrivalReadySession {
    final WorkSession? session = _workSession;
    return session != null &&
        session.isAcknowledged &&
        !session.endPendingSync &&
        session.sessionId.isNotEmpty;
  }

  bool get workSessionNeedsSync => _sessionNeedsSync;
  bool get hasLocationProblem => switch (_state) {
    GpsTrackingState.permissionDenied ||
    GpsTrackingState.permissionDeniedForever ||
    GpsTrackingState.error ||
    GpsTrackingState.unreliableFix ||
    GpsTrackingState.syncFailed => true,
    _ => false,
  };
  String get statusMessage => switch (_state) {
    GpsTrackingState.idle => 'Location tracking is off.',
    GpsTrackingState.disabledByUser =>
      'Location sharing is off. Turn it on in Profile, or confirm arrivals by hand.',
    GpsTrackingState.notAllowed =>
      'Location is not used while your account is not active.',
    GpsTrackingState.startingSession => 'Starting your work session…',
    GpsTrackingState.checking => 'Checking location services…',
    GpsTrackingState.tracking =>
      reliableCurrentPosition == null
          ? 'Waiting for a fresh, accurate location.'
          : 'Sharing your current location.',
    GpsTrackingState.syncPending =>
      hasActiveWorkSession
          ? 'Work is active on this device. Location sync is pending.'
          : _heldPointsBlockStart
          ? 'Sending saved location points. Try Start Work again when this finishes.'
          : _workSession?.endPendingSync == true
          ? 'Work ended on this device. End status is waiting to sync.'
          : 'Could not start work. Check your connection and try Start Work again.',
    GpsTrackingState.sessionSuperseded =>
      'This work session was replaced on another device. Start Work to continue.',
    GpsTrackingState.sessionEnded => 'Work ended on this device.',
    GpsTrackingState.sessionEndPending =>
      'Work ended on this device. End status is waiting to sync.',
    GpsTrackingState.controlPending =>
      'The new upload mode is waiting for phone acknowledgement.',
    GpsTrackingState.syncFailed =>
      'Work session could not sync. Check your connection and retry.',
    GpsTrackingState.companyPaused =>
      'The company is paused. Work cannot start until it is active again.',
    GpsTrackingState.serviceDisabled =>
      'Location services are off. Tracking will resume when they return.',
    GpsTrackingState.permissionDenied =>
      'Location permission is required for verified arrivals.',
    GpsTrackingState.permissionDeniedForever =>
      'Location permission is blocked in device settings.',
    GpsTrackingState.unreliableFix =>
      'No accurate, recent location yet. Turn on device location, allow it for this app, then wait a few seconds. Simulated locations are not accepted.',
    GpsTrackingState.error =>
      'Location tracking paused after repeated errors. Reopen the app or retry.',
  };

  Future<void> setTrackingEnabled(
    bool enabled, {
    bool notAllowed = false,
  }) async {
    if (!enabled) {
      await endWork();
      _trackingEnabled = false;
      _setState(
        notAllowed
            ? GpsTrackingState.notAllowed
            : GpsTrackingState.disabledByUser,
      );
      return;
    }
    if (_trackingEnabled) return;
    _trackingEnabled = true;
    _setState(GpsTrackingState.idle);
  }

  Future<void> startTracking({UserModel? user, bool explicit = false}) async {
    if (!_trackingEnabled) {
      _trackingRequested = false;
      _setState(
        _state == GpsTrackingState.notAllowed
            ? GpsTrackingState.notAllowed
            : GpsTrackingState.disabledByUser,
      );
      return;
    }
    final User? authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null) {
      _setState(GpsTrackingState.syncFailed);
      return;
    }
    UserModel? resolvedUser = user;
    try {
      resolvedUser ??= await (_firestoreService ??= FirestoreService()).getUser(
        authUser.uid,
      );
    } catch (_) {
      _setState(GpsTrackingState.syncFailed);
      return;
    }
    if (resolvedUser == null ||
        resolvedUser.uid != authUser.uid ||
        !resolvedUser.hasSalespersonRole ||
        !resolvedUser.hasActiveAccount) {
      await endWork(uid: authUser.uid, user: resolvedUser);
      _setState(GpsTrackingState.notAllowed);
      return;
    }
    _sessionUser = resolvedUser;
    _trackingRequested = true;
    final int generation = _trackingGeneration;
    _watchLocationService(generation);
    await _ensureTracking(
      generation: generation,
      user: resolvedUser,
      explicit: explicit,
    );
  }

  Future<void> refreshTracking() async {
    unawaited(_flushHeldPoints());
    if (!_trackingEnabled || !_trackingRequested) return;
    final int generation = _trackingGeneration;
    _watchLocationService(generation);
    final UserModel? user = _sessionUser;
    if (user == null) return;
    await _ensureTracking(forceCheck: true, generation: generation, user: user);
  }

  Future<ArrivalLocationAssessment> captureArrivalLocation({
    required double retailerLatitude,
    required double retailerLongitude,
  }) async {
    if (!_trackingEnabled) {
      return const ArrivalLocationAssessment.unavailable(
        LocationEvidenceFailure.disabledByUser,
      );
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _setState(GpsTrackingState.serviceDisabled);
        return const ArrivalLocationAssessment.unavailable(
          LocationEvidenceFailure.serviceDisabled,
        );
      }

      final LocationPermission? permission = await _resolveLocationPermission(
        allowPrompt: _state != GpsTrackingState.permissionDenied,
      );
      if (permission == null) {
        return const ArrivalLocationAssessment.unavailable(
          LocationEvidenceFailure.unavailable,
        );
      }
      if (permission == LocationPermission.deniedForever) {
        _setState(GpsTrackingState.permissionDeniedForever);
        return const ArrivalLocationAssessment.unavailable(
          LocationEvidenceFailure.permissionDeniedForever,
        );
      }
      if (permission == LocationPermission.denied) {
        _setState(GpsTrackingState.permissionDenied);
        return const ArrivalLocationAssessment.unavailable(
          LocationEvidenceFailure.permissionDenied,
        );
      }

      final Position? position = await acquireLocationFix(
        isUsable: (Position p) => isReliableArrivalFix(_toFix(p)),
        coarseWait: Duration.zero,
      );
      if (position == null) {
        return const ArrivalLocationAssessment.unavailable(
          LocationEvidenceFailure.unavailable,
        );
      }
      _acceptPosition(position);
      return ArrivalLocationAssessment.assess(
        fix: _toFix(position),
        retailerLatitude: retailerLatitude,
        retailerLongitude: retailerLongitude,
        now: DateTime.now(),
      );
    } catch (_) {
      return const ArrivalLocationAssessment.unavailable(
        LocationEvidenceFailure.unavailable,
      );
    }
  }

  void _watchLocationService(int generation) {
    if (_serviceStatusSubscription != null) return;
    try {
      _serviceStatusSubscription = Geolocator.getServiceStatusStream().listen((
        ServiceStatus status,
      ) {
        if (!_isCurrentGeneration(generation)) return;
        if (status == ServiceStatus.disabled) {
          unawaited(
            _pausePositionStream(
              GpsTrackingState.serviceDisabled,
              generation: generation,
            ),
          );
        } else if (_trackingRequested) {
          final UserModel? user = _sessionUser;
          if (user != null) {
            unawaited(
              _ensureTracking(
                forceCheck: true,
                generation: generation,
                user: user,
              ),
            );
          }
        }
      }, onError: (_) {});
    } catch (_) {
      _serviceStatusSubscription = null;
    }
  }

  Future<void> _ensureTracking({
    bool forceCheck = false,
    required int generation,
    required UserModel user,
    bool explicit = false,
  }) async {
    final Future<void>? active = _startFuture;
    if (active != null && _startFutureGeneration == generation) {
      return active;
    }
    if (_isTracking && !forceCheck) return;
    final Future<void> next = _startTrackingInternal(
      generation,
      user: user,
      explicit: explicit,
    );
    _startFuture = next;
    _startFutureGeneration = generation;
    try {
      await next;
    } finally {
      if (identical(_startFuture, next)) {
        _startFuture = null;
        _startFutureGeneration = null;
      }
    }
  }

  Future<void> _startTrackingInternal(
    int generation, {
    required UserModel user,
    required bool explicit,
  }) async {
    if (!_isCurrentOwner(generation, user.uid)) return;
    _setState(GpsTrackingState.checking);
    GpsTrackingState? blockedState;
    if (!await Geolocator.isLocationServiceEnabled()) {
      blockedState = GpsTrackingState.serviceDisabled;
    } else {
      final LocationPermission? permission = await _resolveLocationPermission(
        allowPrompt: explicit,
      );
      if (explicit) await _requestNotificationPermission();
      if (!_isCurrentOwner(generation, user.uid)) return;
      if (permission == null) {
        blockedState = GpsTrackingState.error;
      } else if (permission == LocationPermission.deniedForever) {
        blockedState = GpsTrackingState.permissionDeniedForever;
      } else if (permission == LocationPermission.denied) {
        blockedState = GpsTrackingState.permissionDenied;
      }
    }
    if (!_isCurrentOwner(generation, user.uid)) return;
    if (blockedState != null && !explicit) {
      await _pausePositionStream(blockedState, generation: generation);
      return;
    }

    final bool sessionReady = await _resolveWorkSession(
      user: user,
      generation: generation,
      explicit: explicit,
    );
    if (!sessionReady || !_isCurrentOwner(generation, user.uid)) return;
    final WorkSession? activeSession = _workSession;
    if (activeSession != null) {
      unawaited(
        _watchTrackingControl(
          user: user,
          session: activeSession,
          generation: generation,
        ),
      );
    }
    if (blockedState != null) {
      await _pausePositionStream(blockedState, generation: generation);
      return;
    }

    if (_positionSubscription == null) {
      final LocationSettings settings =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
              foregroundNotificationConfig: const ForegroundNotificationConfig(
                notificationTitle: 'Scoot Sales',
                notificationText:
                    'Location sharing is active for your work session.',
                notificationChannelName: 'Active work session',
                enableWifiLock: false,
                setOngoing: true,
              ),
            )
          : !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
          ? AppleSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
              allowBackgroundLocationUpdates: true,
              showBackgroundLocationIndicator: true,
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            );
      _awaitingImmediateUpload = true;
      _positionSubscription =
          Geolocator.getPositionStream(locationSettings: settings).listen(
            (Position position) {
              if (_isCurrentOwner(generation, user.uid)) {
                _acceptPosition(position);
              }
            },
            onError: (_) => unawaited(_handleStreamError(generation, user.uid)),
            cancelOnError: true,
          );
      _scheduleNextUpload(
        generation: generation,
        uid: user.uid,
        delay: const Duration(seconds: 30),
      );
    }

    if (!_isCurrentOwner(generation, user.uid)) return;
    _isTracking = true;
    _setState(
      _sessionNeedsSync
          ? GpsTrackingState.syncPending
          : GpsTrackingState.tracking,
    );
    unawaited(
      acquireLocationFix(
        isUsable: (Position p) => _isUsableTrackingFix(p, now: DateTime.now()),
      ).then((Position? position) {
        if (position != null && _isCurrentOwner(generation, user.uid)) {
          _acceptPosition(position, requestImmediateUpload: true);
        }
      }),
    );
  }

  Future<bool> _resolveWorkSession({
    required UserModel user,
    required int generation,
    required bool explicit,
  }) async {
    final FirestoreService service = _firestoreService ??= FirestoreService();
    WorkSession? local;
    try {
      local = await _workSessionStore.read(user.uid);
    } catch (_) {
      if (_isCurrentOwner(generation, user.uid)) {
        _setState(GpsTrackingState.syncFailed);
      }
      return false;
    }
    if (!_isCurrentOwner(generation, user.uid)) return false;

    if (local != null) {
      _workSession = local;
      if (local.status == WorkSessionLocalStatus.ended) {
        if (local.endPendingSync && local.generation > 0) {
          try {
            await service.publishHeldTrack(
              user: user,
              session: local,
              store: _backlog,
            );
            await service.endWorkSession(
              uid: user.uid,
              sessionId: local.sessionId,
              generation: local.generation,
            );
            local = local.copyWith(endPendingSync: false);
            await _workSessionStore.write(local);
            _workSession = local;
            await _flushHeldTrack(user);
          } catch (_) {
            if (_isCurrentOwner(generation, user.uid)) {
              _sessionNeedsSync = true;
              _setState(GpsTrackingState.syncPending);
            }
            return false;
          }
        } else if (await _backlog.hasAny(user.uid)) {
          unawaited(_flushHeldTrack(user));
        }
        if (!explicit) {
          _setState(GpsTrackingState.sessionEnded);
          return false;
        }
      } else if (local.status == WorkSessionLocalStatus.superseded &&
          !explicit) {
        _setState(GpsTrackingState.sessionSuperseded);
        return false;
      } else if (local.status == WorkSessionLocalStatus.active) {
        WorkSessionServerRecord server;
        try {
          server = await service.readWorkSession(user.uid);
        } on FirebaseException catch (error) {
          if (!_isCurrentOwner(generation, user.uid)) return false;
          if (error.code == 'permission-denied') {
            _setState(GpsTrackingState.syncFailed);
            return false;
          }
          _sessionNeedsSync = true;
          return true;
        } catch (_) {
          if (!_isCurrentOwner(generation, user.uid)) return false;
          _sessionNeedsSync = true;
          return true;
        }
        if (!_isCurrentOwner(generation, user.uid)) return false;
        if (server.isActive &&
            server.sessionId == local.sessionId &&
            server.generation == local.generation) {
          local = local.copyWith(
            lastFixSequence: server.lastFixSequence > local.lastFixSequence
                ? server.lastFixSequence
                : local.lastFixSequence,
            trackingMode: server.trackingMode,
            controlRevision: server.appliedControlRevision,
            appliedControlRevision: server.appliedControlRevision,
            lastBreadcrumbCapturedAt: server.lastBreadcrumbCapturedAt,
            clearLastBreadcrumbCapturedAt:
                server.lastBreadcrumbCapturedAt == null,
          );
          _workSession = local;
          await _workSessionStore.write(local);
          _sessionNeedsSync = false;
          return true;
        }
        if (server.endedByCompanyPause &&
            server.sessionId == local.sessionId &&
            server.generation == local.generation) {
          final WorkSession pausedEnd = local.copyWith(
            status: WorkSessionLocalStatus.ended,
            endPendingSync: false,
          );
          await _workSessionStore.write(pausedEnd);
          _workSession = pausedEnd;
          await _pausePositionStream(
            GpsTrackingState.companyPaused,
            generation: generation,
          );
          return false;
        }
        final WorkSession superseded = local.copyWith(
          status: WorkSessionLocalStatus.superseded,
          endPendingSync: false,
        );
        await _workSessionStore.write(superseded);
        _workSession = superseded;
        await _pausePositionStream(
          GpsTrackingState.sessionSuperseded,
          generation: generation,
        );
        return false;
      }
    }

    final WorkSession? pendingStart = local;
    if (pendingStart?.status == WorkSessionLocalStatus.starting) {
      WorkSessionServerRecord server;
      try {
        server = await service.readWorkSession(user.uid);
      } catch (_) {
        if (_isCurrentOwner(generation, user.uid)) {
          _sessionNeedsSync = true;
          _setState(GpsTrackingState.syncPending);
        }
        return false;
      }
      if (!_isCurrentOwner(generation, user.uid)) return false;
      if (server.isActive &&
          server.sessionId == pendingStart!.sessionId &&
          server.generation == pendingStart.previousGeneration + 1) {
        final WorkSession acknowledged = pendingStart.copyWith(
          generation: server.generation,
          lastFixSequence: server.lastFixSequence,
          status: WorkSessionLocalStatus.active,
          endPendingSync: false,
          trackingMode: server.trackingMode,
          controlRevision: server.appliedControlRevision,
          appliedControlRevision: server.appliedControlRevision,
          lastBreadcrumbCapturedAt: server.lastBreadcrumbCapturedAt,
          clearLastBreadcrumbCapturedAt:
              server.lastBreadcrumbCapturedAt == null,
        );
        await _workSessionStore.write(acknowledged);
        _workSession = acknowledged;
        _sessionNeedsSync = false;
        return true;
      }
      if (server.generation != pendingStart!.previousGeneration ||
          server.sessionId != pendingStart.previousSessionId) {
        final WorkSession superseded = pendingStart.copyWith(
          status: WorkSessionLocalStatus.superseded,
        );
        await _workSessionStore.write(superseded);
        _workSession = superseded;
        _setState(GpsTrackingState.sessionSuperseded);
        return false;
      }
      return _commitNewWorkSession(
        user: user,
        local: pendingStart,
        generation: generation,
      );
    }

    if (local != null &&
        local.status != WorkSessionLocalStatus.ended &&
        local.status != WorkSessionLocalStatus.superseded) {
      return false;
    }
    if (local != null && !explicit) return false;
    if (CompanyLifecycleMonitor.instance.paused) {
      _setState(GpsTrackingState.companyPaused);
      return false;
    }

    final bool backlogCleared = await _flushBacklogBeforeNewSession(user);
    if (!_isCurrentOwner(generation, user.uid)) return false;
    _heldPointsBlockStart = !backlogCleared;
    if (!backlogCleared) {
      _sessionNeedsSync = true;
      _setState(GpsTrackingState.syncPending);
      return false;
    }
    WorkSessionServerRecord previous;
    try {
      previous = await service.readWorkSession(user.uid);
    } catch (_) {
      if (_isCurrentOwner(generation, user.uid)) {
        _sessionNeedsSync = true;
        _setState(GpsTrackingState.syncPending);
      }
      return false;
    }
    if (!_isCurrentOwner(generation, user.uid)) return false;
    final WorkSession starting = WorkSession(
      uid: user.uid,
      sessionId: createWorkSessionId(),
      generation: 0,
      lastFixSequence: 0,
      status: WorkSessionLocalStatus.starting,
      previousSessionId: previous.sessionId,
      previousGeneration: previous.generation,
      deviceStartedAt: DateTime.now().toUtc(),
    );
    try {
      await _workSessionStore.write(starting);
    } catch (_) {
      _setState(GpsTrackingState.syncFailed);
      return false;
    }
    _workSession = starting;
    return _commitNewWorkSession(
      user: user,
      local: starting,
      generation: generation,
    );
  }

  Future<bool> _commitNewWorkSession({
    required UserModel user,
    required WorkSession local,
    required int generation,
  }) async {
    _setState(GpsTrackingState.startingSession);
    try {
      final WorkSessionStartResult result =
          await (_firestoreService ??= FirestoreService()).startWorkSession(
            user: user,
            sessionId: local.sessionId,
            expectedSessionId: local.previousSessionId,
            expectedGeneration: local.previousGeneration,
          );
      if (!_isCurrentOwner(generation, user.uid)) return false;
      if (!result.accepted) {
        final WorkSession superseded = local.copyWith(
          status: WorkSessionLocalStatus.superseded,
        );
        await _workSessionStore.write(superseded);
        _workSession = superseded;
        _setState(GpsTrackingState.sessionSuperseded);
        return false;
      }
      final WorkSession active = local.copyWith(
        generation: result.generation,
        lastFixSequence: result.lastFixSequence,
        userDocumentId: result.userDocumentId,
        status: WorkSessionLocalStatus.active,
        endPendingSync: false,
        trackingMode: result.trackingMode,
        controlRevision: result.controlRevision,
        appliedControlRevision: result.appliedControlRevision,
        clearLastBreadcrumbCapturedAt: true,
      );
      await _workSessionStore.write(active);
      if (!_isCurrentOwner(generation, user.uid)) return false;
      _workSession = active;
      _sessionNeedsSync = false;
      return true;
    } catch (_) {
      if (!_isCurrentOwner(generation, user.uid)) return false;
      _sessionNeedsSync = true;
      _setState(GpsTrackingState.syncPending);
      return false;
    }
  }

  Future<void> _watchTrackingControl({
    required UserModel user,
    required WorkSession session,
    required int generation,
  }) async {
    if (_controlSubscriptionUid == user.uid &&
        _controlSubscriptionSessionId == session.sessionId &&
        _controlSubscriptionGeneration == session.generation &&
        _controlSubscription != null) {
      return;
    }
    await _controlSubscription?.cancel();
    _controlSubscription = null;
    if (!_isCurrentSession(
      generation,
      user.uid,
      session.sessionId,
      session.generation,
    )) {
      return;
    }
    _controlSubscriptionUid = user.uid;
    _controlSubscriptionSessionId = session.sessionId;
    _controlSubscriptionGeneration = session.generation;
    try {
      _controlSubscription = (_firestoreService ??= FirestoreService())
          .watchTrackingControl(user.uid)
          .listen(
            (TrackingControl control) {
              _enqueueTrackingControlApply(
                control,
                uid: user.uid,
                sessionId: session.sessionId,
                sessionGeneration: session.generation,
                trackingGeneration: generation,
              );
            },
            onError: (_) {
              if (_isCurrentSession(
                generation,
                user.uid,
                session.sessionId,
                session.generation,
              )) {
                _setState(GpsTrackingState.controlPending);
              }
            },
          );
    } catch (_) {
      if (_isCurrentSession(
        generation,
        user.uid,
        session.sessionId,
        session.generation,
      )) {
        _setState(GpsTrackingState.controlPending);
      }
    }
  }

  void _enqueueTrackingControlApply(
    TrackingControl control, {
    required String uid,
    required String sessionId,
    required int sessionGeneration,
    required int trackingGeneration,
  }) {
    final Future<void> previous = _controlApplyFuture ?? Future<void>.value();
    final Future<void> next = previous.catchError((Object _) {}).then((
      _,
    ) async {
      await _applyTrackingControl(
        control,
        uid: uid,
        sessionId: sessionId,
        sessionGeneration: sessionGeneration,
        trackingGeneration: trackingGeneration,
      );
    });
    _controlApplyFuture = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_controlApplyFuture, next)) {
          _controlApplyFuture = null;
        }
      }),
    );
  }

  Future<void> _applyTrackingControl(
    TrackingControl control, {
    required String uid,
    required String sessionId,
    required int sessionGeneration,
    required int trackingGeneration,
  }) async {
    if (!_isCurrentSession(
      trackingGeneration,
      uid,
      sessionId,
      sessionGeneration,
    )) {
      return;
    }
    final Future<void>? activeUpload = _uploadFuture;
    if (activeUpload != null) await activeUpload;
    if (!_isCurrentSession(
      trackingGeneration,
      uid,
      sessionId,
      sessionGeneration,
    )) {
      return;
    }
    final WorkSession? current = _workSession;
    if (current == null || control.revision < current.controlRevision) return;
    if (control.revision == current.controlRevision &&
        control.mode != current.trackingMode) {
      _setState(GpsTrackingState.syncFailed);
      return;
    }
    if (control.revision == current.appliedControlRevision &&
        control.mode == current.trackingMode) {
      return;
    }

    _controlUpdateInProgress = true;
    _setState(GpsTrackingState.controlPending);
    try {
      final TrackingControl acknowledged =
          await (_firestoreService ??= FirestoreService())
              .acknowledgeTrackingControl(
                uid: uid,
                sessionId: sessionId,
                generation: sessionGeneration,
              );
      if (!_isCurrentSession(
        trackingGeneration,
        uid,
        sessionId,
        sessionGeneration,
      )) {
        return;
      }
      final WorkSession updated = current.copyWith(
        trackingMode: acknowledged.mode,
        controlRevision: acknowledged.revision,
        appliedControlRevision: acknowledged.revision,
      );
      _workSession = updated;
      try {
        await _workSessionStore.write(updated);
      } catch (_) {
        _setState(GpsTrackingState.syncFailed);
        return;
      }
      if (!_isCurrentSession(
        trackingGeneration,
        uid,
        sessionId,
        sessionGeneration,
      )) {
        return;
      }
      _uploadRetryAttempt = 0;
      _scheduleNextUpload(generation: trackingGeneration, uid: uid);
      _setState(
        _sessionNeedsSync
            ? GpsTrackingState.syncPending
            : !_isUsableTrackingFix(_currentPosition, now: DateTime.now())
            ? GpsTrackingState.unreliableFix
            : GpsTrackingState.tracking,
      );
    } on WorkSessionSupersededException {
      await _markSessionSuperseded(
        current,
        uid: uid,
        sessionId: sessionId,
        sessionGeneration: sessionGeneration,
        trackingGeneration: trackingGeneration,
      );
    } catch (_) {
      if (_isCurrentSession(
        trackingGeneration,
        uid,
        sessionId,
        sessionGeneration,
      )) {
        _setState(GpsTrackingState.controlPending);
      }
    } finally {
      _controlUpdateInProgress = false;
    }
  }

  Future<void> _markSessionSuperseded(
    WorkSession session, {
    required String uid,
    required String sessionId,
    required int sessionGeneration,
    required int trackingGeneration,
  }) async {
    if (!_isCurrentSession(
      trackingGeneration,
      uid,
      sessionId,
      sessionGeneration,
    )) {
      return;
    }
    final WorkSession superseded = session.copyWith(
      status: WorkSessionLocalStatus.superseded,
      endPendingSync: false,
    );
    try {
      await _workSessionStore.write(superseded);
    } catch (_) {}
    if (!_isCurrentSession(
      trackingGeneration,
      uid,
      sessionId,
      sessionGeneration,
    )) {
      return;
    }
    stopTracking();
    _workSession = superseded;
    _setState(GpsTrackingState.sessionSuperseded);
  }

  void _acceptPosition(
    Position position, {
    bool requestImmediateUpload = false,
  }) {
    if (!_trackingEnabled || !_trackingRequested) return;
    final UserModel? user = _sessionUser;
    final WorkSession? session = _workSession;
    if (user == null ||
        session == null ||
        !session.isAcknowledged ||
        session.status != WorkSessionLocalStatus.active ||
        !_localStore.isActive(user.uid)) {
      return;
    }
    final Position? current = _currentPosition;
    if (current != null && position.timestamp.isBefore(current.timestamp)) {
      return;
    }
    _currentPosition = position;
    _retryTimer?.cancel();
    _retryTimer = null;
    final bool reliable = _isUsableTrackingFix(position, now: DateTime.now());
    _state = !reliable
        ? GpsTrackingState.unreliableFix
        : _sessionNeedsSync
        ? GpsTrackingState.syncPending
        : GpsTrackingState.tracking;
    notifyListeners();
    if (requestImmediateUpload) _awaitingImmediateUpload = true;
    if (reliable && _awaitingImmediateUpload) {
      _awaitingImmediateUpload = false;
      unawaited(
        _uploadCurrentLocation(generation: _trackingGeneration, uid: user.uid),
      );
    }
  }

  Future<void> _handleStreamError(int generation, String uid) async {
    if (!_isCurrentGeneration(generation)) return;
    await _pausePositionStream(GpsTrackingState.error, generation: generation);
    if (!_isCurrentGeneration(generation) || _retryAttempt >= 3) return;
    final int seconds = 5 * (1 << _retryAttempt);
    _retryAttempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (_isCurrentGeneration(generation)) {
        final UserModel? user = _sessionUser;
        if (user != null && user.uid == uid) {
          unawaited(
            _ensureTracking(
              forceCheck: true,
              generation: generation,
              user: user,
            ),
          );
        }
      }
    });
  }

  Future<LocationPermission?> _resolveLocationPermission({
    required bool allowPrompt,
  }) {
    return _permissionGate.resolve(
      () => _requestLocationPermission(allowPrompt: allowPrompt),
    );
  }

  Future<LocationPermission?> _requestLocationPermission({
    required bool allowPrompt,
  }) async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (allowPrompt && permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission;
    } catch (_) {
      return null;
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _notificationChannel.invokeMethod<void>('request');
    } catch (_) {}
  }

  Future<void> _pausePositionStream(
    GpsTrackingState nextState, {
    required int generation,
  }) async {
    if (!_isCurrentGeneration(generation)) return;
    final StreamSubscription<Position>? subscription = _positionSubscription;
    _positionSubscription = null;
    await subscription?.cancel();
    if (!_isCurrentGeneration(generation)) return;
    _uploadTimer?.cancel();
    _uploadTimer = null;
    _isTracking = false;
    _setState(nextState);
  }

  Future<void> _uploadCurrentLocation({
    required int generation,
    required String uid,
  }) {
    final Future<void>? active = _uploadFuture;
    if (active != null) return active;
    late final Future<void> next;
    next = _performLocationUpload(generation: generation, uid: uid)
        .whenComplete(() {
          if (identical(_uploadFuture, next)) _uploadFuture = null;
          if (_isCurrentOwner(generation, uid)) {
            _scheduleNextUpload(
              generation: generation,
              uid: uid,
              delay: _uploadRetryDelay(),
            );
          }
        });
    _uploadFuture = next;
    return next;
  }

  Future<void> _performLocationUpload({
    required int generation,
    required String uid,
  }) async {
    if (!_trackingEnabled ||
        !_trackingRequested ||
        !_isCurrentOwner(generation, uid) ||
        _controlUpdateInProgress) {
      return;
    }
    final UserModel? user = _sessionUser;
    WorkSession? session = _workSession;
    Position? position = reliableCurrentPosition;
    if (user == null ||
        session == null ||
        !session.isAcknowledged ||
        session.status != WorkSessionLocalStatus.active ||
        session.uid != uid ||
        session.sessionId.isEmpty) {
      return;
    }
    final DateTime now = DateTime.now();
    if (position == null ||
        now.difference(position.timestamp) > const Duration(seconds: 30) ||
        _lastUploadedCapturedAt == position.timestamp) {
      position = await acquireLocationFix(
        isUsable: (Position p) => _isUsableTrackingFix(p, now: DateTime.now()),
        preciseWait: const Duration(seconds: 10),
        coarseWait: const Duration(seconds: 8),
      );
      if (position == null) {
        if (_isCurrentOwner(generation, uid)) {
          _uploadRetryAttempt++;
          _setState(GpsTrackingState.unreliableFix);
        }
        return;
      }
      if (!_isCurrentOwner(generation, uid)) return;
      _acceptPosition(position);
    }
    final Position candidate = position;
    if (!_isUsableTrackingFix(candidate, now: DateTime.now())) {
      _uploadRetryAttempt++;
      _setState(GpsTrackingState.unreliableFix);
      return;
    }
    if (_lastUploadedCapturedAt == candidate.timestamp) return;
    session = _workSession;
    if (session == null ||
        session.status != WorkSessionLocalStatus.active ||
        session.sessionId.isEmpty) {
      return;
    }

    Position uploadPosition = candidate;
    final Position? pendingPosition = _pendingUploadPosition;
    final int? pendingSequence = _pendingUploadSequence;
    if (pendingPosition != null &&
        pendingSequence != null &&
        pendingPosition.timestamp != uploadPosition.timestamp) {
      WorkSessionServerRecord server;
      try {
        server = await (_firestoreService ??= FirestoreService())
            .readWorkSession(uid);
      } catch (_) {
        _sessionNeedsSync = true;
        _uploadRetryAttempt++;
        await _holdOfflineFix(
          session,
          uploadPosition,
          pendingSequence + 1,
          generation: generation,
          uid: uid,
        );
        _setState(GpsTrackingState.syncPending);
        return;
      }
      if (!_isCurrentOwner(generation, uid)) return;
      if (!server.isActive ||
          server.sessionId != session.sessionId ||
          server.generation != session.generation) {
        await _markSessionSuperseded(
          session,
          uid: uid,
          sessionId: session.sessionId,
          sessionGeneration: session.generation,
          trackingGeneration: generation,
        );
        return;
      }
      if (server.lastFixSequence >= pendingSequence) {
        if (server.lastFixSequence == pendingSequence &&
            server.deviceCapturedAt != pendingPosition.timestamp.toUtc()) {
          _sessionNeedsSync = true;
          _setState(GpsTrackingState.syncFailed);
          return;
        }
        session = session.copyWith(
          lastFixSequence: server.lastFixSequence,
          trackingMode: server.trackingMode,
          controlRevision: server.appliedControlRevision,
          appliedControlRevision: server.appliedControlRevision,
          lastBreadcrumbCapturedAt: server.lastBreadcrumbCapturedAt,
          clearLastBreadcrumbCapturedAt:
              server.lastBreadcrumbCapturedAt == null,
        );
        _lastUploadedCapturedAt = server.deviceCapturedAt;
        _lastUploadedLatitude = server.latitude;
        _lastUploadedLongitude = server.longitude;
        _pendingUploadPosition = null;
        _pendingUploadSequence = null;
        if (server.deviceCapturedAt != null &&
            !uploadPosition.timestamp.toUtc().isAfter(
              server.deviceCapturedAt!,
            )) {
          _workSession = session;
          await _workSessionStore.write(session);
          return;
        }
      } else {
        _pendingUploadPosition = null;
        _pendingUploadSequence = null;
      }
      _workSession = session;
      try {
        await _workSessionStore.write(session);
      } catch (_) {
        _sessionNeedsSync = true;
        _setState(GpsTrackingState.syncFailed);
        return;
      }
      if (!_isCurrentOwner(generation, uid)) return;
    } else if (pendingPosition != null &&
        pendingSequence != null &&
        pendingPosition.timestamp == uploadPosition.timestamp) {
      uploadPosition = pendingPosition;
    }
    final int uploadSequence =
        pendingSequence != null && _pendingUploadPosition != null
        ? pendingSequence
        : session.lastFixSequence + 1;
    final WorkSession attempted = session.copyWith(
      lastFixSequence: uploadSequence,
    );
    try {
      await _workSessionStore.write(attempted);
    } catch (_) {
      _sessionNeedsSync = true;
      _uploadRetryAttempt++;
      _setState(GpsTrackingState.syncFailed);
      return;
    }
    if (!_isCurrentOwner(generation, uid)) return;
    _workSession = attempted;
    _pendingUploadPosition = uploadPosition;
    _pendingUploadSequence = uploadSequence;

    final DateTime capturedAt = uploadPosition.timestamp.toUtc();
    final DateTime? previousBreadcrumbAt = session.lastBreadcrumbCapturedAt
        ?.toUtc();
    final bool writeBreadcrumb =
        previousBreadcrumbAt == null ||
        !capturedAt.isBefore(
          previousBreadcrumbAt.add(_breadcrumbMinimumInterval),
        );
    try {
      await (_firestoreService ??= FirestoreService()).updateGpsLocation(
        user: user,
        session: attempted,
        fixSequence: uploadSequence,
        latitude: uploadPosition.latitude,
        longitude: uploadPosition.longitude,
        accuracyMeters: uploadPosition.accuracy,
        deviceCapturedAt: uploadPosition.timestamp,
        isMocked: uploadPosition.isMocked,
        writeBreadcrumb: writeBreadcrumb,
      );
      if (!_isCurrentOwner(generation, uid)) return;
      final WorkSession synced = attempted.copyWith(
        lastBreadcrumbCapturedAt: writeBreadcrumb
            ? capturedAt
            : session.lastBreadcrumbCapturedAt,
        clearLastBreadcrumbCapturedAt:
            !writeBreadcrumb && session.lastBreadcrumbCapturedAt == null,
      );
      _workSession = synced;
      _lastUploadedCapturedAt = uploadPosition.timestamp;
      _lastUploadedLatitude = uploadPosition.latitude;
      _lastUploadedLongitude = uploadPosition.longitude;
      if (_pendingUploadPosition?.timestamp == uploadPosition.timestamp) {
        _pendingUploadPosition = null;
        _pendingUploadSequence = null;
      }
      _sessionNeedsSync = false;
      _uploadRetryAttempt = 0;
      if (writeBreadcrumb) {
        try {
          await _workSessionStore.write(synced);
        } catch (_) {
          _setState(GpsTrackingState.syncFailed);
          return;
        }
      }
      if (!_isCurrentOwner(generation, uid)) return;
      _setState(GpsTrackingState.tracking);
      await _settleBacklog(user, attempted, uploadSequence);
    } on WorkSessionSupersededException {
      await _markSessionSuperseded(
        session,
        uid: uid,
        sessionId: session.sessionId,
        sessionGeneration: session.generation,
        trackingGeneration: generation,
      );
    } catch (error) {
      if (!_isCurrentOwner(generation, uid)) return;
      _sessionNeedsSync = true;
      _uploadRetryAttempt++;
      if (isTransientFirebaseFailure(error)) {
        await _backlogFix(uid, attempted, uploadPosition, uploadSequence);
      }
      _setState(
        error is FirebaseException && error.code == 'permission-denied'
            ? GpsTrackingState.syncFailed
            : GpsTrackingState.syncPending,
      );
    }
  }

  Future<void> _backlogFix(
    String uid,
    WorkSession session,
    Position position,
    int sequence,
  ) async {
    try {
      await _backlog.add(
        uid,
        GpsBacklogFix(
          sessionId: session.sessionId,
          generation: session.generation,
          fixSequence: sequence,
          latitude: position.latitude,
          longitude: position.longitude,
          accuracyMeters: position.accuracy,
          deviceCapturedAt: position.timestamp.toUtc(),
        ),
      );
    } catch (_) {}
  }

  Future<void> _holdOfflineFix(
    WorkSession session,
    Position position,
    int sequence, {
    required int generation,
    required String uid,
  }) async {
    final WorkSession attempted = session.copyWith(lastFixSequence: sequence);
    try {
      await _workSessionStore.write(attempted);
    } catch (_) {
      return;
    }
    if (!_isCurrentOwner(generation, uid)) return;
    _workSession = attempted;
    _pendingUploadPosition = position;
    _pendingUploadSequence = sequence;
    await _backlogFix(uid, attempted, position, sequence);
  }

  Future<void> _runBacklogFlush(Future<void> Function() body) async {
    if (_backlogFlush != null) return;
    final Future<void> run = body().catchError((Object _) {});
    _backlogFlush = run;
    try {
      await run;
    } finally {
      _backlogFlush = null;
    }
  }

  Future<void> _settleBacklog(
    UserModel user,
    WorkSession session,
    int uploadedSequence,
  ) => _runBacklogFlush(() async {
    await _backlog.removeSequence(
      user.uid,
      sessionId: session.sessionId,
      generation: session.generation,
      fixSequence: uploadedSequence,
    );
    if (!await _backlog.hasAny(user.uid)) return;
    await (_firestoreService ??= FirestoreService()).flushGpsBacklog(
      user: user,
      store: _backlog,
    );
  });

  Future<bool> _flushBacklogBeforeNewSession(UserModel user) async {
    final Future<void>? running = _backlogFlush;
    if (running != null) await running;
    try {
      await _flushHeldTrack(user);
    } catch (_) {}
    return !await _backlog.hasAny(user.uid);
  }

  void _scheduleNextUpload({
    required int generation,
    required String uid,
    Duration? delay,
  }) {
    _uploadTimer?.cancel();
    _uploadTimer = null;
    final WorkSession? session = _workSession;
    if (!_isCurrentOwner(generation, uid) ||
        !_isTracking ||
        session == null ||
        session.status != WorkSessionLocalStatus.active ||
        !session.isAcknowledged) {
      return;
    }
    final Duration nextDelay = delay ?? _modeCadence(session.trackingMode);
    _uploadTimer = Timer(nextDelay, () {
      _uploadTimer = null;
      if (_isCurrentOwner(generation, uid)) {
        unawaited(_uploadCurrentLocation(generation: generation, uid: uid));
      }
    });
  }

  Duration _modeCadence(TrackingMode mode) {
    final Position? current = reliableCurrentPosition;
    if (current == null) {
      return Duration(seconds: mode.movingIntervalSeconds);
    }
    final bool moving = current.speed.isFinite && current.speed >= 1.0;
    final bool changedPosition =
        _lastUploadedLatitude != null &&
        _lastUploadedLongitude != null &&
        Geolocator.distanceBetween(
              _lastUploadedLatitude!,
              _lastUploadedLongitude!,
              current.latitude,
              current.longitude,
            ) >=
            _movementThresholdMeters;
    return Duration(
      seconds: moving || changedPosition
          ? mode.movingIntervalSeconds
          : mode.stationaryIntervalSeconds,
    );
  }

  Duration? _uploadRetryDelay() {
    if (_uploadRetryAttempt <= 0) return null;
    final int exponent = (_uploadRetryAttempt - 1).clamp(0, 6);
    final int seconds = (5 * (1 << exponent)).clamp(5, 300);
    return Duration(seconds: seconds);
  }

  void _setState(GpsTrackingState value) {
    if (_state == value) return;
    _state = value;
    notifyListeners();
  }

  Future<void> endWork({String? uid, UserModel? user}) async {
    final WorkSession? current = _workSession;
    final String ownerUid =
        (uid ?? current?.uid ?? FirebaseAuth.instance.currentUser?.uid ?? '')
            .trim();
    final currentIdentity = _localStore.lease(ownerUid);
    if (ownerUid.isEmpty) {
      stopTracking();
      return;
    }

    WorkSession? session;
    try {
      session = current?.uid == ownerUid
          ? current
          : await _workSessionStore.read(ownerUid);
    } catch (_) {
      if (_localStore.isActive(ownerUid)) {
        _setState(GpsTrackingState.syncFailed);
      }
      return;
    }
    final Future<void>? activeStart = _startFuture;
    final UserModel? trackingUser = _sessionUser?.uid == ownerUid
        ? _sessionUser
        : null;
    if (_sessionUser?.uid == ownerUid || _workSession?.uid == ownerUid) {
      stopTracking();
    }
    if (session == null) {
      if (_localStore.isActive(ownerUid)) {
        _setState(GpsTrackingState.sessionEnded);
      }
      return;
    }

    final bool starting = session.status == WorkSessionLocalStatus.starting;
    final int expectedGeneration = starting
        ? session.previousGeneration + 1
        : session.generation;
    WorkSession ended = session.copyWith(
      generation: expectedGeneration,
      status: WorkSessionLocalStatus.ended,
      endPendingSync: expectedGeneration > 0,
    );
    try {
      await _workSessionStore.write(ended);
    } catch (_) {
      if (_localStore.isActive(ownerUid)) {
        _setState(GpsTrackingState.syncFailed);
      }
      return;
    }
    if (_localStore.isActive(ownerUid)) {
      _workSession = ended;
      _sessionNeedsSync = ended.endPendingSync;
      _setState(
        ended.endPendingSync
            ? GpsTrackingState.sessionEndPending
            : GpsTrackingState.sessionEnded,
      );
    }
    if (expectedGeneration <= 0) return;

    if (activeStart != null) {
      try {
        await activeStart;
      } catch (_) {}
    }
    if (!currentIdentity()) return;
    UserModel? flushUser;
    try {
      final FirestoreService service = _firestoreService ??= FirestoreService();
      final WorkSessionServerRecord server = await service.readWorkSession(
        ownerUid,
      );
      if (!currentIdentity()) return;
      if (server.sessionId == ended.sessionId &&
          server.generation == expectedGeneration &&
          server.isActive) {
        final UserModel? publishUser = await _resolveEndUser(
          service,
          ownerUid,
          user?.uid == ownerUid ? user : trackingUser,
        );
        flushUser = publishUser;
        if (publishUser != null) {
          await service.publishHeldTrack(
            user: publishUser,
            session: ended,
            store: _backlog,
          );
        } else if (await _hasHeldFixes(ownerUid, ended)) {
          throw StateError('The held location points need the user profile.');
        }
        await service.endWorkSession(
          uid: ownerUid,
          sessionId: ended.sessionId,
          generation: expectedGeneration,
        );
      }
      if (!currentIdentity()) return;
      ended = ended.copyWith(endPendingSync: false);
      await _workSessionStore.write(ended);
      if (_localStore.isActive(ownerUid)) {
        _workSession = ended;
        _sessionNeedsSync = false;
        _setState(GpsTrackingState.sessionEnded);
      }
    } catch (_) {
      if (_localStore.isActive(ownerUid)) {
        _sessionNeedsSync = true;
        _setState(GpsTrackingState.sessionEndPending);
      }
      return;
    }
    if (flushUser != null) await _flushHeldTrack(flushUser);
  }

  Future<void> _flushHeldPoints() async {
    try {
      final String uid =
          (_sessionUser?.uid ?? FirebaseAuth.instance.currentUser?.uid ?? '')
              .trim();
      if (uid.isEmpty || !await _backlog.hasAny(uid)) return;
      final FirestoreService service = _firestoreService ??= FirestoreService();
      final UserModel? user = _sessionUser?.uid == uid
          ? _sessionUser
          : await service.getUser(uid);
      if (user != null) await _flushHeldTrack(user);
    } catch (_) {}
  }

  Future<void> _flushHeldTrack(UserModel user) => _runBacklogFlush(
    () => (_firestoreService ??= FirestoreService()).flushHeldTrack(
      user: user,
      store: _backlog,
    ),
  );

  Future<UserModel?> _resolveEndUser(
    FirestoreService service,
    String uid,
    UserModel? known,
  ) async {
    if (known != null) return known;
    try {
      return await service.getUser(uid);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasHeldFixes(String uid, WorkSession session) async {
    final List<GpsBacklogFix> rows = await _backlog.readAll(uid);
    return rows.any(
      (GpsBacklogFix fix) =>
          fix.sessionId == session.sessionId &&
          fix.generation == session.generation,
    );
  }

  void stopTracking() {
    _trackingGeneration++;
    _trackingRequested = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
    unawaited(_serviceStatusSubscription?.cancel());
    _serviceStatusSubscription = null;
    unawaited(_controlSubscription?.cancel());
    _controlSubscription = null;
    _controlSubscriptionUid = '';
    _controlSubscriptionSessionId = '';
    _controlSubscriptionGeneration = 0;
    _uploadTimer?.cancel();
    _uploadTimer = null;
    _isTracking = false;
    _currentPosition = null;
    _sessionUser = null;
    _pendingUploadPosition = null;
    _pendingUploadSequence = null;
    _lastUploadedLatitude = null;
    _lastUploadedLongitude = null;
    _controlUpdateInProgress = false;
    _state = GpsTrackingState.idle;
    notifyListeners();
  }

  bool _isCurrentGeneration(int generation) {
    return isCurrentTrackingGeneration(
      trackingRequested: _trackingRequested,
      expectedGeneration: generation,
      currentGeneration: _trackingGeneration,
    );
  }

  bool _isCurrentOwner(int generation, String uid) =>
      _isCurrentGeneration(generation) &&
      _sessionUser?.uid == uid &&
      _localStore.isActive(uid);

  bool _isCurrentSession(
    int trackingGeneration,
    String uid,
    String sessionId,
    int sessionGeneration,
  ) {
    final WorkSession? session = _workSession;
    return _isCurrentOwner(trackingGeneration, uid) &&
        session != null &&
        session.uid == uid &&
        session.sessionId == sessionId &&
        session.generation == sessionGeneration &&
        session.status == WorkSessionLocalStatus.active;
  }

  @override
  void dispose() {
    stopTracking();
    super.dispose();
  }
}

DeviceLocationFix _toFix(Position position) => DeviceLocationFix(
  latitude: position.latitude,
  longitude: position.longitude,
  accuracyMeters: position.accuracy,
  capturedAt: position.timestamp,
  isMocked: position.isMocked,
);

bool _isUsableTrackingFix(Position? position, {required DateTime now}) {
  if (position == null ||
      !position.latitude.isFinite ||
      !position.longitude.isFinite ||
      position.latitude < -90 ||
      position.latitude > 90 ||
      position.longitude < -180 ||
      position.longitude > 180 ||
      (position.latitude == 0 && position.longitude == 0) ||
      position.isMocked ||
      !position.accuracy.isFinite ||
      position.accuracy < 0 ||
      position.accuracy > _trackingFixMaxAccuracyMeters) {
    return false;
  }
  final Duration age = now.difference(position.timestamp);
  return age >= -kLocationClockSkewTolerance && age <= _trackingFixMaxAge;
}
