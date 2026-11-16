enum AiFreshnessState { noData, timestampUnavailable, fresh, stale }

const Duration aiFreshnessStaleAfter = Duration(days: 7);
const Duration aiFreshnessMalaysiaOffset = Duration(hours: 8);

DateTime? aiDataTimestamp(Map<String, dynamic> data, {DateTime? now}) {
  final DateTime clock = (now ?? DateTime.now()).toUtc();
  DateTime? newest;
  for (final String field in const <String>[
    'generatedAt',
    'updatedAt',
    'weekStart',
  ]) {
    final DateTime? parsed = _parseAiTimestamp(data[field]);
    if (parsed != null &&
        !parsed.isAfter(clock.add(const Duration(days: 1))) &&
        (newest == null || parsed.isAfter(newest))) {
      newest = parsed;
    }
  }
  return newest;
}

DateTime? _parseAiTimestamp(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is num) {
    final double raw = value.toDouble();
    if (!raw.isFinite) return null;
    final double magnitude = raw.abs();
    final double milliseconds = magnitude > 1e14
        ? raw / 1000
        : magnitude > 9999999999
        ? raw
        : raw * 1000;
    if (!milliseconds.isFinite || milliseconds.abs() > 8640000000000000) {
      return null;
    }
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        milliseconds.toInt(),
        isUtc: true,
      );
    } on RangeError {
      return null;
    }
  }
  if (value == null) return null;

  try {
    final dynamic timestamp = value;
    final Object? date = timestamp.toDate();
    if (date is DateTime) return date.toUtc();
  } catch (_) {}

  final String text = value.toString().trim();
  if (text.isEmpty) return null;
  final RegExp dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  if (dateOnly.hasMatch(text)) {
    final DateTime? date = DateTime.tryParse('${text}T00:00:00Z');
    return date?.subtract(aiFreshnessMalaysiaOffset);
  }

  final DateTime? parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  final bool hasZone = RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(text);
  if (hasZone) return parsed.toUtc();

  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
    parsed.microsecond,
  ).subtract(aiFreshnessMalaysiaOffset);
}

class AiDataFreshness {
  const AiDataFreshness({
    required this.state,
    required this.latestAtUtc,
    required this.hasMissingTimestamp,
  });

  final AiFreshnessState state;
  final DateTime? latestAtUtc;

  final bool hasMissingTimestamp;
}

AiDataFreshness calculateAiDataFreshness({
  required bool hasData,
  required Iterable<DateTime?> timestamps,
  required DateTime now,
  Duration staleAfter = aiFreshnessStaleAfter,
  bool hasMissingTimestamp = false,
}) {
  if (!hasData) {
    return const AiDataFreshness(
      state: AiFreshnessState.noData,
      latestAtUtc: null,
      hasMissingTimestamp: false,
    );
  }

  DateTime? newest;
  for (final DateTime? timestamp in timestamps) {
    if (timestamp == null) continue;
    final DateTime utc = timestamp.toUtc();
    if (utc.isAfter(now.toUtc().add(const Duration(days: 1)))) continue;
    if (newest == null || utc.isAfter(newest)) newest = utc;
  }

  if (newest == null) {
    return AiDataFreshness(
      state: AiFreshnessState.timestampUnavailable,
      latestAtUtc: null,
      hasMissingTimestamp: true,
    );
  }

  final Duration age = now.toUtc().difference(newest);
  return AiDataFreshness(
    state: age > staleAfter ? AiFreshnessState.stale : AiFreshnessState.fresh,
    latestAtUtc: newest,
    hasMissingTimestamp: hasMissingTimestamp,
  );
}

String formatAiFreshnessDate(DateTime timestamp) {
  final DateTime malaysia = timestamp.toUtc().add(aiFreshnessMalaysiaOffset);
  return '${malaysia.day} ${_month(malaysia.month)} ${malaysia.year}';
}

String aiFreshnessMessage(AiDataFreshness freshness, {required DateTime now}) {
  switch (freshness.state) {
    case AiFreshnessState.noData:
      return 'Not generated yet';
    case AiFreshnessState.timestampUnavailable:
      return 'Weekly insights · timestamp unavailable';
    case AiFreshnessState.fresh:
    case AiFreshnessState.stale:
      final DateTime timestamp = freshness.latestAtUtc!;
      final Duration delta = now.toUtc().difference(timestamp);
      final String age = _relativeAge(delta, timestamp);
      final String missing = freshness.hasMissingTimestamp
          ? ' · some timestamps unavailable'
          : '';
      return 'Weekly insights · updated $age$missing';
  }
}

String _relativeAge(Duration delta, DateTime timestamp) {
  if (delta.isNegative) {
    final Duration ahead = delta.abs();
    if (ahead.inHours < 1) return 'in ${ahead.inMinutes.clamp(1, 59)} min';
    if (ahead.inDays < 1) return 'in ${ahead.inHours} hr';
    return formatAiFreshnessDate(timestamp);
  }
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes} min ago';
  if (delta.inDays < 1) return '${delta.inHours} hr ago';
  if (delta.inDays < 7) {
    final int days = delta.inDays;
    return '$days ${days == 1 ? 'day' : 'days'} ago';
  }
  return formatAiFreshnessDate(timestamp);
}

String _month(int month) => const <String>[
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
][month - 1];
