import 'location_evidence.dart';

class StopArrivalPayload {
  const StopArrivalPayload._();

  static Map<String, dynamic> occurrenceFields({
    required StopArrivalEvidence evidence,
  }) {
    final Map<String, dynamic> fields = <String, dynamic>{
      'arrivalMode': evidence.mode,
      'retailerCoordinateRevision': evidence.isVerified
          ? evidence.retailerCoordinateRevision
          : '',
      'retailerCoordinateSource': evidence.isVerified
          ? evidence.retailerCoordinateSource
          : '',
      'coordinateReferenceMode': evidence.isVerified
          ? evidence.coordinateReferenceMode
          : 'unverified',
    };
    if (evidence.coordinateSnapshotAt != null) {
      fields['coordinateSnapshotAt'] = evidence.coordinateSnapshotAt!
          .toUtc()
          .toIso8601String();
    }
    if (evidence.coordinateCheckedAt != null) {
      fields['coordinateCheckedAt'] = evidence.coordinateCheckedAt!
          .toUtc()
          .toIso8601String();
    }
    if (evidence.failureCode.isNotEmpty) {
      fields['arrivalFailureCode'] = evidence.failureCode;
    }
    if (evidence.overrideReasonCode.isNotEmpty) {
      fields['overrideReasonCode'] = evidence.overrideReasonCode;
    }
    if (evidence.overrideNote.isNotEmpty) {
      fields['overrideNote'] = evidence.overrideNote;
    }
    final DeviceLocationFix? fix = evidence.fix;
    if (fix != null) {
      fields.addAll(<String, dynamic>{
        'arrivalLatitude': fix.latitude,
        'arrivalLongitude': fix.longitude,
        'arrivalAccuracyMeters': fix.accuracyMeters,
        'arrivalDeviceCapturedAt': fix.capturedAt.toUtc().toIso8601String(),
        'arrivalIsMocked': fix.isMocked,
      });
    }
    if (evidence.distanceMeters != null) {
      fields['arrivalDistanceMeters'] = evidence.distanceMeters;
    }
    return fields;
  }
}
