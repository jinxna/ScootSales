import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/voice/copilot/copilot_dates.dart';
import 'package:flutter_web_app/voice/copilot/copilot_grammar.dart';
import 'package:flutter_web_app/voice/copilot/order_search_session.dart';

final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[
  for (int i = 1; i <= 3; i++)
    <String, dynamic>{
      'orderId': 'O$i',
      'status': 'submitted',
      'retailerName': 'Shop $i',
      'submittedAt': DateTime.utc(2026, 11, 10 + i),
      'totalAmount': 100.0,
    },
];

OrderSearchSession _session(
  List<DateTime> starts, {
  Future<int> Function()? countWaiting,
  List<Map<String, dynamic>> rows = const <Map<String, dynamic>>[],
}) {
  final List<Map<String, dynamic>> read = rows.isEmpty ? _rows : rows;
  return OrderSearchSession(
    readWindow: (DateTime start, DateTime end) async {
      starts.add(start);
      return OrderWindow(rows: read);
    },
    readWaiting: () async => read,
    loadSalespeople: () async => const [],
    download: (String filename, String csv) => true,
    recordExport: (set, filename) async {},
    scopeNote: null,
    countWaiting: countWaiting,
    clock: () => DateTime.utc(2026, 11, 15, 6),
  );
}

void main() {
  test('orders waiting for approval are not limited to this month', () async {
    final List<DateTime> starts = <DateTime>[];
    final OrderSearchSession session = _session(
      starts,
      countWaiting: () async => 410,
    );

    final CopilotReply waiting = await session.search(
      const SearchOrdersIntent(status: 'submitted'),
    );
    expect(starts, isEmpty);
    expect(waiting.text, startsWith('410 waiting for approval (all time).'));
    expect(
      waiting.text,
      contains(
        '3 shown, newest first among the 3 I read. Open All Orders for the rest.',
      ),
    );
    expect(waiting.text, isNot(contains('Newest')));

    final CopilotReply all = await _session(
      starts,
      countWaiting: () async => 3,
    ).search(const SearchOrdersIntent(status: 'submitted'));
    expect(
      all.text,
      startsWith('3 waiting for approval (all time). Newest 3 shown.'),
    );
    expect(waiting.text, isNot(contains('this month')));

    starts.clear();
    final CopilotReply normal = await _session(
      starts,
    ).search(const SearchOrdersIntent());
    expect(starts.single, DateTime.utc(2026, 10, 31, 16));
    expect(normal.text, contains('this month'));

    starts.clear();
    final CopilotReply week =
        await _session(starts, countWaiting: () async => 410).search(
          SearchOrdersIntent(
            status: 'submitted',
            period: copilotRange(
              CopilotRangeKind.thisWeek,
              DateTime.utc(2026, 11, 15, 6),
            ),
          ),
        );
    expect(week.text, contains('this week'));
    expect(week.text, isNot(contains('410')));
  });

  test(
    'an order with no status is not waiting and is not called submitted',
    () async {
      final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
        ..._rows,
        <String, dynamic>{
          'orderId': 'O4',
          'retailerName': 'Shop 4',
          'submittedAt': DateTime.utc(2026, 11, 14),
          'totalAmount': 100.0,
        },
      ];
      final List<DateTime> starts = <DateTime>[];
      final CopilotReply narrowed = await _session(
        starts,
        rows: rows,
      ).search(const SearchOrdersIntent(status: 'submitted'));
      expect(narrowed.text, startsWith('3 orders ·'));
      expect(narrowed.text, contains('3 submitted.'));
      final OrderResultsCard narrowedCard = narrowed.card! as OrderResultsCard;
      expect(narrowedCard.rows.any((String r) => r.contains('O4')), isFalse);

      final CopilotReply every = await _session(
        starts,
        rows: rows,
      ).search(const SearchOrdersIntent());
      expect(every.text, contains('3 submitted, 1 other.'));
      final OrderResultsCard everyCard = every.card! as OrderResultsCard;
      expect(
        everyCard.rows.singleWhere((String r) => r.contains('O4')),
        endsWith(' · no status'),
      );
    },
  );
}
