import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/user_model.dart';
import '../models/tracking_control.dart';
import '../models/work_session.dart';
import '../utils/canonical_profile.dart';
import 'gps_backlog.dart';

enum WorkSessionEndResult { ended, superseded }

class ResolvedUserProfile {
  const ResolvedUserProfile({required this.id, required this.data});

  final String id;
  final Map<String, dynamic> data;
}

class WorkSessionServerRecord {
  const WorkSessionServerRecord({
    required this.exists,
    required this.sessionId,
    required this.generation,
    required this.lastFixSequence,
    required this.isActive,
    required this.trackingMode,
    required this.appliedControlRevision,
    this.lastBreadcrumbCapturedAt,
    this.deviceCapturedAt,
    this.latitude,
    this.longitude,
    this.endedReason = '',
  });

  final bool exists;
  final String sessionId;
  final int generation;
  final int lastFixSequence;
  final bool isActive;
  final TrackingMode trackingMode;
  final int appliedControlRevision;
  final DateTime? lastBreadcrumbCapturedAt;
  final DateTime? deviceCapturedAt;
  final double? latitude;
  final double? longitude;
  final String endedReason;

  bool get endedByCompanyPause =>
      !isActive && endedReason == 'company_paused';

  factory WorkSessionServerRecord.fromMap(
    Map<String, dynamic>? data, {
    required bool exists,
  }) {
    int integer(Object? value) {
      if (value is! num || value.toDouble() != value.toInt().toDouble()) {
        return 0;
      }
      return value.toInt().clamp(0, 0x7fffffff);
    }

    return WorkSessionServerRecord(
      exists: exists,
      sessionId: (data?['activeSessionId'] as String? ?? '').trim(),
      generation: integer(data?['activeSessionGeneration']),
      lastFixSequence: integer(data?['lastFixSequence']),
      isActive: data?['workSessionStatus'] == 'active',
      trackingMode:
          TrackingMode.tryParse(data?['trackingMode']) ??
          TrackingMode.batterySaver,
      appliedControlRevision: integer(data?['appliedControlRevision']),
      lastBreadcrumbCapturedAt: _readDateTime(
        data?['lastBreadcrumbCapturedAt'],
      ),
      deviceCapturedAt: _readDateTime(data?['deviceCapturedAt']),
      latitude: _readDouble(data?['latitude']),
      longitude: _readDouble(data?['longitude']),
      endedReason: (data?['endedReason'] as String? ?? '').trim(),
    );
  }
}

class WorkSessionStartResult {
  const WorkSessionStartResult({
    required this.accepted,
    required this.sessionId,
    required this.generation,
    required this.lastFixSequence,
    required this.userDocumentId,
    required this.trackingMode,
    required this.controlRevision,
    required this.appliedControlRevision,
  });

  final bool accepted;
  final String sessionId;
  final int generation;
  final int lastFixSequence;
  final String userDocumentId;
  final TrackingMode trackingMode;
  final int controlRevision;
  final int appliedControlRevision;
}

class FirestoreService {
  FirestoreService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Stream<TrackingControl> watchTrackingControl(String uid) {
    _requireCurrentOwner(uid);
    return _db.collection('tracking_controls').doc(uid.trim()).snapshots().map((
      DocumentSnapshot<Map<String, dynamic>> snapshot,
    ) {
      if (!snapshot.exists) return const TrackingControl.defaultValue();
      final Map<String, dynamic> data = snapshot.data() ?? <String, dynamic>{};
      data['updatedAt'] = _readDateTime(data['updatedAt']);
      return TrackingControl.fromMap(data);
    });
  }

  Future<UserModel?> getUser(
    String uid, {
    Source source = Source.serverAndCache,
  }) async {
    final String authUid = uid.trim();
    if (authUid.isEmpty) return null;

    final profile = await resolveUserProfile(
      authUid,
      email: FirebaseAuth.instance.currentUser?.email,
      source: source,
    );
    if (profile == null) return null;

    return UserModel.fromMap(<String, dynamic>{
      ...profile.data,
      'uid': authUid,
      'userDocId': profile.id,
    }, profile.id);
  }

