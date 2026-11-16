part of 'copilot_grammar.dart';

class SearchOrdersIntent extends CopilotIntent {
  const SearchOrdersIntent({
    this.salesperson,
    this.retailer,
    this.anyName,
    this.period,
    this.status,
    this.refine = false,
    this.fromModel = false,
  });

  final String? salesperson;
  final String? retailer;
  final String? anyName;
  final CopilotRange? period;

  final String? status;

  final bool refine;

  final bool fromModel;
}

class ExportResultsIntent extends CopilotIntent {
  const ExportResultsIntent({this.search});
  final SearchOrdersIntent? search;
}

final RegExp _exportRequest = RegExp(
  r'^(?:(?:can|could|would|will) you |please |tolong |i want to |i would like to |i need to |let me |help me |give me |send me |get me |make me )*'
  r'(?:(?:export|download|eksport|muat ?turun) |(?:an? |the )?(?:spreadsheet|csv|excel|xlsx)(?: file)?(?: of| for| with)? )(.+)$',
);
final RegExp _exportFormat = RegExp(
  r'\s+(?:as|to|in|into|ke|sebagai)\s+(?:an? )?(?:csv|excel|xlsx|spreadsheet|file|fail)(?: file)?$',
);

final RegExp _writeVerb = RegExp(
  r'^(?:(?:can|could|would|will) you |please |tolong )*(?:reject|delete|remove|padam|buang)\b',
);

class PickIntent extends CopilotIntent {
  const PickIntent(this.position);
  final int position;
}

class BriefRetailerIntent extends CopilotIntent {
  const BriefRetailerIntent(this.name, {this.period});
  final String name;
  final CopilotRange? period;
}

class RankWhyIntent extends CopilotIntent {
  const RankWhyIntent(this.name);
  final String name;
}

class ResetFiltersIntent extends CopilotIntent {
  const ResetFiltersIntent();
}

class OpenResultIntent extends CopilotIntent {
  const OpenResultIntent(this.position);
  final int position;
}

class SmallTalkIntent extends CopilotIntent {
  const SmallTalkIntent();
}

class TopIntent extends CopilotIntent {
  const TopIntent({
    required this.retailers,
    required this.range,
    this.limit = 5,
  });
  final bool retailers;
  final CopilotRange range;
  final int limit;
}

class OpenProgressIntent extends CopilotIntent {
  const OpenProgressIntent(this.range);
  final CopilotRange range;
}

enum ActionRequestKind { approveOrders, createRoute }

class ActionRequestIntent extends CopilotIntent {
  const ActionRequestIntent({required this.kind, this.name, this.range});
  final ActionRequestKind kind;
  final String? name;
  final CopilotRange? range;
}

const Map<String, int> _cardinals = <String, int>{
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'satu': 1,
  'dua': 2,
  'tiga': 3,
  'empat': 4,
  'lima': 5,
  'enam': 6,
  'tujuh': 7,
  'lapan': 8,
  'sembilan': 9,
  'sepuluh': 10,
};

final List<String> _englishNumbers = <String>[
  'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
  'ten',
];

final String _ord =
    '(${(<String>[..._ordinals.keys, ..._cardinals.keys]..sort((String a, String b) => b.length.compareTo(a.length))).join('|')}|\\d{1,2})';
final RegExp _pickWord = RegExp('^(?:the |yang )?$_ord(?: one| satu)?\$');
final RegExp _pickNumber = RegExp('^(?:number|nombor|no) $_ord\$');
final RegExp _openWord = RegExp(
  '^(?:open|buka|show|tunjuk) (?:the |yang )?(?:order |pesanan |number |nombor |no )?$_ord(?: one| order| pesanan)?\$',
);
int _ordValue(String word) =>
    _ordinals[word] ?? _cardinals[word] ?? int.parse(word);

final RegExp _exportCommand = RegExp(
  r'^(?:please |tolong )?(?:export|download|eksport|muat ?turun|simpan)'
  r'(?:\s+(?:these|this|them|it|that|the|results?|list|orders?|all|as|to|a|csv|file|ini|itu|semua|senarai|hasil|pesanan|ke|sebagai|fail))*$',
);

