import 'dart:convert';

import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:integration_test/integration_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:fmcg_sales/main.dart' as app;

const String _routePlanId = 'route-map-navigation-e2e';
const String _stopAId = 'map-stop-a';
const String _stopBId = 'map-stop-b';
const String _stopCId = 'map-stop-c';
const String _stopAName = 'QA Map Retailer A';
const String _stopBName = 'QA Map Retailer B';
const String _stopCName = 'QA Map Retailer C';

class _CapturingUrlLauncherPlatform extends UrlLauncherPlatform {
  String? launchedUrl;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    return true;
  }
}

String _visibleText(WidgetTester tester) => find
    .byType(Text)
    .evaluate()
    .map((Element element) => (element.widget as Text).data ?? '')
    .where((String value) => value.trim().isNotEmpty)
    .join(' | ');

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required Duration timeout,
  required String label,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  // ignore: avoid_print
  print(
    'ASSIGNED_ROUTE_MAP_WAIT_TIMEOUT '
    '${jsonEncode(<String, Object?>{'label': label, 'stopAVisible': find.text(_stopAName).evaluate().isNotEmpty, 'stopBVisible': find.text(_stopBName).evaluate().isNotEmpty, 'stopCVisible': find.text(_stopCName).evaluate().isNotEmpty, 'mapAttributionVisible': find.text('© OpenStreetMap contributors © CARTO').evaluate().isNotEmpty, 'chooserHeadingVisible': find.text('Stops at this location').evaluate().isNotEmpty, 'textNodeCount': find.byType(Text).evaluate().length})}',
  );
  fail('Timed out waiting for $label. Visible text: ${_visibleText(tester)}');
}

Future<bool> _waitForMapOrFallback(WidgetTester tester) async {
  final Finder attribution = find.text('© OpenStreetMap contributors © CARTO');
  final Finder fallback = find.text(
    'Map tiles could not be loaded. Your route list and actions are available below.',
  );
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (attribution.evaluate().isNotEmpty) return true;
    if (fallback.evaluate().isNotEmpty) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(
    'Map neither rendered nor fell back. Visible text: ${_visibleText(tester)}',
  );
}

Future<Map<String, dynamic>?> _readProgress(String uid) async {
  final QuerySnapshot<Map<String, dynamic>> snapshot = await FirebaseFirestore
      .instance
      .collection('route_plan_progress')
      .where('planId', isEqualTo: _routePlanId)
      .where('salesmanUid', isEqualTo: uid)
      .limit(2)
      .get(const GetOptions(source: Source.server))
      .timeout(const Duration(seconds: 10));
  expect(snapshot.docs.length, lessThanOrEqualTo(1));
  return snapshot.docs.isEmpty ? null : snapshot.docs.single.data();
}

