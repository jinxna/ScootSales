import 'nearby_retailer.dart';

const Duration kLocationFixMaxAge = Duration(minutes: 2);
const double kLocationMaxAccuracyMeters = 100;
const Duration kArrivalLocationFixMaxAge = Duration(seconds: 30);
const double kArrivalLocationMaxAccuracyMeters = 25;

enum LocationEvidenceFailure {
  disabledByUser,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  unavailable,
  invalidCoordinates,
  stale,
  inaccurate,
  mocked,
  missingRetailerCoordinates,
  outsideRadius,
}

extension LocationEvidenceFailureText on LocationEvidenceFailure {
  String get code => switch (this) {
    LocationEvidenceFailure.disabledByUser => 'disabled_by_user',
    LocationEvidenceFailure.serviceDisabled => 'service_disabled',
    LocationEvidenceFailure.permissionDenied => 'permission_denied',
    LocationEvidenceFailure.permissionDeniedForever =>
      'permission_denied_forever',
    LocationEvidenceFailure.unavailable => 'unavailable',
    LocationEvidenceFailure.invalidCoordinates => 'invalid_coordinates',
    LocationEvidenceFailure.stale => 'stale',
    LocationEvidenceFailure.inaccurate => 'inaccurate',
    LocationEvidenceFailure.mocked => 'mocked',
    LocationEvidenceFailure.missingRetailerCoordinates =>
      'missing_retailer_coordinates',
    LocationEvidenceFailure.outsideRadius => 'outside_radius',
  };

  String get userMessage => switch (this) {
    LocationEvidenceFailure.disabledByUser =>
      'Location sharing is disabled in Profile.',
    LocationEvidenceFailure.serviceDisabled =>
      'Location services are switched off.',
    LocationEvidenceFailure.permissionDenied =>
      'Location permission was not granted.',
    LocationEvidenceFailure.permissionDeniedForever =>
      'Location permission is blocked in device settings.',
    LocationEvidenceFailure.unavailable =>
      'A current device fix or the current retailer pin could not be checked.',
    LocationEvidenceFailure.invalidCoordinates =>
      'The device returned invalid coordinates.',
    LocationEvidenceFailure.stale =>
      'The location timestamp is outside the allowed 30-second window.',
    LocationEvidenceFailure.inaccurate =>
      'Location accuracy is not good enough to verify this arrival.',
    LocationEvidenceFailure.mocked =>
      'The device reports that this is a simulated location.',
    LocationEvidenceFailure.missingRetailerCoordinates =>
      'The current verified retailer pin could not be matched to this route.',
    LocationEvidenceFailure.outsideRadius =>
      'The device is more than 75 m from the assigned retailer.',
  };
}

enum ManualArrivalReason {
  gpsUnavailable,
  retailerCoordinatesIncorrect,
  managerApprovedException,
  safetyOrAccessIssue,
}

extension ManualArrivalReasonText on ManualArrivalReason {
  String get code => switch (this) {
    ManualArrivalReason.gpsUnavailable => 'gps_unavailable',
    ManualArrivalReason.retailerCoordinatesIncorrect =>
      'retailer_coordinates_incorrect',
    ManualArrivalReason.managerApprovedException =>
      'manager_approved_exception',
    ManualArrivalReason.safetyOrAccessIssue => 'safety_or_access_issue',
  };

  String get label => switch (this) {
    ManualArrivalReason.gpsUnavailable =>
      'GPS or retailer-pin verification unavailable',
    ManualArrivalReason.retailerCoordinatesIncorrect =>
      'Retailer coordinates appear incorrect',
    ManualArrivalReason.managerApprovedException =>
      'Manager-approved exception',
    ManualArrivalReason.safetyOrAccessIssue => 'Safety or access issue',
  };
}

class DeviceLocationFix {
  const DeviceLocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.capturedAt,
    required this.isMocked,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime capturedAt;
  final bool isMocked;
}

class ArrivalLocationAssessment {
  const ArrivalLocationAssessment._({
    required this.failure,
    this.fix,
    this.distanceMeters,
  });

  const ArrivalLocationAssessment.unavailable(LocationEvidenceFailure failure)
    : this._(failure: failure);

  final LocationEvidenceFailure? failure;
  final DeviceLocationFix? fix;
  final double? distanceMeters;