final RegExp _polite = RegExp(
  r'^(?:(?:can|could|would|will) you |please |tolong )+',
);
final RegExp _tail = RegExp(
  r'\s+(?:please|pls|plz|tolong|ya|ok|okay|now|again|thanks|thank you|for me|untuk saya|ones|one|yang|(?:that|which) (?:are|is|were|was))$',
);
final RegExp _lead = RegExp(
  r"^(?:can you|could you|would you|will you|please|tolong|hey|i want to|i'd like to|i would like to|let me|help me|"
  r'what are|what is|what were|what was|how many|give me|pull up|search for|show me|tell me|'
  r'show|list|find|get|check|see|display|open|view|tunjukkan|tunjuk|paparkan|papar|senaraikan|senarai|cari|lihat|semak|'
  r'berapa banyak|berapa|buka|halaman|laman|the|all|my|our|me|any|some|new|latest|recent|total|ya|yang)\b\s*',
);

final RegExp _orderNoun = RegExp(r'\b(?:orders?|pesanan|tempahan)\b');
const String _noun = r'(?:orders?|pesanan|tempahan)';
final RegExp _countQuestion = RegExp(
  r'\b(?:how many|berapa(?: banyak)?|number of|count)\b',
);
final RegExp _negatedStatus = RegExp(
  r"\b(?:not|isnt|isn't|never|bukan|tidak|tak|without)\s+(?:yet\s+|been\s+|lagi\s+)?(?:approved|rejected|submitted|pending|lulus|diluluskan|ditolak)\b",
);
final RegExp _submittedAdjective = RegExp(
  r'\b(?:submitted|pending)\s+(?=(?:orders?|ones|pesanan|tempahan)\b)',
);
final RegExp _submittedStatus = RegExp(
  r'\bpending(?: approval)?\b|\b(?:waiting|awaiting)(?: for)? approval\b|\bbelum (?:di)?lulus(?:kan)?\b|\bmenunggu kelulusan\b',
);
final RegExp _approvedStatus = RegExp(r'\b(?:approved|lulus|diluluskan)\b');
final RegExp _rejectedStatus = RegExp(
  r'\b(?:rejected|declined|ditolak|cancell?ed|dibatalkan)\b',
);

const String _rangePrefix =
    r'(?:\b(?:in|during|for|of|over|within)\s+(?:the\s+)?)?';
const String _monthWords =
    'january|february|march|april|may|june|july|august|september|october|'
    'november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec';

const Set<String> _nameMonths = <String>{
  'may', 'jun', 'june', 'april', 'august', 'jan', 'mar', 'apr', 'aug',
};

const Map<String, int> _monthNumbers = <String, int>{
  'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
  'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7,
  'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9, 'oct': 10,
  'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
};

final RegExp _pastDaysRange = RegExp(
  '$_rangePrefix\\b(?:past|last|previous)\\s+(few|couple of|\\d{1,3}|${_englishNumbers.join('|')})\\s+(days?|weeks?|months?)\\b',
);
final RegExp _pastUnitRange = RegExp('$_rangePrefix\\bpast\\s+(week|month)\\b');
final RegExp _monthRange = RegExp(
  '(?:\\b(in|during|for|of)\\s+(?:the\\s+)?)?(month\\s+of\\s+)?\\b($_monthWords)\\b',
);

final List<(CopilotRangeKind, RegExp)>
_fixedRanges = <(CopilotRangeKind, RegExp)>[
  (
    CopilotRangeKind.today,
    RegExp('$_rangePrefix\\b(?:today|hari ini|harini)\\b'),
  ),
  (
    CopilotRangeKind.yesterday,
    RegExp('$_rangePrefix\\b(?:yesterday|semalam)\\b'),
  ),
  (
    CopilotRangeKind.thisWeek,
    RegExp('$_rangePrefix\\b(?:this week|minggu ini|minggu ni)\\b'),
  ),
  (
    CopilotRangeKind.lastWeek,
    RegExp(
      '$_rangePrefix\\b(?:last week|previous week|minggu lepas|minggu lalu|minggu sudah)\\b',
    ),
  ),
  (
    CopilotRangeKind.nextWeek,
    RegExp('$_rangePrefix\\b(?:next week|minggu depan)\\b'),
  ),
  (
    CopilotRangeKind.thisMonth,
    RegExp('$_rangePrefix\\b(?:this month|bulan ini|bulan ni)\\b'),
  ),
  (
    CopilotRangeKind.lastMonth,
    RegExp(
      '$_rangePrefix\\b(?:last month|previous month|bulan lepas|bulan lalu|bulan sudah)\\b',
    ),
  ),
];

