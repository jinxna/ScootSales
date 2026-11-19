enum CopilotIntentKind {
  openRoute,
  nextStop,
  stopsLeft,
  openOrders,
  ordersThisWeek,
  visitBrief,
  lastOrder,
  whyStop,
  whatToSay,
  usualOrderDay,
  followUps,
  followUp,
  whichShop,
  sales,
  openPlanner,
  openProfile,
  help,
  refuse,
  unknown,
}

class ScoutShop {
  const ScoutShop({required this.id, required this.name});

  final String id;
  final String name;
}

class ScoutMemory {
  const ScoutMemory({this.shop, this.topic});

  final ScoutShop? shop;
  final CopilotIntentKind? topic;
}

const Set<CopilotIntentKind> kCopilotShopTopics = <CopilotIntentKind>{
  CopilotIntentKind.whyStop,
  CopilotIntentKind.whatToSay,
  CopilotIntentKind.visitBrief,
  CopilotIntentKind.lastOrder,
  CopilotIntentKind.usualOrderDay,
};

class CopilotIntent {
  const CopilotIntent(
    this.kind, {
    this.retailer = '',
    this.thisWeek = false,
    this.today = false,
    this.nextOne = false,
    this.remembered,
  });

  final CopilotIntentKind kind;

  final String retailer;

  final bool thisWeek;

  final bool today;

  final bool nextOne;

  final ScoutShop? remembered;
}

CopilotIntent resolveCopilotIntent(CopilotIntent intent, ScoutMemory memory) {
  const CopilotIntent which = CopilotIntent(CopilotIntentKind.whichShop);
  final ScoutShop? shop = memory.shop;
  final CopilotIntentKind? topic = memory.topic;
  if (intent.kind == CopilotIntentKind.followUp) {
    if (intent.nextOne) {
      if (shop == null) return which;
      return CopilotIntent(
        topic ?? CopilotIntentKind.nextStop,
        remembered: shop,
        nextOne: true,
      );
    }
    final CopilotIntentKind? shopTopic = topic == CopilotIntentKind.nextStop
        ? CopilotIntentKind.whyStop
        : topic;
    if (intent.retailer.isEmpty) {
      if (shop == null || shopTopic == null) return which;
      return CopilotIntent(shopTopic, remembered: shop);
    }
    if (shopTopic == null) return intent;
    return CopilotIntent(shopTopic, retailer: intent.retailer);
  }
  if (kCopilotShopTopics.contains(intent.kind) && intent.retailer.isEmpty) {
    if (shop == null) return which;
    return CopilotIntent(intent.kind, remembered: shop);
  }
  return intent;
}

String normaliseCopilotText(String input) => input
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