  bool get isVerified => failure == null && fix != null;

  static ArrivalLocationAssessment assess({
    required DeviceLocationFix fix,
    required double retailerLatitude,
    required double retailerLongitude,
    DateTime? now,
  }) {
    final DateTime checkedAt = now ?? DateTime.now();
    if (!_validCoordinates(fix.latitude, fix.longitude)) {
      return ArrivalLocationAssessment._(
        failure: LocationEvidenceFailure.invalidCoordinates,
        fix: fix,
      );
    }
    if (fix.isMocked) {
      return ArrivalLocationAssessment._(
        failure: LocationEvidenceFailure.mocked,
        fix: fix,
      );
    }
    final Duration age = checkedAt.difference(fix.capturedAt);
    if (age < -kLocationClockSkewTolerance || age > kArrivalLocationFixMaxAge) {
      return ArrivalLocationAssessment._(
        failure: LocationEvidenceFailure.stale,
        fix: fix,
      );
    }
    if (!fix.accuracyMeters.isFinite ||
        fix.accuracyMeters <= 0 ||
        fix.accuracyMeters > kArrivalLocationMaxAccuracyMeters) {
      return ArrivalLocationAssessment._(
        failure: LocationEvidenceFailure.inaccurate,
        fix: fix,
      );
    }
    if (!_validCoordinates(retailerLatitude, retailerLongitude)) {
      return ArrivalLocationAssessment._(
        failure: LocationEvidenceFailure.missingRetailerCoordinates,
        fix: fix,
      );
    }
    final double distance = haversineMeters(
      fix.latitude,
      fix.longitude,
      retailerLatitude,
      retailerLongitude,
    );
    if (distance > kArrivalMaxDistanceMeters) {
      return ArrivalLocationAssessment._(
        failure: LocationEvidenceFailure.outsideRadius,
        fix: fix,
        distanceMeters: distance,
      );
    }
    return ArrivalLocationAssessment._(
      failure: null,
      fix: fix,
      distanceMeters: distance,
    );
  }
}

class StopArrivalEvidence {
  const StopArrivalEvidence._({
    required this.mode,
    required this.failureCode,
    required this.reviewStatus,
    required this.fix,
    required this.distanceMeters,
    required this.overrideReasonCode,
    required this.overrideNote,
    required this.coordinateReferenceMode,
    required this.retailerCoordinateRevision,
    required this.retailerCoordinateSource,
    required this.coordinateSnapshotAt,
    required this.coordinateCheckedAt,
  });

  factory StopArrivalEvidence.verified(
    ArrivalLocationAssessment assessment, {
    required bool currentRetailerCoordinatesVerified,
    String coordinateReferenceMode = 'current_retailer',
    String retailerCoordinateRevision = '',
    String retailerCoordinateSource = '',
    DateTime? coordinateSnapshotAt,
    DateTime? coordinateCheckedAt,
  }) {
    if (!assessment.isVerified || !currentRetailerCoordinatesVerified) {
      throw ArgumentError('Verified evidence requires a valid assessment.');
    }
    return StopArrivalEvidence._(
      mode: 'location_verified',
      failureCode: '',
      reviewStatus: 'not_required',
      fix: assessment.fix,
      distanceMeters: assessment.distanceMeters,
      overrideReasonCode: '',
      overrideNote: '',
      coordinateReferenceMode: coordinateReferenceMode,
      retailerCoordinateRevision: retailerCoordinateRevision,
      retailerCoordinateSource: retailerCoordinateSource,
      coordinateSnapshotAt: coordinateSnapshotAt?.toUtc(),
      coordinateCheckedAt: coordinateCheckedAt?.toUtc(),
    );
  }

  factory StopArrivalEvidence.manual({
    required ArrivalLocationAssessment assessment,
    required ManualArrivalReason reason,
    required String note,
  }) {
    final String cleanNote = note.trim();
    if (assessment.isVerified || assessment.failure == null) {
      throw ArgumentError('Manual evidence requires a failed assessment.');
    }
    if (cleanNote.length < 3 || cleanNote.length > 300) {
      throw ArgumentError('Manual arrival note must be 3-300 characters.');
    }
    return StopArrivalEvidence._(
      mode: 'manual_unverified',
      failureCode: assessment.failure!.code,
      reviewStatus: 'pending',
      fix: assessment.fix,
      distanceMeters: assessment.distanceMeters,
      overrideReasonCode: reason.code,
      overrideNote: cleanNote,
      coordinateReferenceMode: 'unverified',
      retailerCoordinateRevision: '',
      retailerCoordinateSource: '',
      coordinateSnapshotAt: null,
      coordinateCheckedAt: null,
    );
  }