  Future<void> updateUserSettings(
    String uid,
    Map<String, dynamic> settings,
  ) async {
    final documentId = await _resolveUserDocumentId(uid, '');
    if (documentId == null || documentId.isEmpty) {
      throw StateError('The canonical user profile could not be resolved.');
    }
    await _db.collection('users').doc(documentId).update(settings);
  }

  Future<void> updateUserProfile(
    String uid,
    Map<String, dynamic> profileData,
  ) async {
    final documentId = await _resolveUserDocumentId(uid, '');
    if (documentId == null || documentId.isEmpty) {
      throw StateError('The canonical user profile could not be resolved.');
    }
    await _db
        .collection('users')
        .doc(documentId)
        .set(profileData, SetOptions(merge: true));
  }

  Future<WorkSessionServerRecord> readWorkSession(String uid) async {
    _requireCurrentOwner(uid);
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await _db
        .collection('live_tracking')
        .doc(uid.trim())
        .get(const GetOptions(source: Source.server));
    return WorkSessionServerRecord.fromMap(
      snapshot.data(),
      exists: snapshot.exists,
    );
  }

  Future<WorkSessionStartResult> startWorkSession({
    required UserModel user,
    required String sessionId,
    required String expectedSessionId,
    required int expectedGeneration,
  }) async {
    _requireCurrentOwner(user.uid);
    if (!user.hasSalespersonRole || !user.hasActiveAccount) {
      throw StateError('Only an active salesperson can start Work.');
    }
    if (sessionId.trim().isEmpty || expectedGeneration < 0) {
      throw ArgumentError('The work session identity is invalid.');
    }
    final DocumentReference<Map<String, dynamic>> reference = _db
        .collection('live_tracking')
        .doc(user.uid.trim());
    final DocumentReference<Map<String, dynamic>> controlReference = _db
        .collection('tracking_controls')
        .doc(user.uid.trim());
    final String? userDocumentId = user.userDocId.isNotEmpty
        ? user.userDocId
        : await _resolveUserDocumentId(user.uid, user.email);
    if (userDocumentId == null || userDocumentId.isEmpty) {
      throw StateError('The canonical user profile could not be resolved.');
    }
    final Map<String, dynamic> identity = _trackingIdentity(user);

    return _db.runTransaction<WorkSessionStartResult>((
      Transaction transaction,
    ) async {
      final List<DocumentSnapshot<Map<String, dynamic>>> reads =
          await Future.wait(<Future<DocumentSnapshot<Map<String, dynamic>>>>[
            transaction.get(reference),
            transaction.get(controlReference),
          ]);
      final DocumentSnapshot<Map<String, dynamic>> snapshot = reads[0];
      final DocumentSnapshot<Map<String, dynamic>> controlSnapshot = reads[1];
      final TrackingControl control = _trackingControlFromSnapshot(
        controlSnapshot,
      );
      final Map<String, dynamic> old = snapshot.data() ?? <String, dynamic>{};
      final WorkSessionServerRecord current = WorkSessionServerRecord.fromMap(
        old,
        exists: snapshot.exists,
      );

      if (current.sessionId == sessionId &&
          current.generation == expectedGeneration + 1 &&
          current.isActive) {
        return WorkSessionStartResult(
          accepted: true,
          sessionId: current.sessionId,
          generation: current.generation,
          lastFixSequence: current.lastFixSequence,
          userDocumentId: userDocumentId,
          trackingMode: current.trackingMode,
          controlRevision: control.revision,
          appliedControlRevision: current.appliedControlRevision,
        );
      }

      if (current.generation != expectedGeneration ||
          current.sessionId != expectedSessionId.trim()) {
        return WorkSessionStartResult(
          accepted: false,
          sessionId: '',
          generation: 0,
          lastFixSequence: 0,
          userDocumentId: userDocumentId,
          trackingMode: control.mode,
          controlRevision: control.revision,
          appliedControlRevision: 0,
        );
      }

      final int nextGeneration = current.generation + 1;
      transaction.set(reference, <String, dynamic>{
        if (!snapshot.exists) ...identity,
        'activeSessionId': sessionId,
        'activeSessionGeneration': nextGeneration,
        'lastFixSequence': 0,
        'workSessionStatus': 'active',
        'status': 'starting',
        'workSessionStartedAt': FieldValue.serverTimestamp(),
        if (snapshot.exists) 'workSessionEndedAt': FieldValue.delete(),
        if (snapshot.exists) 'lastBreadcrumbCapturedAt': FieldValue.delete(),
        if (current.endedReason.isNotEmpty) 'endedReason': FieldValue.delete(),
        'trackingMode': control.mode.wireValue,
        'appliedControlRevision': control.revision,
      }, SetOptions(merge: true));
      return WorkSessionStartResult(
        accepted: true,
        sessionId: sessionId,
        generation: nextGeneration,
        lastFixSequence: 0,
        userDocumentId: userDocumentId,
        trackingMode: control.mode,
        controlRevision: control.revision,
        appliedControlRevision: control.revision,
      );
    });
  }