final RegExp _brief = RegExp(
  r'\b(?:visit brief(?:ing)?|brief(?:ing)?(?: me)?|taklimat|ringkasan lawatan)\s+(?:for|on|of|about|untuk)\s+(.+)$|'
  r'\bwhat should i (?:talk|speak|say|discuss|restock|pitch|offer|sell)(?: about)? (?:at|with|to|for|during)\s+(.+)$',
);
final RegExp _sayThere = RegExp(
  r'^what (?:should|do|shall|can|must) i (?:say|talk about|discuss|bring up|tell them|ask them)(?: there| here| today)?$',
);
final RegExp _lastOrder = RegExp(
  r'^(?:what did|what has)\s+(.+?)\s+(?:order|ordered|buy|bought)(?:\s+last(?:\s+time)?)?$|'
  r'\blast order\s+(?:for|from|at|of|by)\s+(.+)$|'
  r'\bpesanan terakhir\s+(?:untuk\s+|dari\s+)?(.+)$',
);
final RegExp _whyStop = RegExp(
  r'^why (?:am i|are we|do i|should i|must i)(?: have to)? (?:going|go|visiting|visit|seeing|see|stopping|stop)(?: to| at| by)? (.+)$|'
  r'^why (?:is |was )?(.+?) (?:on|in) (?:my|the|todays|this) (?:route|list|plan|week)(?: today)?$|'
  r'^why (?:visit|go to|stop at) (.+)$|'
  r'^(?:what is |whats )?the reason for (?:visiting |going to |the stop at )?(.+)$|'
  r'^why (?:this|that|the) (?:stop|shop|visit|one)$',
);
final RegExp _usualDay = RegExp(
  r'^when (?:does|do|did|will|would) (.+?) (?:usually |normally |often |always |next )?(?:order|orders|reorder|reorders|buy|buys)(?: again| next)?$|'
  r'^(?:what|which) day (?:does|do) (.+?) (?:usually |normally )?(?:order|orders|reorder|buy|buys)$|'
  r'\busual order day (?:for|of|at) (.+)$',
);
final RegExp _leadFiller = RegExp(
  r'^(?:(?:and then|and|then|so|ok|okay|dan)\s+)+',
);
final RegExp _joiningWord = RegExp(r'\b(?:and|dan)\b');
final RegExp _followLead = RegExp(
  r'^(?:what about|how about|same for|and for)\s+(.+)$',
);
final RegExp _nextOne = RegExp(
  r'^(?:the |my )?(?:next (?:one|stop|shop|visit|retailer|outlet|customer)|(?:one|stop|shop) after(?: that)?)$|^after that$',
);
final RegExp _questionStart = RegExp(
  r'^(?:what|how|why|when|where|who|which|is|are|do|does|did|can|could|show|open|give|tell|i|my)\b',
);
final RegExp _nameTail = RegExp(r'\s+(?:today|now|please|tolong)$');
const Set<String> _shopPronouns = <String>{
  'there',
  'here',
  'it',
  'them',
  'they',
  'that shop',
  'this shop',
  'the shop',
  'the same shop',
  'that store',
  'this store',
  'that one',
  'this one',
  'that stop',
  'this stop',
  'the stop',
  'that retailer',
  'this retailer',
  'that outlet',
  'this outlet',
  'that customer',
  'this customer',
};
const Set<String> _selfWords = <String>{'i', 'me', 'we'};

String _shopName(String raw) {
  final String name = raw.trim().replaceFirst(_nameTail, '').trim();
  return _shopPronouns.contains(name) ? '' : name;
}

final RegExp _injection = RegExp(
  r'\b(ignore|forget|disregard)\b.*\b(instructions?|rules?|previous|above)\b|'
  r'\b(system prompt|developer mode|jailbreak|pretend|you are now|act as)\b',
);
final RegExp _otherPeople = RegExp(
  r'\b(another|other|someone|somebody|everyone|everybody|colleagues?|teammates?|'
  r'team|his|her|their|all salesm[ae]n|all salespeople|all salespersons|all reps|'
  r'salesperson|salesm[ae]n|salespeople|supervisor|manager)\b|'
  r'\borders? (?:of|for|by|from) (?!me\b|my\b|myself\b|today\b|this\b|the\b|yesterday\b|tomorrow\b|last\b|next\b|past\b|previous\b)\w|'
  r'\b(?!my\b|todays\b|this\b|weeks\b)\w+s (?:orders|route|stops|visits)\b',
);
final RegExp _writeVerb = RegExp(
  r'\b(approve|reject|cancel|delete|remove|submit|skip|arrive|arrival|check in|'
  r'publish|edit|modify|change|update|create|add|send|post|mark|complete|finish|'
  r'start|accept|void|refund|lulus|batal|hapus|padam|hantar|langkau|kemas kini)\b',
);

