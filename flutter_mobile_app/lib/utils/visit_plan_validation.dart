import 'remarks_validator.dart';

class PlannedVisitSlot {
  const PlannedVisitSlot({
    required this.id,
    required this.marketplace,
    required this.date,
    required this.time,
    this.status = 'Planned',
    this.progress = 0,
  });

  final String id;
  final String marketplace;
  final String date;
  final String? time;
  final String status;
  final int progress;
}

String? validateVisitPlan({
  required DateTime? selectedDate,
  required String? selectedMarketplace,
  required String? selectedPurpose,
  required String? selectedTime,
  required Iterable<PlannedVisitSlot> existingVisits,
  String? editingVisitId,
  DateTime? today,
  String? selectedNotes,
}) {
  if (selectedDate == null) return 'Please select a date.';
  if (selectedMarketplace == null || selectedMarketplace.isEmpty) {
    return 'Please select a marketplace.';
  }

  final String trimmedPurpose = (selectedPurpose ?? '').trim();
  if (trimmedPurpose.isEmpty) {
    return 'Please enter a purpose for the visit.';
  }
  if (trimmedPurpose.length < 3) {
    return 'Purpose is too short — please add a few more words.';
  }
  if (!RemarksValidator.hasOnlyAllowedCharacters(trimmedPurpose)) {
    return 'Purpose can use only letters, numbers, spaces and basic punctuation.';
  }
  if (_looksLikeGibberish(trimmedPurpose)) {
    return 'Purpose doesn\'t look like a real entry — please check what you typed.';
  }

  final String trimmedNotes = (selectedNotes ?? '').trim();
  if (trimmedNotes.isNotEmpty) {
    if (trimmedNotes.length < 3) {
      return 'Notes are too short — remove it or add a few more words.';
    }
    if (!RemarksValidator.hasOnlyAllowedCharacters(trimmedNotes)) {
      return 'Notes can use only letters, numbers, spaces and basic punctuation.';
    }
    if (_looksLikeGibberish(trimmedNotes)) {
      return 'Notes don\'t look like a real entry — please check what you typed.';
    }
  }

  final DateTime selectedDay = _dateOnly(selectedDate);
  final DateTime currentDay = _dateOnly(today ?? DateTime.now());
  if (selectedDay.isBefore(currentDay)) {
    return 'Cannot schedule visits for past dates.';
  }

  for (final PlannedVisitSlot visit in existingVisits) {
    if (visit.id == editingVisitId) continue;
    final DateTime? visitDate = DateTime.tryParse(visit.date);
    if (visitDate != null &&
        _dateOnly(visitDate) == selectedDay &&
        visit.time == selectedTime) {
      return 'You already have a visit planned at $selectedTime on this date.';
    }
  }

  return null;
}

enum RepeatVisitKind {
  none,

  warn,

  followUp,
}

class RepeatVisitResult {
  const RepeatVisitResult(this.kind, {this.message, this.suggestedPurpose});

  const RepeatVisitResult.none() : this(RepeatVisitKind.none);

  final RepeatVisitKind kind;

  final String? message;

  final String? suggestedPurpose;
}

RepeatVisitResult checkRepeatVisit({
  required DateTime? selectedDate,
  required String? selectedMarketplace,
  required Iterable<PlannedVisitSlot> existingVisits,
  String? editingVisitId,
  DateTime? today,
}) {
  if (selectedDate == null) return const RepeatVisitResult.none();
  final String wanted = _normalizeName(selectedMarketplace);
  if (wanted.isEmpty) return const RepeatVisitResult.none();

  final DateTime selectedDay = _dateOnly(selectedDate);
  final DateTime currentDay = _dateOnly(today ?? DateTime.now());
  final DateTime weekStart = selectedDay.subtract(
    Duration(days: selectedDay.weekday - DateTime.monday),
  );
  final DateTime weekEnd = weekStart.add(const Duration(days: 6));

  final List<_RepeatMatch> counted = <_RepeatMatch>[];
  final List<_RepeatMatch> unfinishedPast = <_RepeatMatch>[];

  for (final PlannedVisitSlot visit in existingVisits) {
    if (visit.id == editingVisitId) continue;
    if (_normalizeName(visit.marketplace) != wanted) continue;
    final DateTime? parsed = DateTime.tryParse(visit.date);
    if (parsed == null) continue;
    final DateTime day = _dateOnly(parsed);
    if (day.isBefore(weekStart) || day.isAfter(weekEnd)) continue;

    final bool isUnfinishedPast =
        day.isBefore(currentDay) && !_isCompleted(visit);
    (isUnfinishedPast ? unfinishedPast : counted).add(
      _RepeatMatch(day, visit.marketplace),
    );
  }

  if (counted.isNotEmpty) {
    counted.sort((_RepeatMatch a, _RepeatMatch b) => a.day.compareTo(b.day));
    final String name = counted.first.name;
    final String message = counted.length == 1
        ? 'You already have a visit to $name on ${_dayLabel(counted.first.day)} '
              'this week. Do you still want to plan another visit?'
        : 'You already have ${counted.length} visits to $name this week '
              '(${counted.map((_RepeatMatch m) => _dayLabel(m.day)).join(', ')}). '
              'Do you still want to plan another visit?';
    return RepeatVisitResult(RepeatVisitKind.warn, message: message);
  }

  if (unfinishedPast.isNotEmpty) {
    unfinishedPast.sort(
      (_RepeatMatch a, _RepeatMatch b) => a.day.compareTo(b.day),
    );
    final DateTime latest = unfinishedPast.last.day;
    return RepeatVisitResult(
      RepeatVisitKind.followUp,
      suggestedPurpose:
          'Follow-up: previous visit on ${_dayLabel(latest)} was not completed',
    );
  }

  return const RepeatVisitResult.none();
}

class _RepeatMatch {
  const _RepeatMatch(this.day, this.name);
  final DateTime day;
  final String name;
}

bool _isCompleted(PlannedVisitSlot visit) =>
    visit.progress == 3 || visit.status.trim().toLowerCase() == 'completed';

String _normalizeName(String? value) =>
    (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

String _dayLabel(DateTime day) {
  const List<String> weekdays = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  const List<String> months = <String>[
    '',
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
  return '${weekdays[day.weekday - 1]}, ${day.day} ${months[day.month]}';
}

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

bool _looksLikeGibberish(String text) {
  final String t = text.toLowerCase();
  if (!RegExp(r'[aeiou]').hasMatch(t)) return true;
  if (RegExp(r'(.)\1{3,}').hasMatch(t)) return true;
  if (RegExp(r'[^aeiou\s\d\W]{6,}').hasMatch(t)) return true;
  if (t.split(RegExp(r'\s+')).any((String word) => word.length > 20)) {
    return true;
  }
  return RemarksValidator.validateContent(text) != null;
}