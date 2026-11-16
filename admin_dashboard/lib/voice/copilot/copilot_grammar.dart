import 'copilot_dates.dart';

part 'copilot_search_grammar.dart';

sealed class CopilotIntent {
  const CopilotIntent();
}

class BriefingIntent extends CopilotIntent {
  const BriefingIntent();
}

class ExplainIntent extends CopilotIntent {
  const ExplainIntent({this.position});
  final int? position;
}

class SetStatusIntent extends CopilotIntent {
  const SetStatusIntent({required this.status, this.position});
  final String status;
  final int? position;
}

class ConfirmIntent extends CopilotIntent {
  const ConfirmIntent();
}

class CancelIntent extends CopilotIntent {
  const CancelIntent();
}

class UnclearIntent extends CopilotIntent {
  const UnclearIntent();
}

class CompoundIntent extends CopilotIntent {
  const CompoundIntent();
}

const Map<String, int> _ordinals = <String, int>{
  'first': 1,
  'second': 2,
  'third': 3,
  'fourth': 4,
  'fifth': 5,
  'sixth': 6,
  'seventh': 7,
  'eighth': 8,
  'ninth': 9,
  'tenth': 10,
  'pertama': 1,
  'kedua': 2,
  'ketiga': 3,
  'keempat': 4,
  'kelima': 5,
  'keenam': 6,
  'ketujuh': 7,
  'kelapan': 8,
  'kesembilan': 9,
  'kesepuluh': 10,
};

final RegExp _briefing = RegExp(
  r'\b(what needs my attention|what should i (focus on|look at|do)|what is important|whats important|'
  r'daily briefing|my briefing|brief me on today|today.s briefing|briefing|'
  r'apa yang perlu|ringkasan harian|apa perlu saya|apa yang penting)\b',
);
final RegExp _briefMe = RegExp(r'^(?:please |tolong )?brief me$');
final RegExp _explain = RegExp(
  r'\b(explain|why is|why|terangkan|jelaskan|kenapa)\b',
);
final RegExp _inReview = RegExp(
  r'\b(in review|under review|for review|dalam semakan|sedang disemak)\b',
);
final RegExp _ignore = RegExp(r'\b(ignore|dismiss|abaikan)\b');

final RegExp _itemWord = RegExp(
  r'\b(it|this|that|item|items|alert|alerts|notification|notifications|amaran|ini|itu|perkara)\b',
);
final RegExp _bareIgnore = RegExp(
  r'^(?:please |tolong )?(?:ignore|dismiss|abaikan)$',
);
bool _namesItem(String text) =>
    _bareIgnore.hasMatch(text) ||
    _itemWord.hasMatch(text) ||
    _positions(text).isNotEmpty;
final RegExp _markVerb = RegExp(r'\b(mark|set|put|tandakan|tetapkan)\b');
final RegExp _confirm = RegExp(
  r'^(confirm|yes|yes confirm|ok confirm|sahkan|ya|ya sahkan)$',
);
final RegExp _cancel = RegExp(
  r'^(cancel|no|never mind|batal|batalkan|tidak|tak jadi)$',
);
final RegExp _compound = RegExp(
  r'\b(then|and then|and also|also|kemudian|lepas itu|dan juga)\b',
);
final RegExp _itemDigits = RegExp(
  r'\b(?:item|number|no|nombor)\s*#?(\d{1,2})\b|#(\d{1,2})\b',
);
final RegExp _bareDigits = RegExp(r'\b(\d{1,2})\b');
final RegExp _question = RegExp(r'^(is|are|was|were|does|did|adakah|apakah)\b');
final RegExp _negation = RegExp(r"\b(don't|dont|do not|never|jangan|not)\b");

