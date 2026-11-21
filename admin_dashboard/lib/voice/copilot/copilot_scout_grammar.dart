part of 'copilot_grammar.dart';

class HelpIntent extends CopilotIntent {
  const HelpIntent();
}

class RouteWhyIntent extends CopilotIntent {
  const RouteWhyIntent({this.shop, this.person, this.subject});
  final String? shop;
  final String? person;
  final String? subject;
}

class OpenPlannerIntent extends CopilotIntent {
  const OpenPlannerIntent({
    required this.salesmanUid,
    required this.personName,
    required this.weekStart,
  });
  final String salesmanUid;
  final String personName;
  final DateTime weekStart;
}

class PersonVisitsIntent extends CopilotIntent {
  const PersonVisitsIntent({this.person, this.week});
  final String? person;
  final CopilotRange? week;
}

class DueIntent extends CopilotIntent {
  const DueIntent({this.stoppedOnly = false});
  final bool stoppedOnly;
}

class PlanWeekIntent extends CopilotIntent {
  const PlanWeekIntent({this.person, this.week});
  final String? person;
  final CopilotRange? week;
}

class NoRouteIntent extends CopilotIntent {
  const NoRouteIntent({this.week});
  final CopilotRange? week;
}

class ShopsOfPersonIntent extends CopilotIntent {
  const ShopsOfPersonIntent(this.words);
  final String words;
}

class TeamIntent extends CopilotIntent {
  const TeamIntent(this.words);
  final String words;
}

class FollowUpIntent extends CopilotIntent {
  const FollowUpIntent({
    this.subject,
    this.personPronoun = false,
    this.orderFallback,
  });
  final String? subject;
  final bool personPronoun;
  final CopilotIntent? orderFallback;
}

const Set<String> _shopPronouns = <String>{
  'that shop',
  'this shop',
  'the shop',
  'that store',
  'that retailer',
  'that one',
  'there',
  'it',
  'them',
};

const Set<String> _personPronouns = <String>{
  'he',
  'she',
  'her',
  'him',
  'his',
  'they',
  'them',
};

bool isShopPronoun(String text) => _shopPronouns.contains(text.toLowerCase());
bool isPersonPronoun(String text) =>
    _personPronouns.contains(text.toLowerCase());

final RegExp _helpRequest = RegExp(
  r'^(?:(?:hey|hi|yo|scout|so|ok|okay) )*'
  r'(?:help|help me|bantuan|what (?:can|could|do) (?:you|u)(?: even| actually| really| exactly| else)? do(?: here| for me)?|what are you (?:able to do|for|good for)|what (?:can|should) i ask(?: you)?|how do i use (?:you|this|scout)|how does this work|what (?:are )?your (?:skills|abilities|features)|show me what you can do|what do you know)'
  r'(?: (?:bud|mate|bro|man|dude|scout|then))?$',
);

final RegExp _routeWhyCommand = RegExp(
  r"^why (?:is|are|was) (.+?) (?:on|in|part of|included in) (?:(.+?)(?:'s| s)|his|her|their|the|this) (?:route|routes|plan|schedule|week)(?: (?:this week|next week))?$",
);
final RegExp _personVisitsCommand = RegExp(
  r'^(?:who|which (?:shops|retailers|stores|outlets|customers)|what (?:shops|retailers|stores|outlets)) should (.+?) (?:visit|see|call on|go to|go see)(?: (.+))?$',
);
final RegExp _dueCommand = RegExp(
  r'^(?:who|what|which (?:shops?|retailers?|stores?|outlets?|customers?)) (?:is|are) (?:due|overdue)(?: .*)?$'
  r'|^(?:which|what) (?:shops?|retailers?|stores?|outlets?|customers?) (?:have |has )?(?:stopped|stop) (?:buying|ordering)(?: .*)?$',
);
final RegExp _planWeekCommand = RegExp(
  r'^(?:(?:please|tolong|can you|could you) )*(?:plan|prepare|set up|schedule|draft) (?:(?:the|a) )?(next week|this week|week)(?: (?:route|routes|plan))? (?:for|of) (.+)$',
);
final RegExp _noRouteCommand = RegExp(
  r"^(?:who|which (?:salespeople|salesmen|salesman|reps|people|team members)) (?:(?:has|have|got) no|(?:hasnt|hasn't|doesnt|doesn't|dont|don't) (?:got |have )?(?:a|any)|(?:does not|do not|has not) (?:have |got )?(?:a|any)) (?:route|routes|plan|plans)(?: (.+))?$",
);
final RegExp _sayThereCommand = RegExp(
  r'^what (?:should|do|can|shall) (?:i|he|she|they|we) (?:say|tell|talk about|ask|bring up)(?: (?:there|to them|to that shop|at that shop|at the shop))?$',
);
final RegExp _briefThatCommand = RegExp(
  r'^(?:(?:give me|show me|get|prepare) )?(?:an? |the )?(?:brief|summary|snapshot|profile) (?:for|on|of|about) (?:that shop|that store|that one|this shop|them)$',
);
final RegExp _stoppedCommand = RegExp(
  r'^(?:which|what) (?:shops?|retailers?|stores?|outlets?|customers?) (?:have |has )?(?:stopped|stop) (?:buying|ordering)(?: .*)?$',
);
final RegExp _leadFiller = RegExp(
  r'^(?:(?:and then|and|then|so|ok|okay|dan)\s+)+',
);
final RegExp _followUpCommand = RegExp(
  r'^(?:(?:and then|then|so|ok|okay|dan)\s+)*(?:and then|and|dan|what about|how about|same for|same question for) (.+)$',
);
final RegExp _orderishSubject = RegExp(
  r'\b(?:ones|only|orders?|pesanan|tempahan|approved|rejected|pending|submitted|instead)\b',
);

