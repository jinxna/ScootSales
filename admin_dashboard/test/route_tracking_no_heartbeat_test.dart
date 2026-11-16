import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/action_centre_item.dart';
import 'package:flutter_web_app/services/action_centre_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  });

  test(
    'a route the phone never sent a heartbeat for raises no stale alarm, an old heartbeat still does',
    () {
      final DateTime now = DateTime.now().toUtc();
      Map<String, dynamic> plan(String id) => <String, dynamic>{
        'planId': id,
        'status': 'published',
        'weekStart': now.subtract(const Duration(days: 1)),
        'weekEnd': now.add(const Duration(days: 1)),
        'stopIds': <String>['s1'],
      };
      Map<String, dynamic> progress(String planId, String uid) =>
          <String, dynamic>{
            'planId': planId,
            'salesmanUid': uid,
            'salesmanCode': uid.toUpperCase(),
            'status': 'in_progress',
            'routeSessionState': 'active',
            'startedAt': now.subtract(const Duration(minutes: 30)),
          };

      final List<ActionCentreItem> items = ActionCentreService()
          .routeExecutionAttentionItems(
            progressRows: <Map<String, dynamic>>[
              progress('plan-a', 'sa'),
              <String, dynamic>{
                ...progress('plan-b', 'sb'),
                'lastHeartbeatAt': now.subtract(const Duration(hours: 2)),
              },
            ],
            routePlans: <Map<String, dynamic>>[plan('plan-a'), plan('plan-b')],
            visits: const <Map<String, dynamic>>[],
            orders: const <Map<String, dynamic>>[],
            now: now,
          );

      final List<String> staleFor = items
          .where((ActionCentreItem item) => item.category == 'Route Tracking')
          .map((ActionCentreItem item) => item.relatedEntityId)
          .toList();
      expect(staleFor, <String>['plan-b']);
    },
  );
}
