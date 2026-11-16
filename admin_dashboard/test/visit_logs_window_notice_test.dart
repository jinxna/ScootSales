import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/visit_logs_page.dart';
import 'package:flutter_web_app/utils/collection_rows.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';

List<Map<String, dynamic>> _visits(int count, DateTime newest) =>
    <Map<String, dynamic>>[
      for (int i = 0; i < count; i++)
        <String, dynamic>{
          'docId': 'V$i',
          'arrivalTime': newest.subtract(Duration(minutes: 20 * i)),
        },
    ];

CollectionRows _repositoryWindow(
  List<Map<String, dynamic>> collection,
  String field,
  int limit,
) {
  final List<Map<String, dynamic>> rows =
      collection
          .where((Map<String, dynamic> row) => row[field] != null)
          .toList()
        ..sort(
          (Map<String, dynamic> a, Map<String, dynamic> b) =>
              (b[field] as DateTime).compareTo(a[field] as DateTime),
        );
  final List<Map<String, dynamic>> window = rows.take(limit).toList();
  final bool full = window.length >= limit;
  return CollectionRows(
    window,
    isComplete: !full && window.length == collection.length,
    coveredSince: full ? window.last[field] as DateTime : coversAllRows,
  );
}

CollectionRows _visitLogWindows(List<Map<String, dynamic>> collection) =>
    mergeNewestWindows(
      <List<Map<String, dynamic>>>[
        _repositoryWindow(collection, 'arrivalTime', 320),
        _repositoryWindow(collection, 'createdAt', 160),
        _repositoryWindow(collection, 'timestamp', 160),
      ],
      maxRows: 500,
      dateForRow: visitDateFromRow,
      sameCollection: true,
    );

void main() {
  test(
    'a range older than the loaded visits gets a notice with the date the list is complete from',
    () {
      final DateTime newest = DateTime.utc(2026, 11, 20, 4);
      final List<Map<String, dynamic>> newestVisits = _visits(500, newest);
      final CollectionRows loaded = mergeNewestWindows(
        <List<Map<String, dynamic>>>[
          CollectionRows(
            newestVisits,
            isComplete: false,
            coveredSince: newestVisits.last['arrivalTime'] as DateTime,
          ),
          CollectionRows(<Map<String, dynamic>>[
            <String, dynamic>{
              'docId': 'L1',
              'arrivalTime': DateTime.utc(2026, 10, 1),
            },
          ], isComplete: true),
        ],
        maxRows: 500,
        dateForRow: visitDateFromRow,
      );

      expect(loaded, hasLength(500));
      expect(
        newestWindowNotice(
          loaded,
          DateTime.utc(2026, 10, 31, 16),
          what: 'visits',
        ),
        'Only the newest visits are loaded, complete from 13/11/2026 13:40 MYT.',
      );
      expect(
        newestWindowNotice(
          loaded,
          DateTime.utc(2026, 11, 15, 16),
          what: 'visits',
        ),
        isNull,
      );
    },
  );

  test('visits that all fit in the loaded window get no notice', () {
    final CollectionRows loaded = mergeNewestWindows(
      <List<Map<String, dynamic>>>[
        CollectionRows(
          _visits(40, DateTime.utc(2026, 11, 20, 4)),
          isComplete: true,
        ),
      ],
      maxRows: 500,
      dateForRow: visitDateFromRow,
    );

    expect(
      newestWindowNotice(
        loaded,
        DateTime.utc(2026, 10, 31, 16),
        what: 'visits',
      ),
      isNull,
    );
    expect(newestWindowNotice(loaded, coversAllRows, what: 'visits'), isNull);
  });

  test(
    'a visit cut from the created-date window gets a notice from that window',
    () {
      final DateTime now = DateTime.utc(2026, 11, 20, 4);
      final CollectionRows loaded = _visitLogWindows(<Map<String, dynamic>>[
        for (int i = 0; i < 159; i++)
          <String, dynamic>{
            'docId': 'C$i',
            'createdAt': now.subtract(Duration(minutes: 20 * i)),
          },
        <String, dynamic>{
          'docId': 'LATE',
          'arrivalTime': DateTime.utc(2026, 10, 20, 2),
          'createdAt': now,
        },
        <String, dynamic>{
          'docId': 'MISSING',
          'createdAt': DateTime.utc(2026, 11, 10, 2),
        },
      ]);

      expect(
        loaded.any((Map<String, dynamic> row) => row['docId'] == 'MISSING'),
        isFalse,
      );
      expect(
        newestWindowNotice(
          loaded,
          DateTime.utc(2026, 10, 31, 16),
          what: 'visits',
        ),
        'Only the newest visits are loaded, complete from 18/11/2026 07:20 MYT.',
      );
      expect(
        newestWindowNotice(loaded, DateTime.utc(2026, 11, 18), what: 'visits'),
        isNull,
      );
    },
  );

  test(
    'visits that all fit in the larger window get no notice although a smaller window is full',
    () {
      final DateTime now = DateTime.utc(2026, 11, 20, 4);
      final CollectionRows visitLogs = _visitLogWindows(<Map<String, dynamic>>[
        for (int i = 0; i < 200; i++)
          <String, dynamic>{
            'docId': 'V$i',
            'arrivalTime': now.subtract(Duration(minutes: 20 * i)),
            'createdAt': now.subtract(Duration(minutes: 20 * i)),
          },
      ]);

      expect(visitLogs, hasLength(200));
      expect(
        newestWindowNotice(
          visitLogs,
          DateTime.utc(2026, 10, 31, 16),
          what: 'visits',
        ),
        isNull,
      );
      expect(
        newestWindowNotice(visitLogs, coversAllRows, what: 'visits'),
        isNull,
      );

      final CollectionRows withRouteStops = mergeNewestWindows(
        <List<Map<String, dynamic>>>[
          visitLogs,
          CollectionRows(
            const <Map<String, dynamic>>[],
            isComplete: false,
            coveredSince: DateTime.utc(2026, 11, 19),
          ),
        ],
        maxRows: 500,
        dateForRow: visitDateFromRow,
      );
      expect(
        newestWindowNotice(
          withRouteStops,
          DateTime.utc(2026, 10, 31, 16),
          what: 'visits',
        ),
        'Only the newest visits are loaded, complete from 19/11/2026 08:00 MYT.',
      );
    },
  );
}
