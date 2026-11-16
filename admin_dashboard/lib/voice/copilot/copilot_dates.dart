import '../../utils/my_team_roster.dart';

enum CopilotRangeKind {
  today,
  yesterday,
  thisWeek,
  lastWeek,
  thisMonth,
  lastMonth,
  nextWeek,
  pastDays,
  month,
  allTime,
}

class CopilotRange {
  const CopilotRange({
    required this.kind,
    required this.start,
    required this.end,
    required this.label,
  });

  final CopilotRangeKind kind;
  final DateTime start;
  final DateTime end;
  final String label;

  String get name {
    final int paren = label.indexOf(' (');
    return paren < 0 ? label : label.substring(0, paren);
  }

  @override
  bool operator ==(Object other) =>
      other is CopilotRange &&
      other.kind == kind &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(kind, start, end);
}

const Duration _kl = Duration(hours: 8);
const Duration _day = Duration(days: 1);

const List<String> _monthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

CopilotRange copilotRange(
  CopilotRangeKind kind,
  DateTime now, {
  int days = 28,
  int? year,
  int? month,
}) {
  final DateTime today = malaysiaDay(now);
  final DateTime week = malaysiaWeekStart(now);
  DateTime first;
  DateTime after;
  String name;
  switch (kind) {
    case CopilotRangeKind.today:
      first = today;
      after = today.add(_day);
      name = 'today';
    case CopilotRangeKind.yesterday:
      first = today.subtract(_day);
      after = today;
      name = 'yesterday';
    case CopilotRangeKind.thisWeek:
      first = week;
      after = today.add(_day);
      name = 'this week';
    case CopilotRangeKind.lastWeek:
      first = week.subtract(const Duration(days: 7));
      after = week;
      name = 'last week';
    case CopilotRangeKind.nextWeek:
      first = week.add(const Duration(days: 7));
      after = week.add(const Duration(days: 14));
      name = 'next week';
    case CopilotRangeKind.thisMonth:
      first = DateTime.utc(today.year, today.month, 1);
      after = DateTime.utc(today.year, today.month + 1, 1);
      name = 'this month';
    case CopilotRangeKind.lastMonth:
      first = DateTime.utc(today.year, today.month - 1, 1);
      after = DateTime.utc(today.year, today.month, 1);
      name = 'last month';
    case CopilotRangeKind.pastDays:
      first = today.subtract(Duration(days: days - 1));
      after = today.add(_day);
      name = 'past $days days';
    case CopilotRangeKind.month:
      final int m = month ?? today.month;
      final int y = year ?? today.year;
      first = DateTime.utc(y, m, 1);
      after = DateTime.utc(y, m + 1, 1);
      name = '${_monthNames[m - 1]} $y';
    case CopilotRangeKind.allTime:
      first = DateTime.utc(2000);
      after = today.add(_day);
      name = 'all time';
  }
  final DateTime last = after.subtract(_day);
  final bool wholeMonth =
      kind == CopilotRangeKind.thisMonth ||
      kind == CopilotRangeKind.lastMonth ||
      kind == CopilotRangeKind.month;
  String label;
  if (kind == CopilotRangeKind.month || kind == CopilotRangeKind.allTime) {
    label = name;
  } else if (wholeMonth) {
    label = '$name (${_months[first.month - 1]})';
  } else {
    final String end = '${last.day} ${_months[last.month - 1]}';
    if (first == last) {
      label = '$name ($end)';
    } else {
      final String start = first.month == last.month
          ? '${first.day}'
          : '${first.day} ${_months[first.month - 1]}';
      label = '$name ($start–$end)';
    }
  }
  return CopilotRange(
    kind: kind,
    start: first.subtract(_kl),
    end: after.subtract(_kl),
    label: label,
  );
}

CopilotRange copilotMonthRange(int month, DateTime now) {
  final DateTime today = malaysiaDay(now);
  final int year = month > today.month ? today.year - 1 : today.year;
  return copilotRange(CopilotRangeKind.month, now, year: year, month: month);
}

CopilotRange? copilotPeriodFromKey(String key, {DateTime? now}) {
  final CopilotRangeKind? kind = switch (key) {
    'today' => CopilotRangeKind.today,
    'yesterday' => CopilotRangeKind.yesterday,
    'this_week' => CopilotRangeKind.thisWeek,
    'last_week' => CopilotRangeKind.lastWeek,
    'this_month' => CopilotRangeKind.thisMonth,
    'last_month' => CopilotRangeKind.lastMonth,
    _ => null,
  };
  return kind == null ? null : copilotRange(kind, now ?? DateTime.now());
}

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
