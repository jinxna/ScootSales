import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/route_planner/route_plan_workspace.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';

Future<int> _pumpFooter(
  WidgetTester tester, {
  required String status,
  required bool saved,
  required bool withDelete,
}) async {
  int deletes = 0;
  await tester.binding.setSurfaceSize(const Size(1400, 400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: DsoTheme.light,
      home: Scaffold(
        body: RoutePlanFooter(
          status: status,
          title: 'Route',
          message: '',
          saved: saved,
          saving: false,
          onSave: () {},
          onApprove: () {},
          onPublish: () {},
          onWithdraw: () {},
          onBackToDraft: () {},
          onDeleteDraft: withDelete ? () => deletes++ : null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (find.text('Delete draft').evaluate().isNotEmpty) {
    await tester.tap(find.text('Delete draft'));
    await tester.pump();
  }
  return deletes;
}

void main() {
  testWidgets('a saved draft offers Delete draft and the button calls the delete', (WidgetTester tester) async {
    expect(await _pumpFooter(tester, status: 'draft', saved: true, withDelete: true), 1);
    expect(find.text('Delete draft'), findsOneWidget);
  });

  for (final String status in <String>['approved', 'published']) {
    testWidgets('an $status plan never offers Delete draft', (WidgetTester tester) async {
      expect(await _pumpFooter(tester, status: status, saved: true, withDelete: true), 0);
      expect(find.text('Delete draft'), findsNothing);
    });
  }

  testWidgets('an unsaved draft and a person who may not delete see no Delete draft', (WidgetTester tester) async {
    expect(await _pumpFooter(tester, status: 'draft', saved: false, withDelete: true), 0);
    expect(find.text('Delete draft'), findsNothing);
    expect(await _pumpFooter(tester, status: 'draft', saved: true, withDelete: false), 0);
    expect(find.text('Delete draft'), findsNothing);
  });
}