String _normalise(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z0-9#\s']"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Set<int> _positions(String text) {
  final Set<int> found = <int>{};
  for (final RegExpMatch m in _itemDigits.allMatches(text)) {
    found.add(int.parse(m.group(1) ?? m.group(2)!));
  }
  for (final MapEntry<String, int> entry in _ordinals.entries) {
    if (RegExp('\\b${entry.key}\\b').hasMatch(text)) found.add(entry.value);
  }
  if (found.isEmpty) {
    final RegExpMatch? bare = _bareDigits.firstMatch(text);
    if (bare != null) found.add(int.parse(bare.group(1)!));
  }
  return found;
}

bool _isStatusCommand(String text, String raw, {required bool review}) =>
    (!review || _markVerb.hasMatch(text)) &&
    !raw.trim().endsWith('?') &&
    !_question.hasMatch(text) &&
    !_negation.hasMatch(text);

CopilotIntent? interpretCopilot(String transcript, {DateTime? now}) {
  final DateTime at = now ?? DateTime.now();
  final String text = _normalise(transcript);
  if (text.isEmpty) return null;
  if (_confirm.hasMatch(text)) return const ConfirmIntent();
  if (_cancel.hasMatch(text)) return const CancelIntent();

  final RankWhyIntent? rankWhy = interpretRankWhy(text, transcript);
  if (rankWhy != null) return rankWhy;

  final BriefRetailerIntent? retailerBrief = interpretRetailerBrief(
    text,
    transcript,
    at,
  );
  if (retailerBrief != null) return retailerBrief;
  final CopilotIntent? extra = interpretExtraCommand(text, transcript, at);
  if (extra != null) return extra;

  final bool wantsBriefing =
      _briefing.hasMatch(text) || _briefMe.hasMatch(_stripTail(text));
  final bool wantsExplain = _explain.hasMatch(text) && !wantsBriefing;
  final bool wantsReview = _inReview.hasMatch(text);
  final bool ignoreWord = _ignore.hasMatch(text);
  final bool wantsIgnore = ignoreWord && _namesItem(text);
  final bool wantsStatus = wantsReview || wantsIgnore;

  final int kinds =
      (wantsBriefing ? 1 : 0) + (wantsExplain ? 1 : 0) + (wantsStatus ? 1 : 0);
  if (kinds == 0) {
    return ignoreWord
        ? const UnclearIntent()
        : interpretOrderCommand(text, transcript, at);
  }
  if (kinds > 1 ||
      (_compound.hasMatch(text) && kinds >= 1 && _hasTwoVerbs(text))) {
    return const CompoundIntent();
  }
  if (wantsBriefing) return const BriefingIntent();
  final Set<int> positions = _positions(text);
  if (positions.length > 1) return const UnclearIntent();
  final int? position = positions.isEmpty ? null : positions.first;
  if (wantsExplain) return ExplainIntent(position: position);
  if (wantsReview && wantsIgnore) return const CompoundIntent();
  if (!_isStatusCommand(text, transcript, review: wantsReview)) {
    return const UnclearIntent();
  }
  return SetStatusIntent(
    status: wantsIgnore ? 'ignored' : 'in_review',
    position: position,
  );
}

bool _hasTwoVerbs(String text) =>
    RegExp(
      r'\b(explain|terangkan|jelaskan|mark|ignore|dismiss|abaikan|tandakan|export|show|tunjuk)\b',
    ).allMatches(text).length >
    1;

CopilotIntent? intentFromCall(
  String name,
  Map<String, Object?> args, {
  DateTime? now,
}) {
  final Object? position = args['position'];
  final int? n = position is int ? position : null;
  if (position != null && n == null) return null;
  switch (name) {
    case 'daily_briefing':
      return const BriefingIntent();
    case 'explain_item':
      return ExplainIntent(position: n);
    case 'search_orders':
      return searchIntentFromCall(args, now ?? DateTime.now());
    case 'export_results':
      return const ExportResultsIntent();
    case 'set_item_status':
      final Object? status = args['status'];
      return status == 'in_review' || status == 'ignored'
          ? SetStatusIntent(status: status as String, position: n)
          : null;
  }
  return null;
}
