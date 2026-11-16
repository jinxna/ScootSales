import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/catalogue_import.dart';

void main() {
  test(
    'a re-import carries the price stamp whenever it writes a price field that differs from the stored one',
    () {
      final CatalogueImportRow row = buildCatalogueImportPlan(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'Department': 'AMBIENT',
            'Category': 'TEST',
            'Product': 'Same Price',
            'Product ID': 'P1',
            'Price': '10',
          },
        ],
      ).rows.single;
      bool stamped(Map<String, dynamic> stored) => row
          .writeFields(exists: true, existingProduct: stored)
          .containsKey('priceUpdatedAt');

      expect(stamped(<String, dynamic>{'unitPrice': 10.0}), isTrue);
      expect(
        stamped(<String, dynamic>{'unitPrice': 10.0, 'priceGuide': 10.0}),
        isTrue,
      );
      expect(
        stamped(<String, dynamic>{
          'unitPrice': 10.0,
          'price': 8.0,
          'priceGuide': 10.0,
        }),
        isTrue,
      );
      expect(
        stamped(<String, dynamic>{
          'unitPrice': 10.0,
          'price': 10.0,
          'priceGuide': 10.0,
        }),
        isFalse,
      );
    },
  );

  group('buildCatalogueImportPlan', () {
    test('blocks duplicate product IDs in one file', () {
      final CatalogueImportPlan plan = buildCatalogueImportPlan(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'Department': 'A',
            'Category': 'B',
            'Product': 'First',
            'Product ID': 'same/id',
          },
          <String, dynamic>{
            'Department': 'A',
            'Category': 'B',
            'Product': 'Second',
            'Product ID': 'same id',
          },
        ],
      );

      expect(
        plan.rows.every(
          (CatalogueImportRow row) =>
              row.errors.contains('Duplicate product ID in this file'),
        ),
        isTrue,
      );
      expect(plan.rows.first.productId, 'same_id');
    });

    test('rejects unsafe prices before an import can be confirmed', () {
      for (final String value in <String>[
        '-1',
        '-0.01',
        'NaN',
        'Infinity',
        '-Infinity',
        '1e30',
        '${maxCatalogueUnitPrice + 0.01}',
      ]) {
        final CatalogueImportRow row = buildCatalogueImportPlan(
          <Map<String, dynamic>>[
            <String, dynamic>{
              'Department': 'AMBIENT',
              'Category': 'TEST',
              'Product': 'Price $value',
              'Price': value,
            },
          ],
        ).rows.single;

        expect(row.errors, contains(startsWith('Price is not a valid number')));
        expect(row.product['unitPrice'], 0.0);
        expect(row.updateProduct.containsKey('unitPrice'), isFalse);
      }

      final CatalogueImportRow boundaryRow = buildCatalogueImportPlan(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'Department': 'AMBIENT',
            'Category': 'TEST',
            'Product': 'Maximum Price',
            'Price': '$maxCatalogueUnitPrice',
          },
        ],
      ).rows.single;
      expect(boundaryRow.errors, isEmpty);
      expect(boundaryRow.product['unitPrice'], maxCatalogueUnitPrice);
      expect(boundaryRow.updateProduct['unitPrice'], maxCatalogueUnitPrice);
    });

    test('does not allow an oversized atomic write plan', () {
      final List<Map<String, dynamic>> rows =
          List<Map<String, dynamic>>.generate(
            151,
            (int index) => <String, dynamic>{
              'Department': 'Department $index',
              'Category': 'Category $index',
              'Product': 'Product $index',
            },
          );

      expect(
        () => buildCatalogueImportPlan(rows),
        throwsA(
          isA<FormatException>().having(
            (FormatException error) => error.message,
            'message',
            contains('linked writes'),
          ),
        ),
      );
    });
  });
}