  Future<TrackingControl> acknowledgeTrackingControl({
    required String uid,
    required String sessionId,
    required int generation,
  }) async {
    _requireCurrentOwner(uid);
    final String ownerUid = uid.trim();
    final DocumentReference<Map<String, dynamic>> controlReference = _db
        .collection('tracking_controls')
        .doc(ownerUid);
    final DocumentReference<Map<String, dynamic>> liveReference = _db
        .collection('live_tracking')
        .doc(ownerUid);
    return _db.runTransaction<TrackingControl>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> controlSnapshot =
          await transaction.get(controlReference);
      final DocumentSnapshot<Map<String, dynamic>> liveSnapshot =
          await transaction.get(liveReference);
      final WorkSessionServerRecord live = WorkSessionServerRecord.fromMap(
        liveSnapshot.data(),
        exists: liveSnapshot.exists,
      );
      if (!live.isActive ||
          live.sessionId != sessionId ||
          live.generation != generation) {
        throw const WorkSessionSupersededException();
      }
      final TrackingControl control = _trackingControlFromSnapshot(
        controlSnapshot,
      );
      if (live.appliedControlRevision == control.revision &&
          live.trackingMode == control.mode) {
        return control;
      }
      transaction.set(liveReference, <String, dynamic>{
        'activeSessionId': sessionId,
        'activeSessionGeneration': generation,
        'workSessionStatus': 'active',
        'trackingMode': control.mode.wireValue,
        'appliedControlRevision': control.revision,
      }, SetOptions(merge: true));
      return control;
    });
  }

  Future<WorkSessionEndResult> endWorkSession({
    required String uid,
    required String sessionId,
    required int generation,
  }) async {
    _requireCurrentOwner(uid);
    final DocumentReference<Map<String, dynamic>> reference = _db
        .collection('live_tracking')
        .doc(uid.trim());
    return _db.runTransaction<WorkSessionEndResult>((
      Transaction transaction,
    ) async {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(reference);
      final WorkSessionServerRecord current = WorkSessionServerRecord.fromMap(
        snapshot.data(),
        exists: snapshot.exists,
      );
      if (!current.isActive ||
          current.sessionId != sessionId ||
          current.generation != generation) {
        return WorkSessionEndResult.superseded;
      }
      transaction.set(reference, <String, dynamic>{
        'activeSessionId': sessionId,
        'activeSessionGeneration': generation,
        'lastFixSequence': current.lastFixSequence,
        'workSessionStatus': 'ended',
        'status': 'inactive',
        'workSessionEndedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return WorkSessionEndResult.ended;
    });
  }

  void _requireCurrentOwner(String uid) {
    final String ownerUid = uid.trim();
    if (ownerUid.isEmpty ||
        FirebaseAuth.instance.currentUser?.uid != ownerUid) {
      throw StateError('The authenticated account changed.');
    }
  }

  TrackingControl _trackingControlFromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    if (!snapshot.exists) return const TrackingControl.defaultValue();
    final Map<String, dynamic> data = snapshot.data() ?? <String, dynamic>{};
    data['updatedAt'] = _readDateTime(data['updatedAt']);
    return TrackingControl.fromMap(data);
  }

  Map<String, dynamic> _trackingIdentity(UserModel user) {
    final String staffId = user.identityCode.isEmpty
        ? user.uid
        : user.identityCode;
    return <String, dynamic>{
      'uid': user.uid,
      'userUid': user.uid,
      'salesmanUid': user.uid,
      'salesmanId': staffId,
      'salesmanName': user.effectiveDisplayName,
      'salesmanEmail': user.email,
      'submittedByUid': user.uid,
      'submittedByEmail': user.email,
      'submittedByName': user.effectiveDisplayName,
      'staffId': staffId,
      'employeeCode': staffId,
      'salesmanCode': staffId,
      'salesman_code': staffId,
      if (user.branchId.trim().isNotEmpty) 'branchId': user.branchId.trim(),
    };
  }

  Future<String?> _resolveUserDocumentId(String uid, String email) async {
    final profile = await resolveUserProfile(uid, email: email);
    return profile?.id;
  }

  Future<ResolvedUserProfile?> resolveUserProfile(
    String uid, {
    String? email,
    Source source = Source.serverAndCache,
    Duration? timeout,
  }) async {
    final String authUid = uid.trim();
    if (authUid.isEmpty) return null;
    final options = GetOptions(source: source);

    Future<DocumentSnapshot<Map<String, dynamic>>> readDocument(
      DocumentReference<Map<String, dynamic>> reference,
    ) {
      final Future<DocumentSnapshot<Map<String, dynamic>>> read = reference.get(
        options,
      );
      return timeout == null ? read : read.timeout(timeout);
    }

    Future<QuerySnapshot<Map<String, dynamic>>> readQuery(
      Query<Map<String, dynamic>> query,
    ) {
      final Future<QuerySnapshot<Map<String, dynamic>>> read = query.get(
        options,
      );
      return timeout == null ? read : read.timeout(timeout);
    }

    final access = await readDocument(
      _db.collection('user_access').doc(authUid),
    );
    if (access.exists) {
      final accessData = access.data();
      if (accessData == null) return null;
      if (accessData['accessVersion'] == 2) {
        final Map<String, dynamic>? identity = strictActiveV2Identity(
          authUid,
          accessData,
        );
        if (identity == null) {
          final Object? blockedStatus = accessData['status'];
          if (accessData['uid'] == authUid &&
              blockedStatus is String &&
              blockedStatus != 'active') {
            return ResolvedUserProfile(
              id: authUid,
              data: <String, dynamic>{
                'uid': authUid,
                'role': accessData['role'],
                'employeeCode': accessData['employeeCode'],
                'branchId': accessData['branchId'],
                'isActive': false,
                'accountStatus': blockedStatus,
                'email': accessData['email'] is String
                    ? accessData['email']
                    : '',
              },
            );
          }
          return null;
        }
        final String? displayId = canonicalProfileIdFromAccess(accessData);
        Map<String, dynamic> display = <String, dynamic>{};
        if (displayId != null) {
          try {
            final DocumentSnapshot<Map<String, dynamic>> canonical =
                await readDocument(_db.collection('users').doc(displayId));
            display = canonical.data() ?? <String, dynamic>{};
          } catch (_) {}
        }
        return ResolvedUserProfile(
          id: displayId ?? authUid,
          data: <String, dynamic>{
            ...display,
            ...identity,
            'isActive': true,
            'accountStatus': identity['status'],
            'email': display['email'] is String
                ? display['email']
                : accessData['email'] is String
                ? accessData['email']
                : '',
          },
        );
      }
      if (accessData['accessVersion'] != null ||
          !accessIdentityMatchesAuth(authUid, accessData)) {
        return null;
      }
      final String? indexedDocumentId = canonicalProfileIdFromAccess(
        accessData,
      );
      if (indexedDocumentId == null) return null;

      final canonical = await readDocument(
        _db.collection('users').doc(indexedDocumentId),
      );
      final canonicalData = canonical.data();
      if (!canonical.exists ||
          canonicalData == null ||
          !canonicalProfileMatchesAuth(authUid, canonicalData)) {
        return null;
      }
      return ResolvedUserProfile(id: canonical.id, data: canonicalData);
    }

    final direct = await readDocument(_db.collection('users').doc(authUid));
    if (direct.exists) {
      final directData = direct.data();
      if (directData == null ||
          !canonicalProfileMatchesAuth(authUid, directData)) {
        return null;
      }
      return ResolvedUserProfile(id: direct.id, data: directData);
    }

    final byUid = await readQuery(
      _db.collection('users').where('uid', isEqualTo: authUid).limit(2),
    );
    if (byUid.docs.length > 1) return null;
    if (byUid.docs.length == 1) {
      final doc = byUid.docs.single;
      if (!canonicalProfileMatchesAuth(authUid, doc.data())) return null;
      return ResolvedUserProfile(id: doc.id, data: doc.data());
    }

    final fallbackEmail = email?.trim() ?? '';
    if (fallbackEmail.isEmpty) return null;
    final byEmail = await readQuery(
      _db.collection('users').where('email', isEqualTo: fallbackEmail).limit(2),
    );
    if (byEmail.docs.length > 1) return null;
    if (byEmail.docs.length == 1) {
      final doc = byEmail.docs.single;
      if (!canonicalProfileMatchesAuth(authUid, doc.data())) return null;
      return ResolvedUserProfile(id: doc.id, data: doc.data());
    }
    return null;
  }

  Future<void> updateGpsLocation({
    required UserModel user,
    required WorkSession session,
    required int fixSequence,
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required DateTime deviceCapturedAt,
    required bool isMocked,
    required bool writeBreadcrumb,
  }) async {
    _requireCurrentOwner(user.uid);
    if (session.uid != user.uid ||
        !session.isAcknowledged ||
        session.status != WorkSessionLocalStatus.active ||
        session.sessionId.isEmpty ||
        fixSequence <= 0 ||
        fixSequence != session.lastFixSequence ||
        session.userDocumentId.isEmpty) {
      throw StateError('The active work session is invalid.');
    }
    final DateTime capturedAt = deviceCapturedAt.toUtc();
    final String eventId =
        'session_${user.uid}_${session.sessionId}_$fixSequence';
    final DocumentReference<Map<String, dynamic>> liveRef = _db
        .collection('live_tracking')
        .doc(user.uid);
    final DocumentReference<Map<String, dynamic>> breadcrumbRef = _db
        .collection('gps_tracking')
        .doc(eventId);

    await _db.runTransaction<void>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> liveSnapshot =
          await transaction.get(liveRef);
      final Map<String, dynamic> current =
          liveSnapshot.data() ?? <String, dynamic>{};
      final WorkSessionServerRecord server = WorkSessionServerRecord.fromMap(
        current,
        exists: liveSnapshot.exists,
      );
      if (!server.isActive ||
          server.sessionId != session.sessionId ||
          server.generation != session.generation) {
        throw const WorkSessionSupersededException();
      }
      if (server.trackingMode != session.trackingMode ||
          server.appliedControlRevision != session.appliedControlRevision) {
        throw const StaleTrackingControlException();
      }
      if (fixSequence < server.lastFixSequence) {
        throw StateError(
          'An older location fix cannot replace the latest one.',
        );
      }
      if (fixSequence == server.lastFixSequence) {
        if (_sameTrackingFix(
          current,
          latitude: latitude,
          longitude: longitude,
          deviceCapturedAt: capturedAt,
          fixSequence: fixSequence,
        )) {
          return;
        }
        throw StateError('A different location reused an accepted sequence.');
      }

      final Map<String, dynamic> livePayload = <String, dynamic>{
        'activeSessionId': session.sessionId,
        'activeSessionGeneration': session.generation,
        'lastFixSequence': fixSequence,
        'workSessionStatus': 'active',
        'trackingMode': session.trackingMode.wireValue,
        'appliedControlRevision': session.appliedControlRevision,
        'latitude': latitude,
        'longitude': longitude,
        'gpsLatitude': latitude,
        'gpsLongitude': longitude,
        'location': GeoPoint(latitude, longitude),
        'accuracy': accuracyMeters,
        'accuracyMeters': accuracyMeters,
        'deviceCapturedAt': capturedAt,
        'isMocked': isMocked,
        'locationSource': 'foreground_tracking',
        'locationVerification': 'device_captured',
        'timestamp': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
        'lastSyncedAt': FieldValue.serverTimestamp(),
        'serverReceivedAt': FieldValue.serverTimestamp(),
        'status': 'active',
        if (writeBreadcrumb) 'lastBreadcrumbCapturedAt': capturedAt,
      };
      if (writeBreadcrumb) {
        final Map<String, dynamic> breadcrumb = <String, dynamic>{
          ..._trackingIdentity(user),
          'eventId': eventId,
          'activeSessionId': session.sessionId,
          'activeSessionGeneration': session.generation,
          'fixSequence': fixSequence,
          'latitude': latitude,
          'longitude': longitude,
          'gpsLatitude': latitude,
          'gpsLongitude': longitude,
          'location': GeoPoint(latitude, longitude),
          'accuracy': accuracyMeters,
          'accuracyMeters': accuracyMeters,
          'deviceCapturedAt': capturedAt,
          'isMocked': isMocked,
          'locationSource': 'foreground_tracking',
          'locationVerification': 'device_captured',
          'timestamp': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        };
        transaction.set(breadcrumbRef, breadcrumb);
      }
      transaction.set(liveRef, livePayload, SetOptions(merge: true));
    });
  }

  Map<String, dynamic> gpsBacklogBreadcrumb(
    UserModel user,
    GpsBacklogFix fix,
  ) => <String, dynamic>{
    ..._trackingIdentity(user),
    'eventId': fix.eventId(user.uid),
    'backlog': true,
    'activeSessionId': fix.sessionId,
    'activeSessionGeneration': fix.generation,
    'fixSequence': fix.fixSequence,
    'latitude': fix.latitude,
    'longitude': fix.longitude,
    'gpsLatitude': fix.latitude,
    'gpsLongitude': fix.longitude,
    'location': GeoPoint(fix.latitude, fix.longitude),
    'accuracy': fix.accuracyMeters,
    'accuracyMeters': fix.accuracyMeters,
    'deviceCapturedAt': fix.deviceCapturedAt.toUtc(),
    'isMocked': false,
    'locationSource': 'foreground_tracking',
    'locationVerification': 'device_captured',
    'timestamp': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  };

  Future<void> publishHeldTrack({
    required UserModel user,
    required WorkSession session,
    GpsBacklogStore? store,
  }) async {
    _requireCurrentOwner(user.uid);
    final GpsBacklogStore backlog =
        store ?? GpsBacklogStore(projectId: _db.app.options.projectId);
    final List<GpsBacklogFix> held = (await backlog.readAll(user.uid))
        .where(
          (GpsBacklogFix fix) =>
              fix.sessionId == session.sessionId &&
              fix.generation == session.generation,
        )
        .toList(growable: false);
    if (held.isEmpty) return;
    final GpsBacklogFix newest = held.reduce(
      (GpsBacklogFix a, GpsBacklogFix b) =>
          a.fixSequence >= b.fixSequence ? a : b,
    );
    try {
      await updateGpsLocation(
        user: user,
        session: session.copyWith(
          status: WorkSessionLocalStatus.active,
          lastFixSequence: newest.fixSequence,
        ),
        fixSequence: newest.fixSequence,
        latitude: newest.latitude,
        longitude: newest.longitude,
        accuracyMeters: newest.accuracyMeters,
        deviceCapturedAt: newest.deviceCapturedAt,
        isMocked: false,
        writeBreadcrumb: true,
      );
      await backlog.removeAll(user.uid, <GpsBacklogFix>[newest]);
    } catch (error) {
      if (isTransientFirebaseFailure(error)) rethrow;
    }
  }

  Future<void> flushHeldTrack({
    required UserModel user,
    GpsBacklogStore? store,
  }) async {
    int written;
    do {
      written = await flushGpsBacklog(user: user, store: store);
    } while (written >= gpsBacklogWritesPerFlush);
  }

  Future<bool> _backlogCrumbCommitted(UserModel user, GpsBacklogFix fix) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await _db
          .collection('gps_tracking')
          .doc(fix.eventId(user.uid))
          .get(const GetOptions(source: Source.server));
      return snapshot.data()?['fixSequence'] == fix.fixSequence;
    } catch (_) {
      return false;
    }
  }

  Future<int> flushGpsBacklog({
    required UserModel user,
    GpsBacklogStore? store,
  }) async {
    _requireCurrentOwner(user.uid);
    final GpsBacklogStore backlog =
        store ?? GpsBacklogStore(projectId: _db.app.options.projectId);
    final List<GpsBacklogFix> fixes = await backlog.readAll(user.uid);
    if (fixes.isEmpty) return 0;
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await _db
        .collection('live_tracking')
        .doc(user.uid)
        .get(const GetOptions(source: Source.server));
    final Map<String, dynamic>? data = snapshot.data();
    final WorkSessionServerRecord record = WorkSessionServerRecord.fromMap(
      data,
      exists: snapshot.exists,
    );
    final GpsBacklogPlan plan = planGpsBacklog(
      fixes,
      data == null
          ? null
          : GpsLiveSnapshot(
              sessionId: record.sessionId,
              generation: record.generation,
              status: (data['workSessionStatus'] as String? ?? '').trim(),
              lastFixSequence: record.lastFixSequence,
              deviceCapturedAt: record.deviceCapturedAt,
              startedAt: _readDateTime(data['workSessionStartedAt']),
              endedAt: _readDateTime(data['workSessionEndedAt']),
            ),
      DateTime.now().toUtc(),
    );
    final List<GpsBacklogFix> finished = <GpsBacklogFix>[...plan.drop];
    final List<String> lost = <String>[...plan.dropReasons.values];
    int written = 0;
    for (final GpsBacklogFix fix in plan.write) {
      if (FirebaseAuth.instance.currentUser?.uid != user.uid.trim()) break;
      try {
        await _db
            .collection('gps_tracking')
            .doc(fix.eventId(user.uid))
            .set(gpsBacklogBreadcrumb(user, fix))
            .timeout(const Duration(seconds: 10));
        finished.add(fix);
        written++;
      } on TimeoutException {
        break;
      } on FirebaseException catch (error) {
        if (error.code == 'unavailable' || error.code == 'deadline-exceeded') {
          break;
        }
        finished.add(fix);
        if (error.code == 'permission-denied' &&
            await _backlogCrumbCommitted(user, fix)) {
          written++;
        } else {
          lost.add('$gpsBacklogServerRefusedReason (${error.code})');
        }
      }
    }
    reportDroppedGpsPoints(lost);
    if (finished.isNotEmpty) await backlog.removeAll(user.uid, finished);
    return written;
  }
}