  final String mode;
  final String failureCode;
  final String reviewStatus;
  final DeviceLocationFix? fix;
  final double? distanceMeters;
  final String overrideReasonCode;
  final String overrideNote;
  final String coordinateReferenceMode;
  final String retailerCoordinateRevision;
  final String retailerCoordinateSource;
  final DateTime? coordinateSnapshotAt;
  final DateTime? coordinateCheckedAt;

  bool get isVerified => mode == 'location_verified';

  Map<String, dynamic> toMap() => <String, dynamic>{
    'mode': mode,
    'coordinateReferenceMode': coordinateReferenceMode,
    if (retailerCoordinateRevision.isNotEmpty)
      'retailerCoordinateRevision': retailerCoordinateRevision,
    if (retailerCoordinateSource.isNotEmpty)
      'retailerCoordinateSource': retailerCoordinateSource,
    if (coordinateSnapshotAt != null)
      'coordinateSnapshotAt': coordinateSnapshotAt!.toUtc(),
    if (coordinateCheckedAt != null)
      'coordinateCheckedAt': coordinateCheckedAt!.toUtc(),
    'reviewStatus': reviewStatus,
    if (failureCode.isNotEmpty) 'failureCode': failureCode,
    if (overrideReasonCode.isNotEmpty) 'overrideReasonCode': overrideReasonCode,
    if (overrideNote.isNotEmpty) 'overrideNote': overrideNote,
    if (fix != null) ...<String, dynamic>{
      'latitude': fix!.latitude,
      'longitude': fix!.longitude,
      'accuracyMeters': fix!.accuracyMeters,
      'deviceCapturedAt': fix!.capturedAt.toUtc(),
      'isMocked': fix!.isMocked,
    },
    if (distanceMeters != null) 'distanceMeters': distanceMeters,
  };
}

bool isReliableForegroundFix(DeviceLocationFix fix, {DateTime? now}) {
  if (!_validCoordinates(fix.latitude, fix.longitude) || fix.isMocked) {
    return false;
  }
  final Duration age = (now ?? DateTime.now()).difference(fix.capturedAt);
  return age >= -kLocationClockSkewTolerance &&
      age <= kLocationFixMaxAge &&
      fix.accuracyMeters.isFinite &&
      fix.accuracyMeters > 0 &&
      fix.accuracyMeters <= kLocationMaxAccuracyMeters;
}

bool isReliableArrivalFix(DeviceLocationFix fix, {DateTime? now}) {
  if (!_validCoordinates(fix.latitude, fix.longitude) || fix.isMocked) {
    return false;
  }
  final Duration age = (now ?? DateTime.now()).difference(fix.capturedAt);
  return age >= -kLocationClockSkewTolerance &&
      age <= kArrivalLocationFixMaxAge &&
      fix.accuracyMeters.isFinite &&
      fix.accuracyMeters > 0 &&
      fix.accuracyMeters <= kArrivalLocationMaxAccuracyMeters;
}

const Duration kLocationClockSkewTolerance = Duration(seconds: 5);

const double kOrderEvidenceMaxAccuracyMeters = 10000;
const Duration kOrderEvidenceMaxFutureOffset = Duration(minutes: 4);

bool isFixWithinOrderEvidenceRange(DeviceLocationFix fix, {DateTime? now}) =>
    _validCoordinates(fix.latitude, fix.longitude) &&
    !(fix.latitude == 0 && fix.longitude == 0) &&
    fix.accuracyMeters.isFinite &&
    fix.accuracyMeters >= 0 &&
    fix.accuracyMeters <= kOrderEvidenceMaxAccuracyMeters &&
    !fix.capturedAt.isAfter(
      (now ?? DateTime.now()).add(kOrderEvidenceMaxFutureOffset),
    );

bool _validCoordinates(double latitude, double longitude) =>
    latitude.isFinite &&
    longitude.isFinite &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180 &&
    !(latitude == 0 && longitude == 0);
