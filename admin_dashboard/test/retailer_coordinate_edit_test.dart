import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/geo_field_utils.dart';
import 'package:flutter_web_app/utils/retailer_coordinate_edit.dart';

void main() {
  test('unrelated edits preserve verified coordinates', () {
    expect(
      retailerCoordinateEdit(
        latitudeText: '3',
        longitudeText: '101',
        original: <String, dynamic>{
          'gps': <String, dynamic>{'lat': 3, 'lng': 101},
          'coordinateStatus': 'verified',
        },
      ),
      isEmpty,
    );
  });
  test('changed coordinates replace legacy aliases and require review', () {
    final original = <String, dynamic>{
      'gps': <String, dynamic>{'lat': 3, 'lng': 101},
      'gps_latitude': 3,
      'gps_longitude': 101,
      'coordinateStatus': 'verified',
      'coordinateReviewStatus': 'reviewed',
      'coordinateReviewedAt': 'old-time',
      'coordinateReviewedByUid': 'old-user',
      'coordinateVerifiedAt': 'old-verified-time',
      'coordinateVerifiedByUid': 'old-verified-user',
    };
    for (final clear in <bool>[false, true]) {
      final patch = retailerCoordinateEdit(
        latitudeText: clear ? '' : '4',
        longitudeText: clear ? '' : '102',
        original: original,
      );
      final merged = <String, dynamic>{...original, ...patch}
        ..removeWhere((key, value) => value is FieldValue);
      expect(readLatLng(merged)?.latitude, clear ? null : 4);
      expect(readLatLng(merged)?.longitude, clear ? null : 102);
      expect(merged['coordinateStatus'], clear ? 'missing' : 'candidate');
      expect(merged['coordinateReviewStatus'], clear ? null : 'needs_review');
      expect(merged['coordinateReviewedAt'], isNull);
      expect(merged['coordinateReviewedByUid'], isNull);
      expect(merged['coordinateVerifiedAt'], isNull);
      expect(merged['coordinateVerifiedByUid'], isNull);
    }
  });
}
