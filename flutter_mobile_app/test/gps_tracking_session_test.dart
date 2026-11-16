import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/providers/gps_provider.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  test('a cancelled GPS startup cannot mutate the next session', () {
    final GpsProvider provider = GpsProvider();
    addTearDown(provider.dispose);

    expect(
      provider.isCurrentTrackingGeneration(
        trackingRequested: false,
        expectedGeneration: 3,
        currentGeneration: 4,
      ),
      isFalse,
    );
    expect(
      provider.isCurrentTrackingGeneration(
        trackingRequested: true,
        expectedGeneration: 3,
        currentGeneration: 4,
      ),
      isFalse,
    );
    expect(
      provider.isCurrentTrackingGeneration(
        trackingRequested: true,
        expectedGeneration: 4,
        currentGeneration: 4,
      ),
      isTrue,
    );
  });

  test('permission requests share the pending platform dialog', () async {
    final GpsPermissionRequestGate gate = GpsPermissionRequestGate();
    final Completer<LocationPermission?> pending = Completer();
    int requestCount = 0;

    Future<LocationPermission?> request() {
      requestCount++;
      return pending.future;
    }

    final Future<LocationPermission?> first = gate.resolve(request);
    final Future<LocationPermission?> second = gate.resolve(request);

    expect(identical(first, second), isTrue);
    expect(requestCount, 1);

    pending.complete(LocationPermission.always);
    expect(await first, LocationPermission.always);

    final Future<LocationPermission?> afterCompletion = gate.resolve(() {
      requestCount++;
      return Future<LocationPermission?>.value(LocationPermission.whileInUse);
    });
    expect(await afterCompletion, LocationPermission.whileInUse);
    expect(requestCount, 2);
  });
}
