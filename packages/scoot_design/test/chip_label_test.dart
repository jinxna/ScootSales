import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scoot_design/scoot_design.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    for (final ScootSurface surface in ScootSurface.values) {
      testWidgets('unselected chip labels are drawn $brightness $surface', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ScootTheme.build(surface: surface, brightness: brightness),
            home: Scaffold(
              body: Wrap(
                children: <Widget>[
                  ChoiceChip(
                    label: const Text('Choice'),
                    selected: false,
                    onSelected: (_) {},
                  ),
                  FilterChip(
                    label: const Text('Filter'),
                    selected: false,
                    onSelected: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        final ScootColors colors = ScootColors.of(
          tester.element(find.text('Choice')),
        );
        for (final String label in <String>['Choice', 'Filter']) {
          final TextStyle style = DefaultTextStyle.of(
            tester.element(find.text(label)),
          ).style;
          expect(style.color, colors.text2, reason: label);
        }
      });
      testWidgets(
        'selected filter chip label is brand text $brightness $surface',
        (WidgetTester tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: ScootTheme.build(surface: surface, brightness: brightness),
              home: Scaffold(
                body: FilterChip(
                  label: const Text('Filter'),
                  selected: true,
                  onSelected: (_) {},
                ),
              ),
            ),
          );
          final ScootColors colors = ScootColors.of(
            tester.element(find.text('Filter')),
          );
          final TextStyle style = DefaultTextStyle.of(
            tester.element(find.text('Filter')),
          ).style;
          expect(style.color, colors.brandText);
        },
      );
    }
  }
}