final RegExp _shopNoun = RegExp(
  r'\b(?:retailers?|shops?|stores?|outlets?|customers?|kedai)\b',
);
final RegExp _coverVerb = RegExp(
  r'\b(?:covers?|covered|covering|connect(?:s|ed)?|associated|assigned|handles?|handled|serves?|served|under|belongs?|belonging)\b',
);
final RegExp _teamAsk = RegExp(
  r"'s team\b|\bteam (?:of|under)\b|\breports? to\b|\breporting to\b|\bworks? (?:under|for)\b|\b(?:is|are) under\b|\bsupervises\b|\bsupervisor (?:of|for)\b|'s supervisor\b|^who is .+ supervisor$",
);
final RegExp _notTeamAsk = RegExp(
  r'\b(?:progress|activity|doing|tracking|route|routes|plan|visit|visits)\b',
);

CopilotRange? _weekIn(String text, DateTime now) {
  final List<CopilotRange> ranges = _takeRanges(text, now).ranges;
  if (ranges.length != 1) return null;
  final CopilotRangeKind kind = ranges.first.kind;
  return kind == CopilotRangeKind.thisWeek ||
          kind == CopilotRangeKind.nextWeek ||
          kind == CopilotRangeKind.lastWeek
      ? ranges.first
      : null;
}

CopilotRange? _weekFromWords(String word, DateTime now) => switch (word) {
  'next week' => copilotRange(CopilotRangeKind.nextWeek, now),
  'this week' => copilotRange(CopilotRangeKind.thisWeek, now),
  _ => null,
};

CopilotIntent? interpretScoutCommand(String text, String raw, DateTime now) {
  final String spoken = _stripTail(text);
  final String whole = spoken.replaceFirst(_leadFiller, '');
  if (_helpRequest.hasMatch(whole)) return const HelpIntent();
  if (_sayThereCommand.hasMatch(whole) || _briefThatCommand.hasMatch(whole)) {
    return const BriefRetailerIntent('', fromMemory: true);
  }

  final RegExpMatch? why = _routeWhyCommand.firstMatch(whole);
  if (why != null) {
    final String shopWords = why.group(1)!;
    final String? shop = isShopPronoun(shopWords)
        ? null
        : _cleanName(shopWords, raw, strict: true);
    if (shop == null && !isShopPronoun(shopWords)) return null;
    final String? personWords = why.group(2);
    final String? person = personWords == null || isPersonPronoun(personWords)
        ? null
        : _cleanName(personWords, raw, strict: true);
    if (personWords != null &&
        person == null &&
        !isPersonPronoun(personWords)) {
      return null;
    }
    return RouteWhyIntent(shop: shop, person: person);
  }

  final RegExpMatch? visits = _personVisitsCommand.firstMatch(whole);
  if (visits != null) {
    final String who = visits.group(1)!;
    final String? person = isPersonPronoun(who)
        ? null
        : _cleanName(who, raw, strict: true);
    if (person == null && !isPersonPronoun(who)) return null;
    final String rest = visits.group(2) ?? '';
    return PersonVisitsIntent(person: person, week: _weekIn(rest, now));
  }

  if (!_orderNoun.hasMatch(whole) && _dueCommand.hasMatch(whole)) {
    return DueIntent(stoppedOnly: _stoppedCommand.hasMatch(whole));
  }

  final RegExpMatch? plan = _planWeekCommand.firstMatch(whole);
  if (plan != null) {
    final String who = plan.group(2)!;
    final String? person = isPersonPronoun(who)
        ? null
        : _cleanName(who, raw, strict: true);
    if (person == null && !isPersonPronoun(who)) return null;
    return PlanWeekIntent(
      person: person,
      week: _weekFromWords(plan.group(1)!, now),
    );
  }

  final RegExpMatch? none = _noRouteCommand.firstMatch(whole);
  if (none != null) {
    return NoRouteIntent(week: _weekIn(none.group(1) ?? '', now));
  }

  if (!_orderNoun.hasMatch(whole)) {
    if (_shopNoun.hasMatch(whole) && _coverVerb.hasMatch(whole)) {
      return ShopsOfPersonIntent(whole);
    }
    if (_teamAsk.hasMatch(whole) && !_notTeamAsk.hasMatch(whole)) {
      return TeamIntent(whole);
    }
  }

  final RegExpMatch? follow = _followUpCommand.firstMatch(spoken);
  if (follow != null) {
    final String rest = follow.group(1)!.trim();
    if (_orderishSubject.hasMatch(rest) ||
        _takeRanges(rest, now).ranges.isNotEmpty) {
      return null;
    }
    if (isPersonPronoun(rest) && !isShopPronoun(rest)) {
      return const FollowUpIntent(personPronoun: true);
    }
    if (isShopPronoun(rest)) return const FollowUpIntent();
    final String? name = _cleanName(rest, raw, strict: true);
    if (name == null) return null;
    return FollowUpIntent(
      subject: name,
      orderFallback: interpretOrderCommand(
        'what about $rest',
        'what about $rest',
        now,
      ),
    );
  }
  return null;
}
