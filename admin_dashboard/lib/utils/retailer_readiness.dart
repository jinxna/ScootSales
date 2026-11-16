import 'geo_field_utils.dart';
import 'order_data_utils.dart';

enum CoordinateStatus { missing, invalid, candidate, needsReview, verified }

extension CoordinateStatusInfo on CoordinateStatus {
  String get wireValue => switch (this) {
    CoordinateStatus.missing => 'missing',
    CoordinateStatus.invalid => 'invalid',
    CoordinateStatus.candidate => 'candidate',
    CoordinateStatus.needsReview => 'needs_review',
    CoordinateStatus.verified => 'verified',
  };

  String get label => switch (this) {
    CoordinateStatus.missing => 'Missing',
    CoordinateStatus.invalid => 'Invalid',
    CoordinateStatus.candidate => 'Candidate',
    CoordinateStatus.needsReview => 'Needs review',
    CoordinateStatus.verified => 'Verified',
  };

  bool get isRouteReady => this == CoordinateStatus.verified;
}

CoordinateStatus retailerCoordinateStatus(Map<String, dynamic> row) {
  switch (dataText(row['coordinateStatus']).toLowerCase()) {
    case 'verified':
      if (hasLatLng(row)) return CoordinateStatus.verified;
      break;
    case 'needs_review':
    case 'needsreview':
      return CoordinateStatus.needsReview;
    case 'candidate':
      return CoordinateStatus.candidate;
    case 'invalid':
      return CoordinateStatus.invalid;
    case 'missing':
      return CoordinateStatus.missing;
  }

  final bool hasCoords = hasLatLng(row);
  final String review = dataText(row['coordinateReviewStatus']).toLowerCase();
  final String source = dataText(row['coordinateSource']).toLowerCase();

  if (hasCoords &&
      (review == 'reviewed' ||
          review == 'verified' ||
          source == 'admin_review')) {
    return CoordinateStatus.verified;
  }
  if (!hasCoords) {
    return hasCoordinateFields(row)
        ? CoordinateStatus.invalid
        : CoordinateStatus.missing;
  }
  if (review == 'needs_review' ||
      source.contains('import') ||
      source.contains('geocode') ||
      source.contains('ors') ||
      source.contains('manual')) {
    return CoordinateStatus.needsReview;
  }
  return CoordinateStatus.candidate;
}

bool isRetailerRouteReady(Map<String, dynamic> row) =>
    retailerCoordinateStatus(row).isRouteReady;

bool retailerNeedsCoordinateReview(Map<String, dynamic> row) {
  if (!hasLatLng(row)) return false;
  final CoordinateStatus status = retailerCoordinateStatus(row);
  return status == CoordinateStatus.candidate ||
      status == CoordinateStatus.needsReview;
}

String retailerRegion(Map<String, dynamic> row) => dataText(
  pickFirst(row, const <String>['region', 'salesRegion', 'zone', 'area']),
);

String retailerSubRegion(Map<String, dynamic> row) => dataText(
  pickFirst(row, const <String>['subRegion', 'sub_region', 'subzone']),
);

String retailerTerritory(Map<String, dynamic> row) => dataText(
  pickFirst(row, const <String>[
    'territory',
    'territoryName',
    'territory_name',
  ]),
);

List<String> retailerPreferredVisitDays(Map<String, dynamic> row) {
  final Object? value = pickFirst(row, const <String>[
    'preferredVisitDays',
    'preferred_visit_days',
    'visitDays',
  ]);
  if (value is List) {
    return value
        .map((Object? e) => dataText(e))
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
  }
  if (value is String) {
    return value
        .split(RegExp(r'[,;|]'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

double retailerPriorityScore(Map<String, dynamic> row) => dataNumber(
  pickFirst(row, const <String>['priorityScore', 'priority_score', 'priority']),
);

double? retailerCoordinateConfidence(Map<String, dynamic> row) {
  final Object? raw = pickFirst(row, const <String>[
    'coordinateConfidence',
    'coordinate_confidence',
  ]);
  if (raw == null) return null;
  return dataNumber(raw);
}