Future<Map<String, dynamic>> _waitForSelectedStop(
  String uid,
  String stopId,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
  Map<String, dynamic>? latest;
  while (DateTime.now().isBefore(deadline)) {
    latest = await _readProgress(uid);
    if (latest?['selectedStopId'] == stopId &&
        latest?['selectionRevision'] == 1) {
      return latest!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }
  fail('Selected-stop progress did not reach the expected revision: $latest');
}

Future<Map<String, dynamic>> _readPublishedRoute() async {
  final DocumentSnapshot<Map<String, dynamic>> snapshot =
      await FirebaseFirestore.instance
          .collection('route_plans')
          .doc(_routePlanId)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
  expect(
    snapshot.exists,
    isTrue,
    reason: 'The local route fixture is required.',
  );
  return snapshot.data()!;
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('map selection, fallback, and selected-stop navigation', (
    WidgetTester tester,
  ) async {
    const bool useFirebaseEmulator = bool.fromEnvironment(
      'USE_FIREBASE_EMULATOR',
    );
    const String firebaseEmulatorHost = String.fromEnvironment(
      'FIREBASE_EMULATOR_HOST',
    );
    expect(useFirebaseEmulator, isTrue);
    expect(firebaseEmulatorHost, '10.0.2.2');

    app.main();
    await tester.pump(const Duration(seconds: 2));

    final Finder quickSignIn = find.text('Salesperson');
    final Finder assignedRouteEntry = find.descendant(
      of: find.byType(ScootBottomNav),
      matching: find.text('Route'),
    );
    final DateTime loginDeadline = DateTime.now().add(
      const Duration(seconds: 60),
    );
    while (DateTime.now().isBefore(loginDeadline) &&
        quickSignIn.evaluate().isEmpty &&
        assignedRouteEntry.evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (quickSignIn.evaluate().isNotEmpty) {
      await tester.tap(quickSignIn.first);
    }
    await _waitFor(
      tester,
      assignedRouteEntry,
      timeout: const Duration(seconds: 90),
      label: 'the authenticated salesperson home',
    );

    final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    expect(uid, isNotEmpty);
    final Map<String, dynamic> routeBefore = await _readPublishedRoute();
    expect(routeBefore['status'], 'published');
    expect(routeBefore['stopIds'], <String>[_stopAId, _stopBId, _stopCId]);

    await tester.tap(assignedRouteEntry.first);
    await _waitFor(
      tester,
      find.text(_stopAName),
      timeout: const Duration(seconds: 60),
      label: 'the first published stop',
    );
    await _waitFor(
      tester,
      find.text(_stopBName),
      timeout: const Duration(seconds: 30),
      label: 'the selected-stop fixture',
    );
    await _waitFor(
      tester,
      find.text(_stopCName),
      timeout: const Duration(seconds: 30),
      label: 'the unverified fixture stop',
    );

    await tester.ensureVisible(find.text('Map'));
    await tester.tap(find.text('Map'));
    final bool mapRendered = await _waitForMapOrFallback(tester);
    bool clusterWasSelectable = false;
    if (mapRendered) {
      expect(find.text('© OpenStreetMap contributors © CARTO'), findsOneWidget);
      expect(find.byType(PolylineLayer<Object>), findsNothing);
      expect(find.textContaining('straight-line distance'), findsWidgets);

      final Finder overlappingStops = find.byTooltip(
        RegExp('overlapping stop markers'),
      );
      await _waitFor(
        tester,
        overlappingStops,
        timeout: const Duration(seconds: 20),
        label: 'overlapping assigned-stop markers',
      );
      final Finder mapCanvas = find.byType(FlutterMap);
      await tester.ensureVisible(mapCanvas.first);
      await tester.pump(const Duration(milliseconds: 200));
      final Finder tappableOverlappingStops = overlappingStops.hitTestable();
      final Rect markerRect = tester.getRect(overlappingStops.first);
      final Size viewportSize =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      final String markerVerticalPosition = markerRect.bottom <= 0
          ? 'above_viewport'
          : markerRect.top >= viewportSize.height
          ? 'below_viewport'
          : 'within_vertical_viewport';
      // ignore: avoid_print
      print(
        'ASSIGNED_ROUTE_MAP_TAP_TARGET '
        '${jsonEncode(<String, Object?>{'markerCount': overlappingStops.evaluate().length, 'hitTestableCount': tappableOverlappingStops.evaluate().length, 'markerVerticalPosition': markerVerticalPosition, 'markerInsideViewport': markerRect.left >= 0 && markerRect.top >= 0 && markerRect.right <= viewportSize.width && markerRect.bottom <= viewportSize.height})}',
      );
      expect(
        tappableOverlappingStops,
        findsOneWidget,
        reason: 'The clustered marker must be visible and hit-testable.',
      );
      await tester.tap(tappableOverlappingStops.first);
      await _waitFor(
        tester,
        find.text('Stops at this location'),
        timeout: const Duration(seconds: 10),
        label: 'the overlapping-stop chooser',
      );
      expect(find.text(_stopBName), findsOneWidget);
      expect(find.textContaining('Unverified pin'), findsOneWidget);
      await tester.tap(find.text(_stopBName).last);
      clusterWasSelectable = true;
    } else {
      expect(
        find.text(
          'Map tiles could not be loaded. Your route list and actions are available below.',
        ),
        findsOneWidget,
      );
      final Finder selectB = find.text('Go to this stop').at(1);
      await tester.ensureVisible(selectB);
      await tester.tap(selectB);
    }

    final Map<String, dynamic> selected = await _waitForSelectedStop(
      uid,
      _stopBId,
    );
    await binding.convertFlutterSurfaceToImage();
    final List<int> screenshot = await binding.takeScreenshot(
      mapRendered
          ? 'assigned-route-map-overview'
          : 'assigned-route-map-tile-fallback',
    );
    expect(screenshot, isNotEmpty);

    if (mapRendered) {
      await tester.tap(find.text('List'));
      await _waitFor(
        tester,
        find.text('Google Maps'),
        timeout: const Duration(seconds: 15),
        label: 'the selected stop actions in List view',
      );
      expect(find.text(_stopBName), findsWidgets);
    }

    final UrlLauncherPlatform originalUrlLauncher =
        UrlLauncherPlatform.instance;
    final _CapturingUrlLauncherPlatform urlLauncher =
        _CapturingUrlLauncherPlatform();
    UrlLauncherPlatform.instance = urlLauncher;
    addTearDown(() => UrlLauncherPlatform.instance = originalUrlLauncher);

    final Finder selectedStopMapsAction = find.widgetWithText(
      OutlinedButton,
      'Open selected stop in Google Maps',
    );
    expect(
      selectedStopMapsAction,
      findsOneWidget,
      reason: 'The selected-stop Maps action must be unique before tapping.',
    );
    await tester.ensureVisible(selectedStopMapsAction);
    await tester.tap(selectedStopMapsAction);
    await _waitFor(
      tester,
      find.text(_stopBName),
      timeout: const Duration(seconds: 10),
      label: 'the selected destination after the Maps handoff',
    );
    expect(urlLauncher.launchedUrl, isNotNull);
    final Uri handoff = Uri.parse(urlLauncher.launchedUrl!);
    expect(handoff.scheme, 'https');
    expect(handoff.host, 'www.google.com');
    expect(handoff.path, '/maps/dir/');
    expect(handoff.queryParameters['api'], '1');
    expect(handoff.queryParameters['destination'], '1.5535,110.3593');
    expect(handoff.queryParameters.containsKey('key'), isFalse);
    final String? origin = handoff.queryParameters['origin'];
    if (origin != null) expect(origin, isNot('1.5535,110.3593'));

    expect((await _readPublishedRoute()), equals(routeBefore));
    expect(selected['selectedStopId'], _stopBId);
    expect(selected['selectionRevision'], 1);

    final String encodedScreenshot = base64Encode(screenshot);
    const int screenshotChunkSize = 2000;
    final int screenshotChunkCount =
        (encodedScreenshot.length + screenshotChunkSize - 1) ~/
        screenshotChunkSize;
    // ignore: avoid_print
    print(
      'ASSIGNED_ROUTE_MAP_PNG_BEGIN '
      '$screenshotChunkCount ${screenshot.length}',
    );
    for (
      int offset = 0;
      offset < encodedScreenshot.length;
      offset += screenshotChunkSize
    ) {
      final int chunkIndex = offset ~/ screenshotChunkSize + 1;
      final String chunk = encodedScreenshot.substring(
        offset,
        (offset + screenshotChunkSize)
            .clamp(0, encodedScreenshot.length)
            .toInt(),
      );
      // ignore: avoid_print
      print(
        'ASSIGNED_ROUTE_MAP_PNG_CHUNK '
        '$chunkIndex/$screenshotChunkCount:$chunk',
      );
    }
    // ignore: avoid_print
    print(
      'ASSIGNED_ROUTE_MAP_PNG_END '
      '$screenshotChunkCount ${screenshot.length}',
    );

    debugPrint(
      'ASSIGNED_ROUTE_MAP_TRACE ${jsonEncode(<String, Object?>{'schemaVersion': 1, 'fixture': 'assigned-route-map-navigation-v1', 'mapOutcome': mapRendered ? 'rendered' : 'tile_fallback', 'osmAttributionVisible': mapRendered, 'overlappingStopsSelectable': clusterWasSelectable, 'unverifiedStopIncluded': true, 'selectedStopId': _stopBId, 'selectionRevision': selected['selectionRevision'], 'routePlanUnchanged': true, 'keylessGoogleMapsDestinationMatched': true, 'freshOriginIncluded': origin != null})}',
    );
  });
}
