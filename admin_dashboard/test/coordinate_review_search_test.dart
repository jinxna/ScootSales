import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/coordinate_review_page.dart';

final List<Map<String, dynamic>> _retailers = <Map<String, dynamic>>[
  <String, dynamic>{
    'docId': 'R-SWIN',
    'name': 'Swinburne Sarawak',
    'latitude': 1.5320,
    'longitude': 110.3570,
    'coordinateStatus': 'verified',
  },
  <String, dynamic>{
    'docId': 'R-KEDAI',
    'name': 'Kedai Ah Seng',
    'latitude': 1.5500,
    'longitude': 110.3400,
    'coordinateStatus': 'verified',
  },
];

void main() {
  test('with no coordinate problems the issue view is empty', () {
    final List<CoordinateReviewRow> rows = coordinateReviewRows(_retailers);

    expect(coordinateReviewVisible(rows, 'issues', ''), isEmpty);
  });

  test('search finds a verified retailer by name and by id from the issue view',
      () {
    final List<CoordinateReviewRow> rows = coordinateReviewRows(_retailers);

    final List<CoordinateReviewRow> byName = coordinateReviewVisible(
      rows,
      'issues',
      'swinburne',
    );
    expect(byName.map((CoordinateReviewRow row) => row.id), <String>['R-SWIN']);
    expect(byName.single.statusLabel, 'Verified');
    expect(byName.single.coordinateText, '1.532000, 110.357000');

    expect(
      coordinateReviewVisible(rows, 'issues', 'r-kedai')
          .map((CoordinateReviewRow row) => row.name),
      <String>['Kedai Ah Seng'],
    );
  });

  test('All retailers lists every shop without a search', () {
    expect(
      coordinateReviewVisible(coordinateReviewRows(_retailers), 'all', ''),
      hasLength(2),
    );
  });
}
