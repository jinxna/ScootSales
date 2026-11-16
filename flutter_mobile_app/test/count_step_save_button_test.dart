import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/theme/app_theme.dart';
import 'package:fmcg_sales/widgets/count_step_actions.dart';

void main() {
  testWidgets(
    'VP-08 the Count step Save button is an outlined button when it can be pressed',
    (WidgetTester tester) async {
      int saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme,
          home: Scaffold(
            bottomNavigationBar: CountStepActions(
              isSaved: false,
              onSave: () => saves++,
              onAddItems: () {},
              onContinue: () {},
            ),
          ),
        ),
      );
      final Finder save = find.ancestor(
        of: find.text('Save'),
        matching: find.bySubtype<OutlinedButton>(),
      );
      expect(save, findsOneWidget);
      expect(tester.widget<OutlinedButton>(save).enabled, isTrue);
      await tester.tap(save);
      expect(saves, 1);
    },
  );
}