final RegExp _pageVerb = RegExp(
  r'\b(?:open|show|view|display|go to|go back to|take me to|bring up|pull up|switch to|navigate to|jump to|load|launch|buka|tunjuk|tunjukkan|papar|paparkan|pergi ke)\b',
);
final RegExp _pageNegation = RegExp(
  r'\b(?:dont|do not|never|not|jangan|no need to)\b',
);
final RegExp _seekWord = RegExp(
  r'\b(?:where|somewhere|see|find|look|check|show|view|open|go to|take me|cari|lihat|tengok|mana)\b',
);
const int _describedRequestWords = 5;
const Set<String> _pageLead = <String>{
  'please',
  'tolong',
  'hey',
  'scout',
  'the',
  'my',
  'our',
};
const Set<String> _pageTail = <String>{
  'page',
  'screen',
  'tab',
  'please',
  'now',
};
const Map<CopilotIntentKind, List<String>> _pageNames =
    <CopilotIntentKind, List<String>>{
      CopilotIntentKind.openOrders: <String>[
        'orders',
        'order',
        'order history',
        'pesanan',
        'pesanan saya',
        'pesanan ku',
      ],
      CopilotIntentKind.openRoute: <String>[
        'route',
        'routes',
        'laluan',
        'this weeks route',
        'todays route',
      ],
      CopilotIntentKind.openPlanner: <String>['planner', 'perancang'],
      CopilotIntentKind.openProfile: <String>['profile', 'profil'],
    };

bool copilotAsksForPage(String input, CopilotIntentKind page) {
  final List<String>? names = _pageNames[page];
  if (names == null) return false;
  final String text = normaliseCopilotText(input);
  if (text.isEmpty || _pageNegation.hasMatch(text)) return false;
  final List<String> words = text.split(' ');
  final List<String> bare = List<String>.of(words);
  while (bare.isNotEmpty && _pageLead.contains(bare.first)) {
    bare.removeAt(0);
  }
  while (bare.isNotEmpty && _pageTail.contains(bare.last)) {
    bare.removeLast();
  }
  if (names.contains(bare.join(' '))) return true;
  final String padded = ' $text ';
  if (_pageVerb.hasMatch(text) &&
      names.any((String name) => padded.contains(' $name '))) {
    return true;
  }
  return words.length >= _describedRequestWords && _seekWord.hasMatch(text);
}

final List<(CopilotIntentKind, RegExp)> _rules = <(CopilotIntentKind, RegExp)>[
  (
    CopilotIntentKind.followUps,
    RegExp(
      r'\bfollow ?ups?\b|\bpromised? to (?:visit|come back|go back|return|see)\b|'
      r'\bwho (?:did|do|have) i promised?\b|\bvisit again\b',
    ),
  ),
  (
    CopilotIntentKind.stopsLeft,
    RegExp(
      r'\b(how many|berapa)\b.*\b(stops?|visits?|retailers?|outlets?|hentian|lawatan|kedai)\b|'
      r'\b(stops?|visits?|hentian|lawatan) (left|remaining|lagi)\b|'
      r'\bremaining (stops?|visits?)\b|\bbaki (hentian|lawatan)\b',
    ),
  ),
  (
    CopilotIntentKind.nextStop,
    RegExp(
      r'\bnext (stop|visit|retailer|outlet|customer)\b|'
      r'\bwhere (do i|should i) go\b|\b(hentian|lawatan|kedai) seterusnya\b',
    ),
  ),
  (CopilotIntentKind.sales, RegExp(r'\b(sell|sold|sales|jualan)\b')),
  (
    CopilotIntentKind.ordersThisWeek,
    RegExp(
      r'\borders?\b.*\bthis week\b|\bthis weeks orders\b|\bpesanan minggu ini\b',
    ),
  ),
  (
    CopilotIntentKind.openOrders,
    RegExp(r'\b(my )?orders\b|\border history\b|\bpesanan( saya| ku)?\b'),
  ),
  (CopilotIntentKind.openRoute, RegExp(r'\broute\b|\blaluan\b')),
  (CopilotIntentKind.openPlanner, RegExp(r'\b(planner|perancang)\b')),
  (CopilotIntentKind.openProfile, RegExp(r'\b(profile|profil)\b')),
  (
    CopilotIntentKind.help,
    RegExp(
      r'\b(help|what can you do|what can i ask|commands|bantuan|tolong)\b',
    ),
  ),
];

