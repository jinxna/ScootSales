import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/voice/copilot/copilot_dates.dart';
import 'package:flutter_web_app/voice/copilot/copilot_grammar.dart';
import 'package:flutter_web_app/voice/copilot/order_search_session.dart';

OrderSearchSession _session(
  List<DateTime> starts, {
  Future<int> Function()? countWaiting,
}) {
  return OrderSearchSession(
    readWindow: (DateTime start, DateTime end) async {
      starts.add(start);
      return OrderWindow(
        rows: <Map<String, dynamic>>[
          for (int i = 1; i <= 3; i++)
            <String, dynamic>{
              'orderId': 'O$i',
              'status': 'submitted',
              'retailerName': 'Shop $i',
              'submittedAt': DateTime.utc(2026, 11, 10 + i),
              'totalAmount': 100.0,
            },
        ],
      );
    },
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
    expect(starts.single.isBefore(DateTime.utc(2026, 1, 1)), isTrue);
    expect(waiting.text, startsWith('410 waiting for approval (all time).'));
    expect(waiting.text, contains('Newest 3 shown.'));
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
}
