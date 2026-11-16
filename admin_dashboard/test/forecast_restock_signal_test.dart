import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/forecast_catalogue_provenance.dart';

void main() {
  test('the restock rule flags the rows the Prediction Restock tab flags', () {
    final List<(String, Map<String, dynamic>, bool)>
    cases = <(String, Map<String, dynamic>, bool)>[
      (
        'point above reference',
        <String, dynamic>{'status': 'ok', 'point': 30, 'referenceUnits': 10},
        true,
      ),
      (
        'point slightly above reference',
        <String, dynamic>{'status': 'ok', 'point': 10.5, 'referenceUnits': 10},
        true,
      ),
      (
        'point equal to reference',
        <String, dynamic>{'status': 'ok', 'point': 10, 'referenceUnits': 10},
        false,
      ),
      (
        'point below reference',
        <String, dynamic>{'status': 'ok', 'point': 5, 'referenceUnits': 10},
        false,
      ),
      (
        'positive point with no reference',
        <String, dynamic>{'status': 'ok', 'point': 5},
        true,
      ),
      (
        'zero point',
        <String, dynamic>{'status': 'ok', 'point': 0, 'referenceUnits': 0},
        false,
      ),
      (
        'zero point with a stock action',
        <String, dynamic>{
          'status': 'ok',
          'point': 0,
          'recommendedAction': 'Increase stock',
        },
        false,
      ),
      (
        'insufficient history',
        <String, dynamic>{
          'status': 'insufficient_history',
          'point': 120,
          'referenceUnits': 10,
        },
        false,
      ),
      (
        'below reference with a stock action',
        <String, dynamic>{
          'status': 'ok',
          'point': 5,
          'referenceUnits': 10,
          'recommendedAction': 'Increase stock',
        },
        true,
      ),
      (
        'below reference with maintain stock',
        <String, dynamic>{
          'status': 'ok',
          'point': 5,
          'referenceUnits': 10,
          'recommendedAction': 'Maintain stock',
        },
        false,
      ),
      (
        'below reference with a stored change of 40 percent',
        <String, dynamic>{
          'status': 'ok',
          'point': 5,
          'referenceUnits': 10,
          'changePercentage': 40,
        },
        true,
      ),
      (
        'older row shape with a positive quantity',
        <String, dynamic>{'status': '', 'predictedQuantity': 120},
        true,
      ),
      (
        'older row shape with an invalid point',
        <String, dynamic>{
          'status': '',
          'point': 'invalid',
          'predictedQuantity': 120,
          'recommendedAction': 'Increase stock',
        },
        false,
      ),
      (
        'negative point with a positive alias',
        <String, dynamic>{
          'status': 'ok',
          'point': -1,
          'predictedQuantity': 120,
        },
        false,
      ),
      (
        'point that is not a number',
        <String, dynamic>{'status': 'ok', 'point': 'NaN'},
        false,
      ),
      (
        'reference that is not a number',
        <String, dynamic>{'status': 'ok', 'point': 30, 'referenceUnits': 'NaN'},
        false,
      ),
      (
        'numbers with thousands separators',
        <String, dynamic>{
          'status': 'ok',
          'point': '1,200',
          'referenceUnits': '1,000',
        },
        true,
      ),
      (
        'stored average used before the reference',
        <String, dynamic>{
          'status': 'ok',
          'point': 12,
          'historicalAverage': 20,
          'referenceUnits': 10,
        },
        false,
      ),
    ];

    for (final (String name, Map<String, dynamic> row, bool expected)
        in cases) {
      expect(forecastRestockSignal(row).shouldShow, expected, reason: name);
    }
    expect(
      forecastRestockSignal(<String, dynamic>{
        'status': 'ok',
        'point': 30,
        'referenceUnits': 10,
      }).changePercent,
      200,
    );
  });

  test('the Forecast Alerts count uses the latest forecast week only', () {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      <String, dynamic>{
        'productId': 'A',
        'periodStart': '2026-11-02',
        'status': 'ok',
        'point': 50,
        'referenceUnits': 10,
      },
      <String, dynamic>{
        'productId': 'A',
        'periodStart': '2026-11-09',
        'status': 'ok',
        'point': 30,
        'referenceUnits': 10,
      },
      <String, dynamic>{
        'productId': 'B',
        'periodStart': '2026-11-09',
        'status': 'ok',
        'point': 5,
        'referenceUnits': 10,
      },
      <String, dynamic>{
        'productId': 'C',
        'periodStart': '2026-11-02',
        'status': 'ok',
        'point': 40,
        'referenceUnits': 10,
      },
    ];

    expect(forecastRestockSignalCount(rows), 1);
    expect(forecastRestockSignalCount(const <Map<String, dynamic>>[]), 0);
  });
}
