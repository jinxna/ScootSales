import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;

import 'package:fmcg_sales/main.dart' as app;
import 'package:fmcg_sales/screens/stuck_work_screen.dart';
import 'package:fmcg_sales/services/stuck_work.dart';

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 60),
  required String label,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $label');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a planner visit saved offline and refused when the phone is online again stays under Needs attention',
    (WidgetTester tester) async {
      app.main();
      await tester.pump(const Duration(seconds: 2));
      await waitFor(
        tester,
        find.text('Salesperson'),
        label: 'the quick sign-in button',
      );
      await tester.tap(find.text('Salesperson'));
      await waitFor(
        tester,
        find.byType(ScootBottomNav),
        timeout: const Duration(seconds: 90),
        label: 'the home screen',
      );

      final FirebaseFirestore db = FirebaseFirestore.instance;
      final String uid = FirebaseAuth.instance.currentUser!.uid;
      final HeldVisits visits = HeldVisits(firestore: db);
      final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String refusedId = '${uid}_refused_$stamp';
      final String acceptedId = '${uid}_accepted_$stamp';
      Map<String, Object?> visit(String marketplace, {String? owner}) =>
          <String, Object?>{
            'ownerUid': owner ?? uid,
            'salesmanUid': uid,
            'marketplace': marketplace,
            'time': '09:00',
            'purpose': 'Restock',
            'notes': '',
            'date': '2026-11-09',
            'day': 'Monday',
          };

      await db.disableNetwork();
      debugPrint('PLANNER_DEVICE offline');
      final bool refusedKept = await visits.save(
        uid,
        docId: refusedId,
        fields: visit('Refused Shop', owner: 'another-salesperson'),
        update: false,
      );
      final bool acceptedKept = await visits.save(
        uid,
        docId: acceptedId,
        fields: visit('Accepted Shop'),
        update: false,
      );
      expect(refusedKept, isTrue);
      expect(acceptedKept, isTrue);
      debugPrint('PLANNER_DEVICE saved offline, both queued on the phone');

      await db.enableNetwork();
      debugPrint('PLANNER_DEVICE online');
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
      List<Map<String, dynamic>> held = <Map<String, dynamic>>[];
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 500));
        held = await visits.readAll(uid);
        if (held.any((Map<String, dynamic> row) => row['docId'] == refusedId)) {
          break;
        }
      }
      expect(held.map((Map<String, dynamic> row) => row['docId']), <Object?>[
        refusedId,
      ]);
      final DocumentSnapshot<Map<String, dynamic>> accepted = await db
          .collection('visits')
          .doc(acceptedId)
          .get(const GetOptions(source: Source.server));
      expect(accepted.data()?['marketplace'], 'Accepted Shop');
      debugPrint(
        'PLANNER_DEVICE accepted visit on server, refused visit kept: ${held.single['reason']}',
      );

      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => StuckWorkScreen(
            uid: uid,
            projectId: db.app.options.projectId,
            resendStops: (_) async => false,
          ),
        ),
      );
      await waitFor(
        tester,
        find.text('Planned visit to Refused Shop'),
        label: 'the refused visit on Needs attention',
      );
      expect(find.text('Send again'), findsOneWidget);
      debugPrint('PLANNER_DEVICE Needs attention shows the refused visit');

      await tester.tap(find.text('Remove'));
      await waitFor(
        tester,
        find.text('Remove this item?'),
        label: 'the remove confirmation',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pump(const Duration(seconds: 2));
      expect(await visits.readAll(uid), isEmpty);
      debugPrint('PLANNER_DEVICE confirmed Remove cleared the refused visit');
    },
  );
}
