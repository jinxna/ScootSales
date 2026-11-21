import '../dashboard_voice_types.dart';
import 'copilot_grammar.dart';

const Set<String> _negationWords = <String>{
  "don't",
  'dont',
  'never',
  'not',
  'jangan',
};
const Set<String> _seekVerbs = <String>{
  'where',
  'somewhere',
  'see',
  'find',
  'look',
  'check',
  'show',
  'view',
  'open',
  'display',
  'go',
  'take',
  'bring',
  'pull',
  'cari',
  'lihat',
  'tengok',
  'mana',
};
const Set<String> _plannerVerbs = <String>{
  'plan',
  'make',
  'create',
  'build',
  'draft',
  'prepare',
  'set',
  'edit',
  'change',
};
const Set<String> _negationBridge = <String>{
  'want',
  'wanna',
  'to',
  'need',
  'ever',
  'even',
  'you',
  'i',
  'me',
  'please',
  'really',
  'have',
  'again',
  'automatically',
  'auto',
  'always',
  'just',
};
const Set<String> _moodWords = <String>{
  'worst',
  'terrible',
  'awful',
  'hate',
  'annoying',
  'lame',
  'pathetic',
};
const Set<String> _aboutYou = <String>{'you', 'your', 'u', 'ur'};

final RegExp _plannerWord = RegExp(
  r'\b(?:plan|plans|planner|planning|route|routes|schedule|schedules|rancang|perancang|laluan|jadual)\b',
);
final RegExp _plannerContext = RegExp(
  r"\b(?:open|show|view|see|check|bring up|pull up|go to|take me to|make|create|build|draft|prepare|set up|edit|change|plan|buka|tunjuk|buat|week|weeks|week's|weekly|monday|tuesday|wednesday|thursday|friday|saturday|sunday|minggu|him|her|his|their|them)\b",
);

bool copilotAsksForPlanner(String text) {
  final String said = text.toLowerCase().replaceAll(RegExp('[’‘]'), "'");
  final List<String> words = _words(said);
  if (_insulted(words) || _refusesNavigation(words)) return false;
  final RegExpMatch? planWord = _plannerWord.firstMatch(said);
  if (planWord == null) return false;
  final String rest =
      '${said.substring(0, planWord.start)} ${said.substring(planWord.end)}';
  if (!_plannerContext.hasMatch(rest)) return false;
  return !_moody(words) || _seekAt(words).isNotEmpty;
}

bool copilotRefusesAnyPage(String text) {
  final List<String> words = _words(
    text.toLowerCase().replaceAll(RegExp('[’‘]'), "'"),
  );
  return _insulted(words) ||
      _refusesNavigation(words) ||
      (_moody(words) && _seekAt(words).isEmpty);
}

bool _insulted(List<String> words) => words.any(
  (String word) =>
      copilotChatterWords.contains(word) && !_moodWords.contains(word),
);

bool _moody(List<String> words) => words.any(_moodWords.contains);

bool _isSeekVerb(List<String> words, int index) {
  final String word = words[index];
  final String? next = index + 1 < words.length ? words[index + 1] : null;
  return switch (word) {
    'see' => next != 'you' && next != 'ya',
    'look' => next == 'at' || next == 'for' || next == 'up',
    'go' => next == 'to' || next == 'back',
    'take' => next == 'me',
    'bring' || 'pull' => next == 'up',
    _ => _seekVerbs.contains(word),
  };
}

List<int> _seekAt(List<String> words) => <int>[
  for (int index = 0; index < words.length; index++)
    if (_isSeekVerb(words, index)) index,
];

bool _isNegation(List<String> words, int index) =>
    _negationWords.contains(words[index]) ||
    (words[index] == 'no' &&
        index + 1 < words.length &&
        words[index + 1] == 'need');

bool _refusesNavigation(List<String> words) {
  for (int index = 0; index < words.length; index++) {
    if (!_isNegation(words, index)) continue;
    for (int next = index + 1; next < words.length; next++) {
      if (_isSeekVerb(words, next) || _plannerVerbs.contains(words[next])) {
        return true;
      }
      if (!_negationBridge.contains(words[next]) && words[next] != 'need') {
        break;
      }
    }
  }
  return false;
}

