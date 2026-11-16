String kualaLumpurDateKey([DateTime? instant]) {
  final DateTime local = (instant ?? DateTime.now()).toUtc().add(
    const Duration(hours: 8),
  );
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

bool isValidKualaLumpurDateKey(String date) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) return false;
  final DateTime? parsed = DateTime.tryParse(date);
  if (parsed == null) return false;
  return '${parsed.year.toString().padLeft(4, '0')}-'
          '${parsed.month.toString().padLeft(2, '0')}-'
          '${parsed.day.toString().padLeft(2, '0')}' ==
      date;
}

bool isKualaLumpurFollowUpOverdue(String date, [DateTime? instant]) =>
    isValidKualaLumpurDateKey(date) &&
    date.compareTo(kualaLumpurDateKey(instant)) < 0;
