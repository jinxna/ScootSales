enum CopilotIntentKind {
  openRoute,
  nextStop,
  stopsLeft,
  openOrders,
  ordersThisWeek,
  visitBrief,
  lastOrder,
  sales,
  openPlanner,
  openProfile,
  help,
  refuse,
  unknown,
}

class CopilotIntent {
  const CopilotIntent(
    this.kind, {
    this.retailer = '',
    this.thisWeek = false,
    this.today = false,
  });

  final CopilotIntentKind kind;

  final String retailer;

  final bool thisWeek;

  final bool today;
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
final RegExp _lastOrder = RegExp(
  r'^(?:what did|what has)\s+(.+?)\s+(?:order|ordered|buy|bought)(?:\s+last(?:\s+time)?)?$|'
  r'\blast order\s+(?:for|from|at|of|by)\s+(.+)$|'
  r'\bpesanan terakhir\s+(?:untuk\s+|dari\s+)?(.+)$',
);
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

final List<(CopilotIntentKind, RegExp)> _rules = <(CopilotIntentKind, RegExp)>[
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

  final RegExpMatch? brief = _brief.firstMatch(text);
  if (brief != null) {
    final String name = (brief.group(1) ?? brief.group(2)!).trim();
    if (name.isNotEmpty) {
      return CopilotIntent(CopilotIntentKind.visitBrief, retailer: name);
    }
  }
  final RegExpMatch? last = _lastOrder.firstMatch(text);
  if (last != null && !_injection.hasMatch(text)) {
    final String name = (last.group(1) ?? last.group(2) ?? last.group(3) ?? '')
        .trim();
    if (name.isNotEmpty && !const <String>{'i', 'me', 'we'}.contains(name)) {
      return CopilotIntent(CopilotIntentKind.lastOrder, retailer: name);
    }
  }
  if (_injection.hasMatch(text) ||
      _otherPeople.hasMatch(text) ||
      _writeVerb.hasMatch(text)) {
    return const CopilotIntent(CopilotIntentKind.refuse);
  }
  for (final (CopilotIntentKind kind, RegExp pattern) in _rules) {
    if (!pattern.hasMatch(text)) continue;
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
