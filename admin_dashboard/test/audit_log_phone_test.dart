import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/audit_log_page.dart';
import 'package:scoot_design/scoot_design.dart';

void main() {
  testWidgets(
    'on a 390 phone the audit card shows who, record and change whole',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1600);
      addTearDown(tester.view.reset);
      final DateTime now = DateTime(2026, 11, 9, 10);
      const String actor = 'Nurul Aisyah binti Abdullah, branch manager';
      const String record = 'retailer ret-kedai-runcit-batu-kawa-0006';
      const String summary =
          'Changed the assigned salesperson from Aiman to Farah and hid the retailer from the route planner';
      await tester.pumpWidget(
        MaterialApp(
          theme: ScootTheme.dashboard(),
          home: Scaffold(
            body: AuditLogView(
              phase: ScootLoadPhase.ready,
              onRetry: () {},
              now: now,
              entries: <AuditEntry>[
                AuditEntry(
                  action: 'update',
                  summary: summary,
                  entityType: 'retailer',
                  entityId: 'ret-kedai-runcit-batu-kawa-0006',
                  actor: actor,
                  createdAt: now.subtract(const Duration(hours: 1)),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final String value in <String>[actor, record, summary]) {
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(value))
              .didExceedMaxLines,
          isFalse,
          reason: '"$value" is cut',
        );
      }
    },
  );
}
