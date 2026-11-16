library;

List<double> dailySeries<T>(
  Iterable<T> rows, {
  required DateTime? Function(T row) dateOf,
  double Function(T row)? valueOf,
  int days = 14,
  DateTime? now,
}) {
  DateTime klDay(DateTime v) {
    final DateTime kl = v.toUtc().add(const Duration(hours: 8));
    return DateTime.utc(kl.year, kl.month, kl.day);
  }

  final DateTime today = klDay(now ?? DateTime.now());
  final List<double> series = List<double>.filled(days, 0);
  for (final T row in rows) {
    final DateTime? date = dateOf(row);
    if (date == null) continue;
    final int ago = today.difference(klDay(date)).inDays;
    if (ago < 0 || ago >= days) continue;
    series[days - 1 - ago] += valueOf == null ? 1 : valueOf(row);
  }
  return series;
}

double? halfOverHalfDelta(List<double> series) {
  if (series.length < 2) return null;
  final int half = series.length ~/ 2;
  final double older = series.take(half).fold(0, (double a, double b) => a + b);
  final double newer = series
      .skip(series.length - half)
      .fold(0, (double a, double b) => a + b);
  if (older <= 0) return null;
  return (newer - older) / older * 100;
}
