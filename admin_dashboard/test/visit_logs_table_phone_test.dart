import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/visit_logs_parts.dart';
import 'package:scoot_design/scoot_design.dart';

void main() {
  testWidgets('on a 390 phone the empty visits message shows whole', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    const String message =
        'Visits appear when a salesperson arrives at a retailer.';
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.dashboard(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: VisitsTableCard(
              phase: ScootLoadPhase.ready,
              rows: const <VisitRowData>[],
              onRetry: () {},
              emptyTitle: 'No visits recorded today',
              emptyMessage: message,
              summary: '0 visits',
              showDate: false,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final Rect rect = tester.getRect(find.text(message));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));
    expect(
      tester
          .renderObject<RenderParagraph>(find.text(message))
          .didExceedMaxLines,
      isFalse,
    );
  });

  testWidgets('at 840 px the visit status shows inside the card', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(840, 1200);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.dashboard(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: VisitsTableCard(
              phase: ScootLoadPhase.ready,
              rows: <VisitRowData>[
                VisitRowData(
                  retailer: 'Choice Supermarket Tabuan Jaya',
                  salesperson: 'Aiman',
                  arrived: DateTime(2026, 11, 9, 9),
                  left: DateTime(2026, 11, 9, 9, 30),
                  assignedRoute: true,
                  status: 'completed',
                ),
              ],
              onRetry: () {},
              emptyTitle: 'No visits recorded today',
              emptyMessage: 'None',
              summary: '1 visit',
              showDate: false,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.text('Completed')).right,
      lessThanOrEqualTo(824),
    );
  });
}
