import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/screens/assigned_route_screen.dart';
import 'package:fmcg_sales/theme/app_theme.dart';

void main() {
  testWidgets(
    'VP-02 only the route action that can be pressed is drawn as the primary button',
    (WidgetTester tester) async {
      Future<void> pumpActions({
        VoidCallback? onAccept,
        VoidCallback? onStart,
        VoidCallback? onComplete,
      }) => tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme,
          home: Scaffold(
            body: RouteHeaderActions(
              onAccept: onAccept,
              onStart: onStart,
              onComplete: onComplete,
              onOpenMaps: null,
              onClearDestination: null,
            ),
          ),
        ),
      );
      bool primaryEnabled(String label) => tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, label))
          .enabled;

      await pumpActions(onAccept: () {});
      expect(primaryEnabled('Accept route'), isTrue);
      expect(primaryEnabled('Start route'), isFalse);
      expect(primaryEnabled('Complete route'), isFalse);

      await pumpActions(onStart: () {});
      expect(primaryEnabled('Accept route'), isFalse);
      expect(primaryEnabled('Start route'), isTrue);
      expect(primaryEnabled('Complete route'), isFalse);

      await pumpActions(onComplete: () {});
      expect(primaryEnabled('Accept route'), isFalse);
      expect(primaryEnabled('Start route'), isFalse);
      expect(primaryEnabled('Complete route'), isTrue);

      await pumpActions();
      expect(primaryEnabled('Accept route'), isFalse);
      expect(primaryEnabled('Start route'), isFalse);
      expect(primaryEnabled('Complete route'), isFalse);
    },
  );
}
