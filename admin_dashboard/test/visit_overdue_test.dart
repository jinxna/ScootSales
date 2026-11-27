import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/visit_overdue.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 11, 19, 4);

  test('a visit is overdue from 7 Kuching calendar days, not before', () {
    const List<(int, bool)> table = <(int, bool)>[
      (0, false),
      (6, false),
      (7, true),
      (8, true),
    ];
    final List<String> wrong = <String>[
      for (final (int days, bool overdue) in table)
        if (isVisitOverdue(now.subtract(Duration(days: days)), now) != overdue)
          '$days days: expected $overdue',
    ];
    expect(wrong, isEmpty);
    expect(visitDaysAgo(now.subtract(const Duration(days: 7)), now), 7);
  });

  test(
    'a shop never visited has no visit age and is not overdue by this rule',
    () {
      expect(visitDaysAgo(null, now), isNull);
      expect(isVisitOverdue(null, now), isFalse);
    },
  );

  test('days count Kuching dates, not 24-hour blocks', () {
    final DateTime lateVisit = DateTime.utc(2026, 11, 11, 15, 30);
    final DateTime earlyNow = DateTime.utc(2026, 11, 17, 16, 30);
    expect(visitDaysAgo(lateVisit, earlyNow), 7);
    expect(isVisitOverdue(lateVisit, earlyNow), isTrue);
    final DateTime afterKuchingMidnight = DateTime.utc(2026, 11, 12, 16, 30);
    final DateTime lateNow = DateTime.utc(2026, 11, 19, 15);
    expect(visitDaysAgo(afterKuchingMidnight, lateNow), 6);
    expect(isVisitOverdue(afterKuchingMidnight, lateNow), isFalse);
    expect(
      visitDaysAgo(
        DateTime.utc(2026, 11, 18, 16, 1),
        DateTime.utc(2026, 11, 18, 23),
      ),
      0,
    );
  });
}