({List<CopilotRange> ranges, String rest}) _takeRanges(
  String text,
  DateTime now,
) {
  final List<(int, int, CopilotRange)> hits = <(int, int, CopilotRange)>[];
  bool free(int a, int b) =>
      hits.every(((int, int, CopilotRange) h) => b <= h.$1 || a >= h.$2);

  for (final RegExpMatch m in _pastDaysRange.allMatches(text)) {
    final String amount = m.group(1)!;
    final String unit = m.group(2)!;
    final bool few = amount == 'few';
    final int n = few
        ? 0
        : amount == 'couple of'
        ? 2
        : int.tryParse(amount) ?? _cardinals[amount]!;
    final int days = unit.startsWith('day')
        ? (few ? 7 : n)
        : unit.startsWith('week')
        ? (few ? 28 : n * 7)
        : (few ? 90 : n * 30);
    if (days < 1 || days > 366 || !free(m.start, m.end)) continue;
    hits.add((
      m.start,
      m.end,
      copilotRange(CopilotRangeKind.pastDays, now, days: days),
    ));
  }
  for (final RegExpMatch m in _pastUnitRange.allMatches(text)) {
    if (!free(m.start, m.end)) continue;
    final int days = m.group(1) == 'week' ? 7 : 30;
    hits.add((
      m.start,
      m.end,
      copilotRange(CopilotRangeKind.pastDays, now, days: days),
    ));
  }
  for (final (CopilotRangeKind kind, RegExp re) in _fixedRanges) {
    for (final RegExpMatch m in re.allMatches(text)) {
      if (!free(m.start, m.end)) continue;
      hits.add((m.start, m.end, copilotRange(kind, now)));
    }
  }
  for (final RegExpMatch m in _monthRange.allMatches(text)) {
    final String word = m.group(3)!;
    final bool marked = m.group(1) != null || m.group(2) != null;
    if (_nameMonths.contains(word) && !marked) continue;
    if (!free(m.start, m.end)) continue;
    hits.add((m.start, m.end, copilotMonthRange(_monthNumbers[word]!, now)));
  }
  hits.sort(
    ((int, int, CopilotRange) a, (int, int, CopilotRange) b) =>
        a.$1.compareTo(b.$1),
  );
  final StringBuffer rest = StringBuffer();
  int at = 0;
  for (final (int a, int b, CopilotRange _) in hits) {
    rest
      ..write(text.substring(at, a))
      ..write(' ');
    at = b;
  }
  rest.write(text.substring(at));
  final List<CopilotRange> ranges = <CopilotRange>[];
  for (final (int _, int _, CopilotRange r) in hits) {
    if (!ranges.contains(r)) ranges.add(r);
  }
  return (
    ranges: ranges,
    rest: rest.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
  );
}

const String _prepAny =
    r'(?:by|oleh|for|at|to|untuk|di|kepada|bagi|from|of|daripada|dari)';
const String _stop = r'(.+?)(?=\s+' + _prepAny + r'\b|$)';
final RegExp _bySlot = RegExp(r'\b(?:by|oleh)\s+' + _stop);
final RegExp _forSlot = RegExp(
  r'\b(?:for|at|to|untuk|di|kepada|bagi)\s+' + _stop,
);
final RegExp _fromSlot = RegExp(r'\b(?:from|of|daripada|dari)\s+' + _stop);
final RegExp _didSlot = RegExp(
  r'\b(?:did|has|have|does)\s+(.+?)\s+(?:submit|submitted|send|sent|take|took|make|made|place|placed|get|got|raise)\b',
);
final RegExp _verbAfterSlot = RegExp(
  r'\b' + _noun + r'\s+(.+?)\s+(?:submitted|sent|took|made|placed)\b',
);
final RegExp _malayVerbSlot = RegExp(
  r'\b(?:pesanan|tempahan)\s+(.+?)\s+(?:hantar|hantarkan|buat|ambil|masukkan)\b',
);
final RegExp _malayBare = RegExp(r'\b(?:pesanan|tempahan)\s+(?!yang\b)(.+)$');
final RegExp _prefixSlot = RegExp(r'^(.+?)\s+' + _noun + r'\b');
final RegExp _possessive = RegExp(r"^(.+?)(?:'s| s)$");
final RegExp _startsWithPrep = RegExp('^$_prepAny\\b');

