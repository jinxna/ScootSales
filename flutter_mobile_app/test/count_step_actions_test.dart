import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/theme/app_theme.dart';
import 'package:fmcg_sales/widgets/count_step_actions.dart';

void main() {
  testWidgets(
    'VP-01 the Count step shows the whole Continue to Signature label at phone widths and with larger text',
    (WidgetTester tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      for (final (double width, double scale) in <(double, double)>[
        (360, 1.0),
        (360, 1.3),
        (390, 1.0),
        (412, 1.0),
      ]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(
          MaterialApp(
            theme: appLightTheme,
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              bottomNavigationBar: SafeArea(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: CountStepActions(
                    isSaved: false,
                    onSave: () {},
                    onAddItems: () {},
                    onContinue: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final String at = 'width $width, text scale $scale';
        expect(tester.takeException(), isNull, reason: at);
        final Finder label = find.text('Continue to Signature');
        expect(label, findsOneWidget, reason: at);
        expect(
          tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
          isFalse,
          reason: at,
        );
        final Rect labelRect = tester.getRect(label);
        final Rect buttonRect = tester.getRect(
          find.ancestor(
            of: label,
            matching: find.bySubtype<ButtonStyleButton>(),
          ),
        );
        expect(
          buttonRect.contains(labelRect.topLeft) &&
              buttonRect.contains(labelRect.bottomRight - const Offset(1, 1)),
          isTrue,
          reason: '$at: label $labelRect, button $buttonRect',
        );
        for (final Element button
            in find.bySubtype<ButtonStyleButton>().evaluate()) {
          expect(
            button.size!.height,
            greaterThanOrEqualTo(48),
            reason: '$at: ${button.widget}',
          );
        }
      }
    },
  );
}
