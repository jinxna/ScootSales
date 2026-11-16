import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/location_evidence.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 9, 6, 12);

  DeviceLocationFix fix({
    double latitude = 3.139,
    double longitude = 101.6869,
    double accuracy = 12,
    DateTime? capturedAt,
    bool isMocked = false,
  }) => DeviceLocationFix(
    latitude: latitude,
    longitude: longitude,
    accuracyMeters: accuracy,
    capturedAt: capturedAt ?? now,
    isMocked: isMocked,
  );

  group('arrival location assessment', () {
    test('rejects a stale or future-dated fix', () {
      for (final capturedAt in <DateTime>[
        now.subtract(const Duration(minutes: 2, seconds: 1)),
        now.add(kLocationClockSkewTolerance + const Duration(seconds: 1)),
      ]) {
        final result = ArrivalLocationAssessment.assess(
          fix: fix(capturedAt: capturedAt),
          retailerLatitude: 3.139,
          retailerLongitude: 101.6869,
          now: now,
        );
        expect(result.failure, LocationEvidenceFailure.stale);
      }
    });

    test('rejects inaccurate, mocked, impossible, and remote fixes', () {
      expect(
        ArrivalLocationAssessment.assess(
          fix: fix(accuracy: 101),
          retailerLatitude: 3.139,
          retailerLongitude: 101.6869,
          now: now,
        ).failure,
        LocationEvidenceFailure.inaccurate,
      );
      expect(
        ArrivalLocationAssessment.assess(
          fix: fix(isMocked: true),
          retailerLatitude: 3.139,
          retailerLongitude: 101.6869,
          now: now,
        ).failure,
        LocationEvidenceFailure.mocked,
      );
      expect(
        ArrivalLocationAssessment.assess(
          fix: fix(latitude: 999),
          retailerLatitude: 3.139,
          retailerLongitude: 101.6869,
          now: now,
        ).failure,
        LocationEvidenceFailure.invalidCoordinates,
      );
      final remote = ArrivalLocationAssessment.assess(
        fix: fix(latitude: 1.5535, longitude: 110.3439983),
        retailerLatitude: 3.139,
        retailerLongitude: 101.6869,
        now: now,
      );
      expect(remote.failure, LocationEvidenceFailure.outsideRadius);
      expect(remote.distanceMeters, greaterThan(900000));
    });
  });
}