final RegExp _refOnly = RegExp(r'^(?:only|just|hanya|cuma)\s+(.+)$');
final RegExp _refSuffix = RegExp(r'^(.+?)\s+(?:only|sahaja|saja|je|aje|pula)$');
final RegExp _refAbout = RegExp(
  r'^(?:what about|how about|same but for|now|bagaimana dengan|macam mana dengan)\s+(.+)$',
);
final RegExp _refInstead = RegExp(r'\binstead\b');
final RegExp _refOnes = RegExp(
  r'^(?:just )?the (approved|rejected|pending|submitted) ones$',
);

const Set<String> _fillerWords = <String>{
  'i', 'you', 'we', 'he', 'she', 'it', 'they', 'is', 'are', 'was', 'were',
  'am', 'be', 'been', 'do', 'does', 'did', 'has', 'have', 'had', 'can',
  'could', 'will', 'would', 'should', 'that', 'thats', "that's", 'this',
  'these', 'those', 'there', 'here', 'what', 'how', 'why', 'when', 'where',
  'who', 'which', 'not', 'no', 'yes', 'want', 'need', 'show', 'list', 'open',
  'buka', 'go', 'take', 'my', 'your', 'our', 'and', 'or', 'but', 'then',
  'also', 'with', 'just', 'only', 'if', 'so', 'as', 'in', 'on', 'a', 'an',
  'approve', 'review', 'process', 'tunjuk', 'ini', 'itu', 'apa', 'dan',
  'cuma', 'hanya', 'sahaja', 'saya', 'kita', 'whats', "what's", 'wat', 'wats',
  'every', 'each',
};

const Set<String> _notNames = <String>{
  'reports', 'report', 'retailers', 'retailer', 'salesman', 'salesmen',
  'salesperson', 'salespeople', 'products', 'product', 'dashboard',
  'overview', 'settings', 'users', 'user', 'tracking', 'routes', 'route',
  'forecast', 'forecasts', 'prediction', 'inventory', 'targets', 'audit',
  'visits', 'schedule', 'catalogue', 'catalog', 'planner', 'map', 'team',
  'sales', 'purchase', 'special', 'approval', 'approvals', 'procurement',
  'po', 'page', 'screen', 'tab', 'section', 'history', 'summary', 'details',
  'data', 'status', 'queue', 'table', 'again', 'now', 'them', 'one', 'ones',
  'all', 'everything', 'me', 'us', 'the', 'yang', 'of', 'to', 'for', 'by',
  'at', 'from', 'today', 'week', 'month', 'jurujual', 'kedai', 'semua',
  'branch', 'branches', 'draft', 'drafts',
};

const Set<String> _glue = <String>{
  'the', 'yang', 'ones', 'one', 'orders', 'order', 'pesanan', 'tempahan',
  "'s", 's', 'please', 'tolong', 'ya',
};

class _Parsed {
  CopilotRange? period;
  String? status;
  bool weakStatus = false;
  String? salesperson;
  String? retailer;
  String? anyName;
  bool count = false;
  bool conflict = false;

  bool get hasName =>
      salesperson != null || retailer != null || anyName != null;

  bool get qualifies =>
      period != null || (status != null && !weakStatus) || hasName || count;
}

String _stripTail(String s) {
  String r = s.trim();
  while (_tail.hasMatch(r)) {
    r = r.replaceFirst(_tail, '');
  }
  return r;
}

String _stripLead(String s) {
  String r = s.trim();
  while (_lead.hasMatch(r)) {
    r = r.replaceFirst(_lead, '');
  }
  return r;
}

String _tidy(String s) => _stripTail(
  _stripLead(
    s.replaceAll(RegExp(r"(^|\s)'s\b"), ' ').replaceAll(RegExp(r'\s+'), ' '),
  ),
);

