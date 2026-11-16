import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/assigned_route_plan.dart';
import 'package:fmcg_sales/utils/location_evidence.dart';
import 'package:fmcg_sales/widgets/arrival_verification_flow.dart';

AssignedRoutePlan _plan({DateTime? publishedAt}) =>
    AssignedRoutePlan.fromMap('p1', <String, dynamic>{
      'status': 'published',
      'salesmanUid': 'u1',
      'branchId': 'b1',
      if (publishedAt != null) 'publishedAt': publishedAt.toIso8601String(),
      'days': <Map<String, dynamic>>[
        <String, dynamic>{
          'dayId': 'd1',
          'stops': <Map<String, dynamic>>[
            <String, dynamic>{
              'stopId': 's1',
              'retailerId': 'r1',
              'lat': 1.5535,
              'lng': 110.3593,
              'retailerCoordinateSnapshot': <String, dynamic>{
                'latitude': 1.5535,
                'longitude': 110.3593,
                'coordinateStatus': 'verified',
                'coordinateSource': 'admin_review',
                'coordinateRevision': 'rev-1',
              },
            },
            <String, dynamic>{'stopId': 's2', 'retailerId': 'r2'},
          ],
        },
      ],
    });

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) {
          captured = context;
          return const Scaffold();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets(
    'guided arrival for a stop that is not selected is refused before any dialog',
    (WidgetTester tester) async {
      final BuildContext context = await _pumpHost(tester);
      final AssignedRoutePlan plan = _plan(publishedAt: DateTime.utc(2026, 11));
      final Future<StopArrivalEvidence?> attempt =
          collectSelectedStopArrivalEvidence(
            context,
            plan: plan,
            stop: plan.stops.first,
            progress: RouteProgress(
              status: 'in_progress',
              stopProgress: const <String, String>{},
              selectedStopId: 's2',
            ),
            isOnline: true,
          );
      Object? refusal;
      attempt.catchError((Object error) {
        refusal = error;
        return null;
      });
      await tester.pump();
      expect(find.byType(Dialog), findsNothing);
      expect(refusal, isA<StateError>());
      expect(
        (refusal! as StateError).message,
        'Select this stop before recording an arrival.',
      );
    },
  );

  testWidgets(
    'guided arrival offline offers the check against the published pin',
    (WidgetTester tester) async {
      final BuildContext context = await _pumpHost(tester);
      final AssignedRoutePlan plan = _plan(publishedAt: DateTime.utc(2026, 11));
      final Future<StopArrivalEvidence?> attempt =
          collectSelectedStopArrivalEvidence(
            context,
            plan: plan,
            stop: plan.stops.first,
            progress: RouteProgress(
              status: 'in_progress',
              stopProgress: const <String, String>{},
              selectedStopId: 's1',
            ),
            isOnline: false,
          );
      await tester.pump();
      expect(find.text('Check arrival against published pin'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await attempt, isNull);
    },
  );
}