bool isTransientFirebaseFailure(Object error) =>
    error is TimeoutException ||
    (error is FirebaseException &&
        (error.code == 'unavailable' ||
            error.code == 'deadline-exceeded' ||
            error.code == 'aborted'));

class StaleTrackingControlException implements Exception {
  const StaleTrackingControlException();
}

class WorkSessionSupersededException implements Exception {
  const WorkSessionSupersededException();
}

DateTime? _readDateTime(Object? value) {
  if (value is Timestamp) return value.toDate().toUtc();
  if (value is DateTime) return value.toUtc();
  return null;
}

double? _readDouble(Object? value) {
  if (value is! num) return null;
  final double number = value.toDouble();
  return number.isFinite ? number : null;
}

bool _sameTrackingFix(
  Map<String, dynamic> data, {
  required double latitude,
  required double longitude,
  required DateTime deviceCapturedAt,
  required int fixSequence,
}) {
  final Object? rawCapturedAt = data['deviceCapturedAt'];
  final DateTime? capturedAt = rawCapturedAt is Timestamp
      ? rawCapturedAt.toDate().toUtc()
      : rawCapturedAt is DateTime
      ? rawCapturedAt.toUtc()
      : null;
  return data['lastFixSequence'] == fixSequence ||
          data['fixSequence'] == fixSequence
      ? data['latitude'] == latitude &&
            data['longitude'] == longitude &&
            capturedAt == deviceCapturedAt.toUtc()
      : false;
}