String _original(String name, String raw) {
  final String pattern = name
      .split(' ')
      .where((String t) => t.isNotEmpty)
      .map(RegExp.escape)
      .join(r"[^A-Za-z0-9']+");
  final RegExpMatch? m = RegExp(pattern, caseSensitive: false).firstMatch(raw);
  return m?.group(0) ?? name;
}

String? _cleanName(String? value, String raw, {bool strict = false}) {
  if (value == null) return null;
  final List<String> toks = value
      .split(' ')
      .where((String t) => t.isNotEmpty)
      .toList();
  while (toks.isNotEmpty && _glue.contains(toks.first)) {
    toks.removeAt(0);
  }
  while (toks.isNotEmpty && _glue.contains(toks.last)) {
    toks.removeLast();
  }
  if (toks.isEmpty) return null;
  toks[toks.length - 1] = toks.last.replaceFirst(RegExp(r"'s$"), '');
  if (toks.length > 6) return null;
  if (!RegExp(r'[a-z]').hasMatch(toks.join(' '))) return null;
  if (toks.length == 1 && toks.first.length < 2) return null;
  if (_fillerWords.contains(toks.first)) return null;
  if (strict && toks.any((String t) => t != 'a' && _fillerWords.contains(t))) {
    return null;
  }
  if (toks.any(_orderNoun.hasMatch)) return null;
  if (toks.every(_notNames.contains)) return null;
  return _original(toks.join(' '), raw);
}

_Parsed _extract(String text, String raw, DateTime now, {required bool loose}) {
  final _Parsed p = _Parsed();
  String s = text;
  p.count = _countQuestion.hasMatch(s);

  final taken = _takeRanges(s, now);
  if (taken.ranges.length > 1) p.conflict = true;
  p.period = taken.ranges.length == 1 ? taken.ranges.first : null;
  s = taken.rest;

  if (_negatedStatus.hasMatch(s)) p.conflict = true;
  final Set<String> statuses = <String>{};
  final bool strongSubmitted = _submittedStatus.hasMatch(s);
  final bool adjective = _submittedAdjective.hasMatch(s);
  if (strongSubmitted || adjective) statuses.add('submitted');
  p.weakStatus = adjective && !strongSubmitted;
  s = s.replaceAll(_submittedAdjective, ' ').replaceAll(_submittedStatus, ' ');
  if (_approvedStatus.hasMatch(s)) statuses.add('approved');
  if (_rejectedStatus.hasMatch(s)) statuses.add('rejected');
  s = s.replaceAll(_approvedStatus, ' ').replaceAll(_rejectedStatus, ' ');
  if (statuses.length > 1) p.conflict = true;
  if (statuses.length == 1) p.status = statuses.first;

  s = _tidy(s.replaceAll(_countQuestion, ' '));

  String? firstName(RegExp re, {bool strict = false}) {
    for (final RegExpMatch m in re.allMatches(s)) {
      final String? n = _cleanName(m.group(1), raw, strict: strict);
      if (n != null) return n;
    }
    return null;
  }

  p.salesperson = firstName(_bySlot) ?? firstName(_didSlot);
  p.retailer = firstName(_forSlot);
  p.anyName = firstName(_fromSlot);
  p.salesperson ??= firstName(_malayVerbSlot, strict: true);
  if (!p.hasName) {
    final String? v = firstName(_verbAfterSlot, strict: true);
    if (v != null && !_startsWithPrep.hasMatch(v.toLowerCase())) {
      p.salesperson = v;
    }
  }
  if (!p.hasName) {
    final RegExpMatch? m = _prefixSlot.firstMatch(s);
    if (m != null) {
      final String prefix = m.group(1)!;
      final RegExpMatch? poss = _possessive.firstMatch(prefix);
      if (poss != null) {
        p.salesperson = _cleanName(poss.group(1), raw, strict: true);
      } else {
        p.anyName = _cleanName(prefix, raw, strict: true);
      }
    }
  }
  if (!p.hasName) {
    final RegExpMatch? m = _malayBare.firstMatch(s);
    if (m != null && !_startsWithPrep.hasMatch(m.group(1)!)) {
      p.anyName = _cleanName(m.group(1), raw, strict: true);
    }
  }
  if (!p.hasName && loose) {
    p.anyName = _cleanName(
      _tidy(s.replaceAll(RegExp(_noun), ' ')),
      raw,
      strict: true,
    );
  }
  return p;
}

