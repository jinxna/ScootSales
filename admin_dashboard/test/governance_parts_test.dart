import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/governance_parts.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:scoot_design/scoot_design.dart';

import 'support/scoot_host.dart';

AdminAccessRow row(String name, {bool enabled = true}) => AdminAccessRow(
  docId: name,
  name: name,
  email: '$name@example.test',
  enabled: enabled,
  raw: <String, dynamic>{},
);

Widget accessCard({
  ScootLoadPhase phase = ScootLoadPhase.ready,
  List<AdminAccessRow> rows = const <AdminAccessRow>[],
  bool canChange = true,
  VoidCallback? onRetry,
  void Function(AdminAccessRow, bool)? onToggle,
}) => scootHost(
  SingleChildScrollView(
    child: AdminAccessCard(
      phase: phase,
      rows: rows,
      canChange: canChange,
      onToggle: onToggle ?? (_, _) {},
      onRetry: onRetry ?? () {},
    ),
  ),
);

Widget retention({
  bool failed = false,
  int kept = 0,
  int months = 3,
  bool canPurge = true,
}) =>
    scootHost(
  SingleChildScrollView(
    child: OrderRetentionCard(
      retentionMonths: months,
      enabled: false,
      busy: false,
      lastRun: 'Never',
      removed: 0,
      keptCount: kept,
      lastRunFailed: failed,
      canPurge: canPurge,
      onMonths: (_) {},
      onEnabled: (_) {},
      onSave: () {},
      onRunNow: () {},
    ),
  ),
);

void main() {
  testWidgets('a read-only viewer cannot flip the switch', (
    WidgetTester tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(
      accessCard(rows: <AdminAccessRow>[row('A')], canChange: false),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
  });

  testWidgets('a company with no stored choice keeps orders for 7 years', (
    WidgetTester tester,
  ) async {
    useDesktopSurface(tester);
    expect(
      CmsRepository.orderPurgeRetentionMonths(<String, dynamic>{
        'retentionMonths': 6,
      }),
      6,
    );
    await tester.pumpWidget(
      retention(
        months: CmsRepository.orderPurgeRetentionMonths(<String, dynamic>{}),
      ),
    );
    expect(find.text('7 years'), findsOneWidget);
  });

  testWidgets('an administrator sees the choice and Save but no purge controls', (
    WidgetTester tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(retention(canPurge: false));
    expect(find.text('Keep final orders for'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Run purge now…'), findsNothing);
  });

  testWidgets('danger zone only offers listed collections', (
    WidgetTester tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(
      scootHost(
        SingleChildScrollView(
          child: DangerZoneCard(
            busy: false,
            collection: 'visit_logs',
            csvPreview: '',
            onCollection: (_) {},
            onWipeLocations: () {},
            onPurge: () {},
          ),
        ),
      ),
    );
    expect(find.text('Danger zone'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Export and purge…'), findsOneWidget);
  });
}
