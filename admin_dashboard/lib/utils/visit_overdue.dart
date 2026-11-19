const int visitOverdueAfterDays = 7;

DateTime _kuchingDay(DateTime instant) {
  final DateTime local = instant.toUtc().add(const Duration(hours: 8));
  return DateTime.utc(local.year, local.month, local.day);
}

int? visitDaysAgo(DateTime? lastVisit, DateTime now) => lastVisit == null
    ? null
    : _kuchingDay(now).difference(_kuchingDay(lastVisit)).inDays;

bool isVisitOverdue(DateTime? lastVisit, DateTime now) =>
    (visitDaysAgo(lastVisit, now) ?? -1) >= visitOverdueAfterDays;
