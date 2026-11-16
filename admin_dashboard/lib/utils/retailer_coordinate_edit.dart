import 'package:cloud_firestore/cloud_firestore.dart';

import 'geo_field_utils.dart';
import 'retailer_readiness.dart';

const List<String> kCoordinateReviewMetadataKeys = <String>[
  'coordinateReviewedAt',
  'coordinateReviewedByUid',
  'coordinateReviewedBy',
  'coordinateVerifiedAt',
  'coordinateVerifiedByUid',
  'coordinateVerifiedBy',
];

Map<String, dynamic> verifiedCoordinatePayload({
  required Map<String, dynamic> original,
  required String latitudeText,
  required String longitudeText,
  required String reviewerUid,
  required Object reviewedAt,
}) {
  return <String, dynamic>{
    ...retailerCoordinateEdit(
      latitudeText: latitudeText,
      longitudeText: longitudeText,
      original: original,
      forceCanonical: true,
    ),
    'coordinateSource': 'admin_review',
    'coordinateStatus': CoordinateStatus.verified.wireValue,
    'coordinateReviewStatus': 'reviewed',
    'coordinateReviewedByUid': reviewerUid,
    'coordinateReviewedAt': reviewedAt,
  };
}

Map<String, dynamic> retailerCoordinateEdit({
  required String latitudeText,
  required String longitudeText,
  Map<String, dynamic>? original,
  bool forceCanonical = false,
}) {
  final String latText = latitudeText.trim();
  final String lngText = longitudeText.trim();
  final double? lat = double.tryParse(latText);
  final double? lng = double.tryParse(lngText);
  if ((latText.isNotEmpty || lngText.isNotEmpty) &&
      (lat == null ||
          lng == null ||
          !lat.isFinite ||
          !lng.isFinite ||
          lat.abs() > 90 ||
          lng.abs() > 180 ||
          (lat == 0 && lng == 0))) {
    throw const FormatException(
      'Enter both valid coordinates, or leave both coordinate fields blank.',
    );
  }
  final previous = original == null ? null : readLatLng(original);
  final bool hasExistingCoordinateFields =
      original != null && hasCoordinateFields(original);
  final bool coordinatesUnchanged =
      previous == null &&
      lat == null &&
      lng == null &&
      !hasExistingCoordinateFields;
  if (!forceCanonical &&
      original != null &&
      ((previous != null &&
              previous.latitude == lat &&
              previous.longitude == lng) ||
          coordinatesUnchanged)) {
    return <String, dynamic>{};
  }
  final Map<String, dynamic> patch = <String, dynamic>{
    if (original != null)
      for (final String key in <String>[
        ...kLatitudeKeys,
        ...kLongitudeKeys,
        ...kNestedCoordinateKeys,
        ...kCoordinateReviewMetadataKeys,
      ])
        key: FieldValue.delete(),
  };
  if (lat == null || lng == null) {
    if (original == null) return patch;
    return patch..addAll(<String, dynamic>{
      'coordinateStatus': 'missing',
      'coordinateSource': FieldValue.delete(),
      'coordinateReviewStatus': FieldValue.delete(),
    });
  }
  return patch..addAll(<String, dynamic>{
    if (!forceCanonical) ...<String, dynamic>{
      'gpsLatitude': lat,
      'gpsLongitude': lng,
    },
    'latitude': lat,
    'longitude': lng,
    'location': GeoPoint(lat, lng),
    'coordinateStatus': 'candidate',
    'coordinateSource': 'admin_entry',
    'coordinateReviewStatus': 'needs_review',
  });
}
