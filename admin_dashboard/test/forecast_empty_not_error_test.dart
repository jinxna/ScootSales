import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/prediction_states.dart';
import 'package:scoot_design/scoot_design.dart';

const String _toolsSentence =
    'Run forecast and Import Excel need the forecasting service on the '
    'office PC.';

void main() {
  testWidgets('no published forecast is a plain empty state, a failed read '
      'is an error with Retry', (WidgetTester tester) async {
    Future<void> pump(bool loadFailed) => tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.dashboard(),
        home: Scaffold(
          body: ForecastUnavailable(loadFailed: loadFailed, onRetry: () {}),
        ),
      ),
    );
    await pump(false);
    expect(find.byType(ScootEmptyState), findsOneWidget);
    expect(find.byType(ScootErrorState), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.textContaining('No forecast'), findsWidgets);

    await pump(true);
    expect(find.byType(ScootErrorState), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('could not be loaded'), findsOneWidget);
  });

  test('an empty result or a failed read leaves the forecasting service '
      'state as the readiness check gave it', () {
    for (final bool ready in <bool>[true, false]) {
      for (final bool savedCopy in <bool>[true, false]) {
        final ForecastFallback empty = forecastFallback(
          serviceReady: ready,
          hasSavedCopy: savedCopy,
          readFailed: false,
        );
        expect(empty.serviceOnline, ready, reason: 'empty, saved $savedCopy');
        expect(empty.noForecast, !savedCopy);
        expect(empty.loadFailed, isFalse);

        final ForecastFallback failed = forecastFallback(
          serviceReady: ready,
          hasSavedCopy: savedCopy,
          readFailed: true,
        );
        expect(failed.serviceOnline, ready, reason: 'failed, saved $savedCopy');
        expect(failed.noForecast, isFalse);
        expect(failed.loadFailed, !savedCopy);
      }
    }
  });

  testWidgets('an admin sees the office PC sentence only when the company '
      'has a forecasting service', (WidgetTester tester) async {
    Future<void> pump({required bool hasForecastingService}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: ScootTheme.dashboard(),
            home: Scaffold(
              body: ForecastStatusNotices(
                toolsEnabled: false,
                hasForecastingService: hasForecastingService,
                serviceOnline: false,
                isAdmin: true,
                onCheckAgain: () {},
              ),
            ),
          ),
        );
    final Finder sentence = find.textContaining(
      _toolsSentence,
      findRichText: true,
    );
    await pump(hasForecastingService: true);
    expect(sentence, findsOneWidget);

    await pump(hasForecastingService: false);
    expect(sentence, findsNothing);
    expect(find.textContaining('service is offline'), findsNothing);
  });
}