String _singular(String word) {
  if (word.length > 4 && word.endsWith('ies')) {
    return '${word.substring(0, word.length - 3)}y';
  }
  if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

List<String> _words(String text) => <String>[
  for (final String word
      in text
          .toLowerCase()
          .replaceAll('_', ' ')
          .replaceAll(RegExp(r"[^a-z0-9'\s]"), ' ')
          .split(RegExp(r'\s+')))
    if (word.isNotEmpty) _singular(word),
];

Set<String> _stems(String words) => <String>{
  for (final String word in words.split(' '))
    if (word.isNotEmpty) _singular(word),
};

final Set<String> _courtesy = _stems(
  "can could would will you u i want wanna wan need to like let me help where how do why somewhere please pls just quickly also now hey scout tolong ok okay so i'd id",
);
final List<List<String>> _requestVerbs = <List<String>>[
  for (final String verb in const <String>[
    'go back to',
    'go to',
    'take me to',
    'bring up',
    'pull up',
    'switch to',
    'navigate to',
    'jump to',
    'look at',
    'look for',
    'look up',
    'open',
    'show',
    'view',
    'display',
    'list',
    'find',
    'see',
    'check',
    'get',
    'give',
    'search',
    'load',
    'launch',
    'add',
    'create',
    'edit',
    'change',
    'update',
    'remove',
    'delete',
    'manage',
    'reset',
    'review',
    'browse',
    'approve',
    'compare',
    'filter',
    'export',
    'sort',
    'refresh',
    'tell',
    'buka',
    'tunjuk',
    'tunjukkan',
    'papar',
    'paparkan',
    'cari',
    'lihat',
    'tengok',
  ])
    _stems(verb).toList(growable: false),
];
final Set<String> _verbParticles = _stems('me us up back');
final Set<String> _determiners = _stems(
  'the a an my our all every any some this these those his her their',
);
final Set<String> _modifiers = _stems(
  'new low high worst best top bottom active inactive pending waiting open recent latest oldest newest old big biggest small unapproved approved submitted rejected cancelled unverified verified missing assigned unassigned today tomorrow yesterday tonight next last this week weekly month monthly year monday tuesday wednesday thursday friday saturday sunday morning afternoon',
);
final Set<String> _containers = _stems(
  'list page screen tab directory table detail details record records history info password account profile status planner log chart',
);
final Set<String> _questionWords = _stems('who what which');
final Set<String> _clauseOpeners = _stems('who what which how where');
final Set<String> _wantWords = _stems('need want wanna wan');
final Set<String> _amountWords = _stems('much many');
final Set<String> _thereVerbs = _stems('is are');
const Set<String> _peoplePages = <String>{
  'user_directory',
  'my_team',
  'salesman_activity',
  'team_activity',
  'visit_logs',
};
final Set<String> _namePrepositions = _stems(
  'for from by at near named called',
);
final Set<String> _dashboardWords = _stems(
  "the a an and or to of in on is are was were be been am do does did have has had haven't hasn't didn't not no yet any all some every each this that these those it its they them their there here me my our us we his her him he she who what which when where how with without than more less most least many much only also still just ever never very please pls thanks now up down out about into over under per since before after order ordered approve approved approval unapproved pending waiting submitted sent send rejected cancelled delivered paid total amount value visit visited logged login log signed sign location pin coordinate gps address phone email password role status active inactive new old top worst best recent latest last next week month year today tomorrow yesterday tonight day morning monday tuesday wednesday thursday friday saturday sunday stop route plan sale buy bought buying stock product item sku price report forecast salesman salespeople salesperson staff user team member customer retailer shop store outlet assigned unassigned missing verified unverified stopped number count list page name code branch area created made joined working online offline overdue due high low",
);
final Set<String> _leadFiller = _stems(
  'please pls hey scout tolong ok okay so',
);
final Set<String> _objectBreaks = <String>{
  ..._aboutYou,
  ..._stems('when why how where if is are was were will be'),
};
const Map<String, String> _pageNouns = <String, String>{
  'all_orders': 'order customer sale sell sold',
  'user_directory':
      'user staff people person team account member salesman salesmen salespeople salesperson employee',
  'notifications': 'alert notification',
  'route_planner': 'route plan planner schedule',
  'retailer': 'shop store outlet retailer customer',
  'product': 'product item sku catalogue inventory stock',
  'salesman_activity': 'salesman salesmen salespeople salesperson tracking map',
  'visit_logs': 'visit log',
  'prediction': 'forecast prediction demand',
  'reports': 'report analytics sale sell sold',
  'my_team': 'team salesman salesmen salespeople salesperson member staff',
};

DashboardVoicePage? copilotModelPage(
  String text,
  Object? pageKey,
  Iterable<DashboardVoicePage> pages, {
  Iterable<String> knownNames = const <String>[],
}) {
  if (pageKey is! String) return null;
  final DashboardVoicePage? page = pages
      .where((DashboardVoicePage p) => p.key == pageKey)
      .firstOrNull;
  if (page == null) return null;
  final List<String> words = _words(
    text.toLowerCase().replaceAll(RegExp('[’‘]'), "'"),
  );
  if (_insulted(words) || _refusesNavigation(words)) return null;
  if (_moody(words) &&
      words.skip(_courtesyEnd(words)).any(_aboutYou.contains)) {
    return null;
  }
  final Set<String> anyNoun = <String>{
    for (final DashboardVoicePage other in pages) ..._nounsOf(other),
  };
  final Set<String> known = <String>{
    for (final String name in knownNames)
      for (final String part in _words(name))
        if (part.length >= 3) part,
  };
  final _Names names = _Names(
    free: <String>{..._names(text), ...known},
    known: _peoplePages.contains(page.key) ? known : const <String>{},
  );
  return _asksFor(words, _nounsOf(page), anyNoun, names) ? page : null;
}

class _Names {
  const _Names({required this.free, required this.known});
  final Set<String> free;
  final Set<String> known;

  _Names get freeOnly => _Names(free: free, known: const <String>{});
}

Set<String> _names(String text) {
  final List<String> raw = text
      .replaceAll(RegExp('[’‘]'), "'")
      .replaceAll(RegExp(r"[^A-Za-z0-9'\s]"), ' ')
      .split(RegExp(r'\s+'))
      .where((String word) => word.isNotEmpty)
      .toList(growable: false);
  return <String>{
    for (int index = 1; index < raw.length; index++)
      if (RegExp(r"^[A-Z][a-z']+$").hasMatch(raw[index]))
        _singular(raw[index].toLowerCase()),
  };
}

Set<String> _nounsOf(DashboardVoicePage page) => <String>{
  ..._stems(_pageNouns[page.key] ?? ''),
  for (final String word in _words(page.label))
    if (word.length > 2 &&
        !_determiners.contains(word) &&
        !_containers.contains(word))
      word,
};

int _courtesyEnd(List<String> words) {
  int start = 0;
  while (start < words.length && _courtesy.contains(words[start])) {
    start++;
  }
  return start;
}

bool _asksFor(
  List<String> words,
  Set<String> nouns,
  Set<String> anyNoun,
  _Names names,
) {
  final int start = _courtesyEnd(words);
  if (start < words.length && words[start] == 'when') {
    final List<String> rest = words.sublist(start + 1);
    final int restVerb = _afterRequestVerb(rest, _courtesyEnd(rest));
    return restVerb >= 0 &&
        _objectIsPage(
          rest,
          _skipParticles(rest, restVerb),
          nouns,
          anyNoun,
          names,
        );
  }
  if (start > 0 &&
      words[start - 1] == 'how' &&
      start < words.length &&
      _amountWords.contains(words[start])) {
    return _clauseIsAbout(words, start + 1, nouns, anyNoun, names.freeOnly);
  }
  if (start + 1 < words.length &&
      _thereVerbs.contains(words[start]) &&
      words[start + 1] == 'there') {
    return _objectIsPage(words, start + 2, nouns, anyNoun, names);
  }
  final int afterVerb = _afterRequestVerb(words, start);
  if (afterVerb >= 0) {
    return _objectIsPage(
      words,
      _skipParticles(words, afterVerb),
      nouns,
      anyNoun,
      names,
    );
  }
  if (words.take(start).any(_wantWords.contains)) {
    return _objectIsPage(words, start, nouns, anyNoun, names);
  }
  if (start < words.length && _questionWords.contains(words[start])) {
    return _clauseIsAbout(words, start + 1, nouns, anyNoun, names.freeOnly);
  }
  int bare = 0;
  while (bare < words.length && _leadFiller.contains(words[bare])) {
    bare++;
  }
  final int end = _nounPhraseEnd(words, bare, nouns);
  return end >= 0 && _restIsDashboard(words, end);
}

int _skipParticles(List<String> words, int start) {
  int object = start;
  while (object < words.length && _verbParticles.contains(words[object])) {
    object++;
  }
  return object;
}

int _afterRequestVerb(List<String> words, int start) {
  for (final List<String> verb in _requestVerbs) {
    if (start + verb.length > words.length) continue;
    bool same = true;
    for (int i = 0; i < verb.length && same; i++) {
      same = words[start + i] == verb[i];
    }
    if (same) return start + verb.length;
  }
  return -1;
}

bool _objectIsPage(
  List<String> words,
  int start,
  Set<String> nouns,
  Set<String> anyNoun,
  _Names names,
) {
  if (start < words.length && _clauseOpeners.contains(words[start])) {
    return _clauseIsAbout(words, start + 1, nouns, anyNoun, names);
  }
  for (int index = start; index < words.length; index++) {
    if (_objectBreaks.contains(words[index])) return false;
    if (anyNoun.contains(words[index])) {
      return nouns.contains(words[_headOfRun(words, index, anyNoun)]);
    }
  }
  return _namesOnly(words, start, names);
}

int _headOfRun(List<String> words, int first, Set<String> anyNoun) {
  int head = first;
  for (int index = first + 1; index < words.length; index++) {
    if (_isNoun(words[index], anyNoun)) {
      head = index;
    } else if (!_containers.contains(words[index])) {
      break;
    }
  }
  return head;
}

bool _namesOnly(List<String> words, int start, _Names names) {
  bool named = false;
  for (int index = start; index < words.length; index++) {
    final String word = words[index];
    if (names.known.contains(word)) {
      named = true;
    } else if (names.free.contains(word)) {
      continue;
    } else if (!_determiners.contains(word) && !_modifiers.contains(word)) {
      return false;
    }
  }
  return named;
}

bool _isNoun(String word, Set<String> nouns) =>
    nouns.contains(word) ||
    (word.endsWith('ed') && nouns.contains(word.substring(0, word.length - 2)));

bool _isPossessive(String word) => word.length > 1 && word.endsWith("'");

int _nounPhraseEnd(List<String> words, int start, Set<String> nouns) {
  int index = start;
  while (index < words.length) {
    final String word = words[index];
    if (_determiners.contains(word) ||
        _modifiers.contains(word) ||
        _isPossessive(word)) {
      index++;
    } else if (_containers.contains(word) &&
        index + 1 < words.length &&
        words[index + 1] == 'of') {
      index += 2;
    } else {
      break;
    }
  }
  if (index >= words.length || !nouns.contains(words[index])) return -1;
  index++;
  while (index < words.length &&
      (nouns.contains(words[index]) || _containers.contains(words[index]))) {
    index++;
  }
  return index;
}

bool _restIsDashboard(List<String> words, int start) {
  for (int index = start; index < words.length; index++) {
    if (_namePrepositions.contains(words[index])) return true;
    if (!_dashboardWords.contains(words[index])) return false;
  }
  return true;
}

bool _clauseIsAbout(
  List<String> words,
  int start,
  Set<String> nouns,
  Set<String> anyNoun,
  _Names names,
) {
  bool named = false;
  for (int index = start; index < words.length; index++) {
    final String word = words[index];
    if (_isNoun(word, anyNoun)) {
      return _isNoun(words[_headOfRun(words, index, anyNoun)], nouns);
    }
    if (names.known.contains(word)) {
      named = true;
    } else if (_aboutYou.contains(word) ||
        (!_dashboardWords.contains(word) && !names.free.contains(word))) {
      return false;
    }
  }
  return named;
}