SearchOrdersIntent _asSearch(_Parsed p, {required bool refine}) =>
    SearchOrdersIntent(
      salesperson: p.salesperson,
      retailer: p.retailer,
      anyName: p.anyName,
      period: p.period,
      status: p.status,
      refine: refine,
    );

final RegExp _resetCommand = RegExp(
  r'^(?:please |tolong )?(?:start over|start again|clear (?:the |all )?filters?|reset(?: (?:the |all )?filters?)?|all salespeople|all retailers|semua jurujual|semua kedai|mula semula|kosongkan penapis)$',
);

final RegExp _pendingApprovals = RegExp(
  r'^(?:please |tolong )?(?:(?:show|list|find|check|how many|tunjuk(?:kan)?|senarai(?:kan)?|berapa)(?: me)? )?(?:the |all |my )?(?:pending|waiting|awaiting) (?:for )?approvals?(?: (.+))?$'
  r'|^(?:pesanan )?(?:belum diluluskan|menunggu kelulusan)(?: (.+))?$',
);

final RegExp _briefCommand = RegExp(
  r'^(?:(?:can you|could you|please|tolong) )*'
  r'(?:(?:give me|show me|get|prepare|make|write|buat|sediakan|beri saya|bagi saya) )?'
  r'(?:an? |the )?(?:(?:retailer|shop|store|kedai|peruncit) )?'
  r'(?:brief|summary|profile|snapshot|ringkasan|profil)'
  r'(?: (?:retailer|shop|store|kedai|peruncit))?'
  r'(?: (?:on|for|of|about|untuk|mengenai|tentang))? (.+)$'
  r'|^(?:tell me about|how is|summari[sz]e|ceritakan tentang|ringkaskan) (.+?)(?: doing)?$',
);

BriefRetailerIntent? interpretRetailerBrief(
  String text,
  String raw,
  DateTime now,
) {
  final RegExpMatch? m = _briefCommand.firstMatch(_stripTail(text));
  if (m == null) return null;
  String body = (m.group(1) ?? m.group(2))!;
  final taken = _takeRanges(body, now);
  if (taken.ranges.length > 1) return null;
  body = taken.rest
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceFirst(RegExp(r'\s(?:in|for|during|dalam|pada)$'), '')
      .trim();
  final String? name = _cleanName(body, raw, strict: true);
  if (name == null) return null;
  return BriefRetailerIntent(
    name,
    period: taken.ranges.length == 1 ? taken.ranges.first : null,
  );
}

final RegExp _rankWhyCommand = RegExp(
  r'^(?:why|kenapa|mengapa) (?:(?:is|was|does|did|has|adakah) )?(.+?)'
  r'(?: (?:ranked|rank|ranks|ranking|placed|listed|at|on|in|the|a|an|our|my|so|this|weeks?|di|berada|tempat))*'
  r' (top|first|1st|highest|number (?:one|1)|no 1|# ?1|rank(?:ed)? (?:# ?)?(?:1|one)|priority|high|nombor (?:satu|1)|teratas|tertinggi|keutamaan|pertama)'
  r'((?: (?:priority|priorities|pick|choice|retailer|shop|store|outlet|spot|place|position|on|in|of|the|list|ranking|rankings|this|week|today|now|please|utama|sekali|dalam|senarai|minggu|ini|tolong))*)$',
);
final RegExp _itemReference = RegExp(
  r'\b(?:item|items|perkara|number|nombor)\b',
);

RankWhyIntent? interpretRankWhy(String text, String raw) {
  final RegExpMatch? m = _rankWhyCommand.firstMatch(text);
  if (m == null) return null;
  final String body = m.group(1)!;
  if (_itemReference.hasMatch(body)) return null;
  final List<String> tokens = body.split(' ');
  if (tokens.every(
    (String t) =>
        _glue.contains(t) ||
        _ordinals.containsKey(t) ||
        _cardinals.containsKey(t) ||
        RegExp(r'^#?\d+$').hasMatch(t),
  )) {
    return null;
  }
  final String? name = _cleanName(body, raw, strict: true);
  return name == null ? null : RankWhyIntent(name);
}