CopilotIntent interpretCopilotText(String input) {
  final String text = normaliseCopilotText(input);
  if (text.isEmpty) return const CopilotIntent(CopilotIntentKind.unknown);

  final RegExpMatch? lead = _leadFiller.firstMatch(text);
  final String stripped = lead == null ? text : text.substring(lead.end).trim();
  final String core = stripped.isEmpty ? text : stripped;
  final bool joined =
      lead != null &&
      stripped.isNotEmpty &&
      _joiningWord.hasMatch(lead.group(0)!);
  final String? subject =
      _followLead.firstMatch(core)?.group(1)?.trim() ?? (joined ? core : null);
  if (subject != null && _nextOne.hasMatch(subject)) {
    return const CopilotIntent(CopilotIntentKind.followUp, nextOne: true);
  }
  final CopilotIntent intent = _interpretCore(core);
  if (intent.kind != CopilotIntentKind.unknown || subject == null) {
    return intent;
  }
  final String name = _shopName(subject);
  if (name.isEmpty) return const CopilotIntent(CopilotIntentKind.followUp);
  if (name.split(' ').length > 6 || _questionStart.hasMatch(name)) {
    return intent;
  }
  return CopilotIntent(CopilotIntentKind.followUp, retailer: name);
}

CopilotIntent _interpretCore(String text) {
  final RegExpMatch? brief = _brief.firstMatch(text);
  if (brief != null) {
    final String raw = (brief.group(1) ?? brief.group(2)!).trim();
    if (raw.isNotEmpty) {
      return CopilotIntent(
        brief.group(1) != null
            ? CopilotIntentKind.visitBrief
            : CopilotIntentKind.whatToSay,
        retailer: _shopName(raw),
      );
    }
  }
  if (_sayThere.hasMatch(text)) {
    return const CopilotIntent(CopilotIntentKind.whatToSay);
  }
  if (!_injection.hasMatch(text)) {
    final RegExpMatch? last = _lastOrder.firstMatch(text);
    if (last != null) {
      final String raw = (last.group(1) ?? last.group(2) ?? last.group(3) ?? '')
          .trim();
      if (raw.isNotEmpty && !_selfWords.contains(raw)) {
        return CopilotIntent(
          CopilotIntentKind.lastOrder,
          retailer: _shopName(raw),
        );
      }
    }
    final RegExpMatch? why = _whyStop.firstMatch(text);
    if (why != null) {
      return CopilotIntent(
        CopilotIntentKind.whyStop,
        retailer: _shopName(
          why.group(1) ?? why.group(2) ?? why.group(3) ?? why.group(4) ?? '',
        ),
      );
    }
    final RegExpMatch? usual = _usualDay.firstMatch(text);
    if (usual != null) {
      final String raw =
          (usual.group(1) ?? usual.group(2) ?? usual.group(3) ?? '').trim();
      if (raw.isNotEmpty && !_selfWords.contains(raw)) {
        return CopilotIntent(
          CopilotIntentKind.usualOrderDay,
          retailer: _shopName(raw),
        );
      }
    }
  }
  if (_injection.hasMatch(text) ||
      _otherPeople.hasMatch(text) ||
      _writeVerb.hasMatch(text)) {
    return const CopilotIntent(CopilotIntentKind.refuse);
  }
  for (final (CopilotIntentKind kind, RegExp pattern) in _rules) {
    if (!pattern.hasMatch(text)) continue;
    if (_pageNames.containsKey(kind) && !copilotAsksForPage(text, kind)) {
      continue;
    }
    if (kind == CopilotIntentKind.sales) {
      return CopilotIntent(
        kind,
        today: RegExp(r'\b(today|todays|hari ini)\b').hasMatch(text),
      );
    }
    if (kind == CopilotIntentKind.openRoute) {
      return CopilotIntent(
        kind,
        thisWeek: RegExp(r'\b(weeks?|minggu)\b').hasMatch(text),
      );
    }
    return CopilotIntent(kind);
  }
  return const CopilotIntent(CopilotIntentKind.unknown);
}