CopilotIntent? interpretOrderCommand(String text, String raw, DateTime now) {
  final String whole = text.trim();
  if (whole.isEmpty) return null;
  if (_resetCommand.hasMatch(whole)) return const ResetFiltersIntent();
  final RegExpMatch? approvals = _pendingApprovals.firstMatch(whole);
  if (approvals != null) {
    final String rest = (approvals.group(1) ?? approvals.group(2) ?? '').trim();
    final CopilotRange? period = rest.isEmpty ? null : periodInText(rest, now);
    if (rest.isNotEmpty && period == null) return null;
    return SearchOrdersIntent(status: 'submitted', period: period);
  }

  final RegExpMatch? open = _openWord.firstMatch(whole);
  if (open != null) return OpenResultIntent(_ordValue(open.group(1)!));
  final RegExpMatch? pick =
      _pickWord.firstMatch(whole) ?? _pickNumber.firstMatch(whole);
  if (pick != null) return PickIntent(_ordValue(pick.group(1)!));

  final String t = _stripTail(whole);
  if (t.isEmpty) return null;
  if (_exportCommand.hasMatch(t)) return const ExportResultsIntent();
  if (_writeVerb.hasMatch(t)) return null;

  final RegExpMatch? export = _exportRequest.firstMatch(t);
  if (export != null) {
    final String rest = export.group(1)!.replaceFirst(_exportFormat, '');
    if (_orderNoun.hasMatch(rest)) {
      final _Parsed e = _extract(rest, raw, now, loose: false);
      if (e.conflict) return const UnclearIntent();
      return ExportResultsIntent(
        search: e.qualifies ? _asSearch(e, refine: false) : null,
      );
    }
  }

  if (_negatedStatus.hasMatch(t)) return const UnclearIntent();

  final String lead = t.replaceFirst(_polite, '');
  String? body;
  final RegExpMatch? ones = _refOnes.firstMatch(lead);
  if (ones != null) {
    body = ones.group(1) == 'submitted' ? 'pending' : ones.group(1);
  } else {
    body =
        _refOnly.firstMatch(lead)?.group(1) ??
        _refSuffix.firstMatch(lead)?.group(1) ??
        _refAbout.firstMatch(lead)?.group(1) ??
        (_refInstead.hasMatch(lead) ? lead.replaceAll(_refInstead, ' ') : null);
  }
  if (body != null) {
    final _Parsed r = _extract(_tidy(body), raw, now, loose: true);
    if (r.conflict) return const UnclearIntent();
    if (r.qualifies) return _asSearch(r, refine: true);
  }

  if (!_orderNoun.hasMatch(t)) return null;
  final _Parsed p = _extract(t, raw, now, loose: false);
  if (p.conflict) return const UnclearIntent();
  if (!p.qualifies) return null;
  return _asSearch(p, refine: false);
}

CopilotRange? periodInText(String text, DateTime now) {
  final List<CopilotRange> ranges = _takeRanges(text, now).ranges;
  return ranges.length == 1 ? ranges.first : null;
}

final RegExp _modelText = RegExp(r"^[\p{L}\p{N} .,'&/()-]+$", unicode: true);

CopilotIntent? searchIntentFromCall(Map<String, Object?> args, DateTime now) {
  const Set<String> known = <String>{
    'salesperson', 'retailer', 'period', 'status',
  };
  if (args.keys.any((String k) => !known.contains(k))) return null;
  final Map<String, String> v = <String, String>{};
  for (final String key in known) {
    final Object? value = args[key];
    if (value == null) continue;
    if (value is! String) return null;
    final String t = value.trim();
    if (t.isEmpty || t.length > 80) return null;
    final bool isName = key == 'salesperson' || key == 'retailer';
    if (isName && !_modelText.hasMatch(t)) return null;
    v[key] = t;
  }
  final String? periodKey = v['period'];
  final CopilotRange? period = periodKey == null
      ? null
      : copilotPeriodFromKey(periodKey, now: now);
  if (periodKey != null && period == null) return null;
  final String? status = v['status'];
  if (status != null &&
      status != 'submitted' &&
      status != 'approved' &&
      status != 'rejected') {
    return null;
  }
  if (v.isEmpty) return null;
  return SearchOrdersIntent(
    salesperson: v['salesperson'],
    retailer: v['retailer'],
    period: period,
    status: status,
    fromModel: true,
  );
}

final RegExp _smallTalk = RegExp(
  r"^(?:(?:hi|hello|hey|hai|helo|yo)(?: there| copilot| scout| assistant)?|how are you(?: doing| today| feeling)?|how are u|how r u|how is it going|hows it going|how's it going|good (?:morning|afternoon|evening)|selamat (?:pagi|petang|tengah hari|malam)|apa khabar|thanks?|thank you|terima kasih|who are you|what can you do|what do you do|help|help me|bantuan)$",
);

final RegExp _topRetailers = RegExp(
  r'\b(?:top|best|biggest|highest|leading)(?:\s+(\d{1,2}))?\s+(?:selling\s+|buying\s+|performing\s+)?(?:retailers?|shops?|stores?|outlets?|customers?|kedai|peruncit)\b',
);
final RegExp _topProducts = RegExp(
  r'\b(?:top|best|biggest|highest|leading|best selling|most sold)(?:\s+(\d{1,2}))?\s+(?:selling\s+|sold\s+)?(?:products?|items?|skus?|produk|barang)\b',
);
final RegExp _progressCommand = RegExp(
  r"\b(?:salesm[ae]n|salesperson|salespeople|sales team|jurujual|team)(?:'s|s)?\s+(?:progress|activity|tracking)\b|\b(?:progress|activity)\s+(?:of|for)\s+(?:my\s+|the\s+)?(?:salesm[ae]n|salespeople|team|jurujual)\b|\bhow (?:are|is) my (?:salesm[ae]n|salespeople|team) doing\b",
);
final RegExp _approveCommand = RegExp(
  r'^(?:(?:please|tolong|can you|could you|would you|i want to|i would like to|let me) )*(?:approve|accept|authori[sz]e|lulus(?:kan)?)\b(.*)$',
);
final RegExp _createRouteCommand = RegExp(
  r'^(?:(?:please|tolong|can you|could you|would you|i want to|i would like to|let me|help me) )*(?:create|make|build|plan|set up|add|generate|buat|cipta)\s+(?:an? |the |new |weekly |another )*(?:route plans?|routes?|laluan)\b(.*)$',
);
final RegExp _actionNoise = RegExp(
  r'\b(?:orders?|pesanan|tempahan|pending|submitted|all|everything|it|them|these|those|the|my|our|please|ya|for|of|from|by|salesm[ae]n|salesperson|salespeople|rep|jurujual|retailers?|routes?|plans?)\b',
);

String? _actionName(String rest, String raw) {
  final String s = rest
      .replaceAll(_actionNoise, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s.isEmpty ? null : _cleanName(s, raw, strict: true);
}

CopilotIntent? interpretExtraCommand(String text, String raw, DateTime now) {
  final String whole = _stripTail(text);
  if (_smallTalk.hasMatch(whole)) return const SmallTalkIntent();

  final taken = _takeRanges(whole, now);
  final CopilotRange? one = taken.ranges.length == 1
      ? taken.ranges.first
      : null;

  final RegExpMatch? approve = _approveCommand.firstMatch(whole);
  if (approve != null) {
    return ActionRequestIntent(
      kind: ActionRequestKind.approveOrders,
      name: _actionName(_takeRanges(approve.group(1)!, now).rest, raw),
      range: one,
    );
  }
  final RegExpMatch? route = _createRouteCommand.firstMatch(whole);
  if (route != null) {
    return ActionRequestIntent(
      kind: ActionRequestKind.createRoute,
      name: _actionName(_takeRanges(route.group(1)!, now).rest, raw),
      range: one,
    );
  }

  final RegExpMatch? retailers = _topRetailers.firstMatch(whole);
  final RegExpMatch? products = _topProducts.firstMatch(whole);
  final RegExpMatch? top = retailers ?? products;
  if (top != null) {
    if (taken.ranges.length > 1) return const UnclearIntent();
    return TopIntent(
      retailers: retailers != null,
      range: one ?? copilotRange(CopilotRangeKind.thisMonth, now),
      limit: (int.tryParse(top.group(1) ?? '') ?? 5).clamp(1, 10),
    );
  }
  if (!_orderNoun.hasMatch(whole) && _progressCommand.hasMatch(whole)) {
    return OpenProgressIntent(one ?? copilotRange(CopilotRangeKind.today, now));
  }
  return null;
}
