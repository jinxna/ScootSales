library;

import '../../models/ai_insight.dart';
import '../../models/retailer_priority_ranking.dart';
import '../../models/route_plan.dart';
import '../../utils/ai_data_freshness.dart';
import '../../utils/money_format.dart' show formatRm;
import '../../services/shop_panel_service.dart'
    show shopSeriesFromPatterns, ShopWeeklySeries;
import '../../utils/my_team_roster.dart';
import '../../widgets/weekly_bar_chart.dart' show WeeklyQuantity;
import 'copilot_dates.dart';
import 'copilot_directory.dart';
import 'copilot_entity_resolver.dart';
import 'copilot_rank_why.dart';
import 'order_search_session.dart';

enum ScoutTopic {
  orders,
  rankWhy,
  routeWhy,
  personVisits,
  planWeek,
  noRoute,
  due,
  brief,
  shops,
  team,
}

class ScoutSources {
  const ScoutSources({
    required this.rankings,
    required this.routePlans,
    required this.insights,
    required this.visitBriefs,
    required this.salespeople,
    required this.directory,
    required this.shopPatterns,
  });

  final Future<List<RetailerPriorityRanking>> Function() rankings;
  final Future<List<RoutePlan>> Function() routePlans;
  final Future<List<AiInsight>> Function() insights;
  final Future<List<Map<String, dynamic>>> Function() visitBriefs;
  final Future<List<EntityRef>> Function() salespeople;
  final Future<ScoutDirectory> Function() directory;
  final Future<List<Map<String, dynamic>>> Function(String retailerId)
  shopPatterns;
}

class ScoutChart {
  const ScoutChart({required this.title, required this.weeks});
  final String title;
  final List<WeeklyQuantity> weeks;
}

class ScoutSection {
  const ScoutSection({this.title, required this.lines});
  final String? title;
  final List<String> lines;
}

class ScoutButton {
  const ScoutButton({
    required this.label,
    required this.personName,
    required this.salesmanUid,
    required this.weekStart,
  });
  final String label;
  final String personName;
  final String salesmanUid;
  final DateTime weekStart;
}

class ScoutCard {
  const ScoutCard({
    this.sections = const <ScoutSection>[],
    this.details = const <String>[],
    this.buttons = const <ScoutButton>[],
  });
  final List<ScoutSection> sections;
  final List<String> details;
  final List<ScoutButton> buttons;
}

class ScoutAnswer {
  const ScoutAnswer(
    this.reply, {
    this.shop,
    this.person,
    this.charts = const <ScoutChart>[],
  });
  final CopilotReply reply;
  final EntityRef? shop;
  final EntityRef? person;
  final List<ScoutChart> charts;
}

class ScoutBriefPart {
  const ScoutBriefPart({
    this.text,
    this.dataUsed,
    this.shop,
    this.charts = const <ScoutChart>[],
  });
  final String? text;
  final String? dataUsed;
  final EntityRef? shop;
  final List<ScoutChart> charts;
}

class _ChartResult {
  const _ChartResult(this.charts, [this.note]);
  final List<ScoutChart> charts;
  final String? note;
}

class ScoutPlannerTarget {
  const ScoutPlannerTarget({
    this.person,
    this.weekStart,
    this.weekLabel = '',
    this.message,
  });
  final EntityRef? person;
  final DateTime? weekStart;
  final String weekLabel;
  final String? message;
}

class _ScoutReadError implements Exception {
  const _ScoutReadError(this.what);
  final String what;
}

const List<String> _days = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];
const List<String> _months = <String>[
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

String _dm(DateTime day) => '${day.day} ${_months[day.month - 1]}';

String scoutWeekText(DateTime monday) => 'the week of ${_dm(monday)}';

String _firstName(String name) {
  final String trimmed = name.trim();
  return trimmed.isEmpty ? trimmed : trimmed.split(RegExp(r'\s+')).first;
}

String _numberText(num value) {
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toStringAsFixed(1);
}

const String _stopMissing = 'No reason is saved with this stop.';

class ScoutEngine {
  ScoutEngine({required this.sources, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final ScoutSources sources;
  final DateTime Function() _clock;

  DateTime get _nextMonday =>
      malaysiaWeekStart(_clock()).add(const Duration(days: 7));

  DateTime _mondayFor(CopilotRange? range) =>
      range == null ? _nextMonday : malaysiaWeekStart(range.start);

  Future<T> _read<T>(String what, Future<T> Function() load) async {
    try {
      return await load();
    } catch (_) {
      throw _ScoutReadError(what);
    }
  }

  Future<ScoutAnswer> _guard(Future<ScoutAnswer> Function() body) async {
    try {
      return await body();
    } on _ScoutReadError catch (error) {
      return ScoutAnswer(
        CopilotReply('I could not read ${error.what}. Try again.'),
      );
    }
  }

  static const List<String> _statusOrder = <String>[
    'published',
    'approved',
    'draft',
  ];

  static bool _live(RoutePlan plan) {
    final String status = plan.status.toLowerCase();
    return !plan.isDemo && status != 'archived' && status != 'cancelled';
  }

  static int _statusRank(RoutePlan plan) {
    final int index = _statusOrder.indexOf(plan.status.toLowerCase());
    return index < 0 ? _statusOrder.length : index;
  }

  static RoutePlan? _preferred(Iterable<RoutePlan> plans) {
    RoutePlan? best;
    for (final RoutePlan plan in plans) {
      if (best == null || _statusRank(plan) < _statusRank(best)) best = plan;
    }
    return best;
  }

  static String _isoWeekKey(DateTime monday) {
    final DateTime thursday = DateTime.utc(
      monday.year,
      monday.month,
      monday.day,
    ).add(Duration(days: 4 - monday.weekday));
    final int ordinal = thursday
        .difference(DateTime.utc(thursday.year, 1, 1))
        .inDays;
    final int week = ordinal ~/ 7 + 1;
    return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
  }

  Future<List<RoutePlan>> _livePlans() async => (await _read(
    'the route plans',
    sources.routePlans,
  )).where(_live).toList(growable: false);

  Future<List<EntityRef>> _people() =>
      _read('the salespeople', sources.salespeople);

  Future<_ChartResult> _chartsFor(
    EntityRef shop,
    Iterable<({String id, String name})> products,
  ) async {
    final List<({String id, String name})> wanted = products.toList(
      growable: false,
    );
    if (wanted.isEmpty) return const _ChartResult(<ScoutChart>[]);
    final List<ShopWeeklySeries> series;
    try {
      series = shopSeriesFromPatterns(
        await _read('the weekly orders', () => sources.shopPatterns(shop.id)),
      );
    } on _ScoutReadError {
      return _ChartResult(
        const <ScoutChart>[],
        'I could not read the weekly orders for ${shop.name}, so no chart is shown.',
      );
    }
    final List<ScoutChart> charts = <ScoutChart>[];
    final Set<String> seen = <String>{};
    for (final ({String id, String name}) product in wanted) {
      for (final ShopWeeklySeries one in series) {
        final bool same = product.id.isNotEmpty
            ? one.productId == product.id
            : one.productName.toLowerCase() == product.name.toLowerCase();
        if (!same || !seen.add(one.productId) || one.weeks.isEmpty) continue;
        charts.add(
          ScoutChart(
            title: '${one.productName}, cartons per week, ${shop.name}',
            weeks: one.weeks,
          ),
        );
      }
      if (charts.length >= 3) break;
    }
    return _ChartResult(charts);
  }

  static ScoutAnswer _say(String text, {String? dataUsed}) =>
      ScoutAnswer(CopilotReply(text, dataUsed: dataUsed));

  static bool _isPerson(EntityRef person, String uid, String code) {
    final Set<String> keys = <String>{
      if (uid.trim().isNotEmpty) uid.trim().toLowerCase(),
      if (code.trim().isNotEmpty) code.trim().toLowerCase(),
    };
    if (keys.isEmpty) return false;
    return keys.contains(person.id.toLowerCase()) ||
        keys.contains(person.code.toLowerCase()) ||
        person.orderKeys.any(keys.contains);
  }

  List<EntityRef> _peoplePool(
    List<EntityRef> users,
    List<RoutePlan> plans,
    List<RetailerPriorityRanking> rankings,
  ) {
    final List<EntityRef> pool = List<EntityRef>.of(users);
    void add(String uid, String code, String name) {
      if (uid.isEmpty && code.isEmpty) return;
      if (pool.any((EntityRef p) => _isPerson(p, uid, code))) return;
      pool.add(
        EntityRef(
          kind: EntityKind.salesperson,
          id: uid.isEmpty ? code : uid,
          name: name.isEmpty ? code : name,
          code: code,
          orderKeys: <String>{
            if (uid.isNotEmpty) uid.toLowerCase(),
            if (code.isNotEmpty) code.toLowerCase(),
          },
        ),
      );
    }

    for (final RoutePlan plan in plans) {
      if (plan.isDemo) continue;
      add(plan.salesmanUid, plan.salesmanCode, plan.salesmanName);
    }
    for (final RetailerPriorityRanking ranking in rankings) {
      if (ranking.isDemo) continue;
      add(ranking.salesmanUid, ranking.salesmanCode, '');
    }
    return pool;
  }

  EntityRef _personFor(
    List<EntityRef> pool,
    String uid,
    String code,
    String fallbackName,
  ) {
    for (final EntityRef p in pool) {
      if (_isPerson(p, uid, code)) return p;
    }
    return EntityRef(
      kind: EntityKind.salesperson,
      id: uid.isEmpty ? code : uid,
      name: fallbackName.isEmpty ? code : fallbackName,
      code: code,
    );
  }

  List<EntityRef> _shopPool(
    List<RetailerPriorityRanking> rankings,
    List<RoutePlan> plans,
    List<Map<String, dynamic>> briefs,
    List<AiInsight> insights,
  ) {
    final Map<String, EntityRef> pool = <String, EntityRef>{};
    void add(String id, String name) {
      final String key = id.trim();
      if (key.isEmpty || name.trim().isEmpty) return;
      pool.putIfAbsent(
        key,
        () => EntityRef(
          kind: EntityKind.retailer,
          id: key,
          name: name.trim(),
          orderKeys: <String>{key.toLowerCase()},
        ),
      );
    }

    for (final RetailerPriorityRanking r in rankings) {
      if (r.isDemo) continue;
      for (final RankedRetailerOpportunity row in r.ranking) {
        add(row.retailerId, row.retailerName);
      }
    }
    for (final RoutePlan plan in plans) {
      if (plan.isDemo) continue;
      for (final RouteDay day in plan.days) {
        for (final RouteStop stop in day.stops) {
          add(stop.retailerId, stop.retailerName);
        }
      }
    }
    for (final Map<String, dynamic> b in briefs) {
      add('${b['retailerId'] ?? ''}', '${b['retailerName'] ?? ''}');
    }
    for (final AiInsight i in insights) {
      add(i.retailerId, i.retailerName);
    }
    return pool.values.toList(growable: false);
  }

  static ScoutAnswer? _pickProblem(Resolution r, String spoken, String kind) {
    switch (r) {
      case None():
        return _say(
          '"$spoken" is not a $kind I can find in the records your role can see.',
        );
      case Many(:final List<EntityRef> entities):
        return _say(
          'Several ${kind}s match "$spoken": '
          '${entities.map((EntityRef e) => e.name).join(', ')}. Say the full name.',
        );
      case One():
        return null;
    }
  }

  static String _who(EntityRef person) =>
      person.code.isEmpty ? person.name : '${person.name} (${person.code})';

  static String _clockText(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';

  static ScoutAnswer? _personProblem(
    Resolution r,
    List<String> words,
    List<EntityRef> pool,
    String example,
  ) {
    switch (r) {
      case One():
        return null;
      case Many(:final List<EntityRef> entities):
        return _say(
          'Several people match "${words.join(' ')}": '
          '${entities.map(_who).join(', ')}. Say the full name.',
        );
      case None():
        if (words.isEmpty) return _say(example);
        final List<String> names = pool.map(_who).take(12).toList();
        final int more = pool.length - names.length;
        return _say(
          'No one called "${words.join(' ')}" among the people your role '
          'can see.'
          '${names.isEmpty ? '' : ' They are: ${names.join(', ')}'
                    '${more > 0 ? ', and $more more' : ''}.'}',
        );
    }
  }

  Future<ScoutAnswer> shopsOf(String said, {EntityRef? memoryPerson}) {
    return _guard(() async {
      final ScoutDirectory directory = await _read(
        'the shops and people',
        sources.directory,
      );
      final List<String> words = nameWords(said);
      final Resolution r = words.isEmpty && memoryPerson != null
          ? One(memoryPerson)
          : spotEntity(words, directory.people);
      final ScoutAnswer? problem = _personProblem(
        r,
        words,
        directory.people,
        "Whose shops? Say a salesperson's name, for example "
        '"which shops does Aisyah cover".',
      );
      if (problem != null) return problem;
      final EntityRef person = (r as One).entity;
      if (!directory.shopsRead) {
        return ScoutAnswer(
          CopilotReply(
            'I could not read the shops, so I cannot list the shops of '
            '${_who(person)}. Try again, or open Retailers.',
          ),
          person: person,
        );
      }
      final List<ScoutShop> shops = directory.shopsOf(person);
      final String used =
          'retailers · assigned to '
          '${_who(person)}'
          ' · read ${_clockText(directory.readAt)}';
      if (shops.isEmpty) {
        return ScoutAnswer(
          CopilotReply(
            'No shops are assigned to ${_who(person)}. Assign them on '
            'Retailers with "Assign to…".',
            dataUsed: used,
          ),
          person: person,
        );
      }
      final int active = shops.where((ScoutShop s) => !s.hidden).length;
      return ScoutAnswer(
        CopilotReply(
          <String>[
            '${_who(person)} covers ${shops.length} '
                '${shops.length == 1 ? 'shop' : 'shops'} ($active active).',
            for (int i = 0; i < shops.length; i++)
              '${i + 1}. ${shops[i].name} · '
                  '${shops[i].hidden ? 'hidden' : 'active'}',
          ].join('\n'),
          dataUsed: used,
        ),
        person: person,
      );
    });
  }

  Future<ScoutAnswer> teamOf(String said, {EntityRef? memoryPerson}) {
    return _guard(() async {
      final ScoutDirectory directory = await _read(
        'the team records',
        sources.directory,
      );
      final List<String> words = nameWords(said);
      final List<EntityRef> pool = <EntityRef>[
        ...directory.supervisors,
        ...directory.people,
      ];
      final Resolution r = words.isEmpty && memoryPerson != null
          ? One(memoryPerson)
          : spotEntity(words, pool);
      final ScoutAnswer? problem = _personProblem(
        r,
        words,
        pool,
        "Whose team? Say a supervisor's name, for example "
        '"who reports to Aisyah".',
      );
      if (problem != null) return problem;
      final EntityRef person = (r as One).entity;
      final String used =
          'users · supervisor rosters · read ${_clockText(directory.readAt)}';
      final Set<String> keys = personKeys(person);
      final ScoutTeam? led = directory.teams
          .where((ScoutTeam t) => personKeys(t.supervisor).any(keys.contains))
          .firstOrNull;
      if (led != null) {
        final List<TeamMember> found = <TeamMember>[
          for (final TeamMember m in led.members)
            if (m.profileFound) m,
        ];
        final List<String> missing = <String>[
          for (final TeamMember m in led.members)
            if (!m.profileFound) m.code,
        ];
        return ScoutAnswer(
          CopilotReply(
            <String>[
              '${_who(led.supervisor)} has ${found.length} '
                  '${found.length == 1 ? 'salesperson' : 'salespeople'}.',
              for (int i = 0; i < found.length; i++)
                '${i + 1}. ${found[i].name.isEmpty ? found[i].code : found[i].name}'
                    ' · ${found[i].employeeCode.isEmpty ? found[i].code : found[i].employeeCode}'
                    ' · ${found[i].status.name}',
              if (missing.isNotEmpty)
                '${missing.length} roster '
                    '${missing.length == 1 ? 'code matches' : 'codes match'} '
                    'no profile your role can see: ${missing.join(', ')}.',
            ].join('\n'),
            dataUsed: used,
          ),
        );
      }
      final List<ScoutTeam> teams = directory.teamsWith(person);
      return ScoutAnswer(
        CopilotReply(
          teams.isEmpty
              ? "${_who(person)} is on no supervisor's team that your role can see."
              : '${_who(person)} reports to '
                    '${teams.map((ScoutTeam t) => _who(t.supervisor)).join(' and ')}.',
          dataUsed: used,
        ),
        person: person,
      );
    });
  }

  Future<ScoutAnswer> rankWhy(String? spoken, EntityRef? memoryShop) {
    return _guard(() async {
      final String? name = spoken ?? memoryShop?.name;
      if (name == null) return _needShop();
      final List<RetailerPriorityRanking> rankings = await _read(
        'the weekly ranking',
        sources.rankings,
      );
      final RankWhyResult result = explainRetailerRank(
        name,
        rankings,
        retailerId: spoken == null ? memoryShop?.id : null,
      );
      EntityRef? person;
      CopilotReply reply = result.reply;
      final RetailerPriorityRanking? ranking = result.ranking;
      final EntityRef? shop = result.shop;
      if (ranking != null) {
        final List<EntityRef> users = await _people();
        person = _personFor(
          users,
          ranking.salesmanUid,
          ranking.salesmanCode,
          '',
        );
        final RankedRetailerOpportunity? row = shop == null
            ? null
            : ranking.ranking
                  .where(
                    (RankedRetailerOpportunity r) => r.retailerId == shop.id,
                  )
                  .firstOrNull;
        if (shop != null && row != null && !row.chosen) {
          final String note = await _routeNote(shop, person, ranking);
          if (note.isNotEmpty) {
            reply = CopilotReply(
              '${reply.text}\n$note',
              card: reply.card,
              dataUsed: reply.dataUsed,
            );
          }
        }
      }
      return ScoutAnswer(reply, shop: shop, person: person);
    });
  }

  Future<String> _routeNote(
    EntityRef shop,
    EntityRef person,
    RetailerPriorityRanking ranking,
  ) async {
    final List<RoutePlan> plans;
    try {
      plans = await _livePlans();
    } on _ScoutReadError {
      return 'I could not read the route plans, so I do not say whether '
          '${shop.name} is on the route.';
    }
    final RoutePlan? plan = _preferred(
      plans.where(
        (RoutePlan p) =>
            _isPerson(person, p.salesmanUid, p.salesmanCode) &&
            _isoWeekKey(malaysiaWeekStart(p.weekStart)) == ranking.weekKey,
      ),
    );
    if (plan == null) return '';
    final bool on = plan.days.any(
      (RouteDay d) => d.stops.any((RouteStop s) => s.retailerId == shop.id),
    );
    return '${shop.name} is ${on ? 'on' : 'not on'} the route plan for '
        '${scoutWeekText(malaysiaWeekStart(plan.weekStart))} '
        '(plan status: ${plan.status}).';
  }

  static ScoutAnswer _needShop() => _say(
    'Which shop do you mean? Ask about one first, for example '
    '"why is a shop ranked first", then follow up.',
  );

  static ScoutAnswer _needPerson() => _say(
    'Which salesperson do you mean? Say the name, for example '
    '"who should a salesperson visit next week".',
  );

  Future<ScoutAnswer> routeWhy({
    String? shop,
    String? person,
    String? either,
    EntityRef? memoryShop,
    EntityRef? memoryPerson,
  }) {
    return _guard(() async {
      final List<RoutePlan> plans = await _livePlans();
      final List<RetailerPriorityRanking> rankings = await _read(
        'the weekly ranking',
        sources.rankings,
      );
      final List<Map<String, dynamic>> briefs = await _read(
        'the visit briefs',
        sources.visitBriefs,
      );
      final List<EntityRef> people = _peoplePool(
        await _people(),
        plans,
        rankings,
      );
      final List<EntityRef> shops = _shopPool(
        rankings,
        plans,
        briefs,
        const <AiInsight>[],
      );

      EntityRef? shopRef = memoryShop;
      EntityRef? personRef = memoryPerson;
      if (either != null) {
        final Resolution asShop = resolveEntity(either, shops);
        if (asShop is One) {
          shopRef = asShop.entity;
        } else {
          final Resolution asPerson = resolveEntity(either, people);
          if (asPerson is One) {
            personRef = asPerson.entity;
          } else {
            return _pickProblem(asShop, either, 'shop')!;
          }
        }
      }
      if (shop != null) {
        final Resolution r = resolveEntity(shop, shops);
        final ScoutAnswer? problem = _pickProblem(r, shop, 'shop');
        if (problem != null) return problem;
        shopRef = (r as One).entity;
      }
      if (person != null) {
        final Resolution r = resolveEntity(person, people);
        final ScoutAnswer? problem = _pickProblem(r, person, 'salesperson');
        if (problem != null) return problem;
        personRef = (r as One).entity;
      }
      if (shopRef == null) return _needShop();
      final EntityRef theShop = shopRef;

      List<RoutePlan> holding(EntityRef? who) =>
          <RoutePlan>[
            for (final RoutePlan p in plans)
              if ((who == null ||
                      _isPerson(who, p.salesmanUid, p.salesmanCode)) &&
                  p.days.any(
                    (RouteDay d) => d.stops.any(
                      (RouteStop s) => s.retailerId == theShop.id,
                    ),
                  ))
                p,
          ]..sort((RoutePlan a, RoutePlan b) {
            final int byWeek = b.weekStart.compareTo(a.weekStart);
            return byWeek != 0 ? byWeek : _statusRank(a) - _statusRank(b);
          });

      if (personRef == null) {
        final List<RoutePlan> any = holding(null);
        final Set<String> owners = <String>{
          for (final RoutePlan p in any) '${p.salesmanUid}|${p.salesmanCode}',
        };
        if (owners.length == 1) {
          personRef = _personFor(
            people,
            any.first.salesmanUid,
            any.first.salesmanCode,
            any.first.salesmanName,
          );
        } else if (owners.isEmpty) {
          return _say(
            '${theShop.name} is not on any route plan your role can see.',
            dataUsed: 'route_plans',
          );
        } else {
          return _needPerson();
        }
      }
      final EntityRef who = personRef;
      final List<RoutePlan> mine = holding(who);
      if (mine.isEmpty) {
        return ScoutAnswer(
          CopilotReply(
            '${theShop.name} is not on ${who.name}\'s route in any plan I can read.',
            dataUsed: 'route_plans',
          ),
          shop: theShop,
          person: who,
        );
      }
      final DateTime thisMonday = malaysiaWeekStart(_clock());
      final DateTime next = _nextMonday;
      RoutePlan chosen = _preferred(
        mine.where(
          (RoutePlan p) =>
              malaysiaWeekStart(p.weekStart) ==
              malaysiaWeekStart(mine.first.weekStart),
        ),
      )!;
      for (final DateTime wanted in <DateTime>[next, thisMonday]) {
        final RoutePlan? hit = _preferred(
          mine.where((RoutePlan p) => malaysiaWeekStart(p.weekStart) == wanted),
        );
        if (hit != null) {
          chosen = hit;
          break;
        }
      }
      RouteDay? day;
      RouteStop? stop;
      for (final RouteDay d in chosen.days) {
        for (final RouteStop s in d.stops) {
          if (s.retailerId == theShop.id) {
            day = d;
            stop = s;
          }
        }
      }
      final DateTime monday = malaysiaWeekStart(chosen.weekStart);
      final DateTime dayKl = malaysiaDay(day!.date);
      final String dayName = _days[dayKl.weekday - 1];
      final String reason = stop!.reason.trim().isEmpty
          ? _stopMissing
          : 'The reason saved with the stop: ${stop.reason.trim()}';
      final RetailerPriorityRanking? ranking =
          RetailerPriorityRanking.newestActive(
            rankings,
            salesmanUid: who.id,
            salesmanCode: who.code,
          );
      RankedRetailerOpportunity? ranked;
      if (ranking != null) {
        ranked = ranking.ranking
            .where((RankedRetailerOpportunity r) => r.retailerId == theShop.id)
            .firstOrNull;
      }
      final String rank = ranked == null
          ? ''
          : '\nIn the weekly ranking (week ${ranking!.weekKey}) it is '
                '#${ranked.rank} of ${ranking.ranking.length}.';
      final String used =
          'route_plans · document ${chosen.id} · week of ${_dm(monday)}'
          '${ranked == null ? '' : '; retailer_priority_rankings · document ${ranking!.rankingId} · week ${ranking.weekKey}'}';
      List<AiInsight>? alerts;
      try {
        alerts = await _read('the weekly alerts', sources.insights);
      } on _ScoutReadError {
        alerts = null;
      }
      final String reasonLower = stop.reason.toLowerCase();
      final _ChartResult chart = alerts == null
          ? const _ChartResult(
              <ScoutChart>[],
              'I could not read the weekly alerts, so no chart is shown.',
            )
          : await _chartsFor(theShop, <({String id, String name})>[
              for (final AiInsight i in alerts)
                if (!i.isDemo &&
                    i.isActive &&
                    i.type == 'stopped_product' &&
                    i.retailerId == theShop.id &&
                    i.productName.trim().isNotEmpty &&
                    reasonLower.contains(i.productName.trim().toLowerCase()))
                  (id: i.productId, name: i.productName.trim()),
            ]);
      return ScoutAnswer(
        CopilotReply(
          '${theShop.name} is on ${who.name}\'s route for the week of '
          '${_dm(monday)}: $dayName ${_dm(dayKl)}, stop ${stop.sequence} '
          '(plan status: ${chosen.status}).\n$reason$rank'
          '${chart.note == null ? '' : '\n${chart.note}'}',
          dataUsed: used,
        ),
        shop: theShop,
        person: who,
        charts: chart.charts,
      );
    });
  }

  Future<ScoutAnswer> personVisits({
    String? person,
    EntityRef? memoryPerson,
    CopilotRange? week,
  }) {
    return _guard(() async {
      final List<RetailerPriorityRanking> rankings = await _read(
        'the weekly ranking',
        sources.rankings,
      );
      final List<EntityRef> people = _peoplePool(
        await _people(),
        const <RoutePlan>[],
        rankings,
      );
      EntityRef? who = memoryPerson;
      if (person != null) {
        final Resolution r = resolveEntity(person, people);
        final ScoutAnswer? problem = _pickProblem(r, person, 'salesperson');
        if (problem != null) return problem;
        who = (r as One).entity;
      }
      if (who == null) return _needPerson();
      final RetailerPriorityRanking? ranking =
          RetailerPriorityRanking.newestActive(
            rankings,
            salesmanUid: who.id,
            salesmanCode: who.code,
          );
      if (ranking == null) {
        return ScoutAnswer(
          CopilotReply(
            'No weekly ranking is published for ${who.name} yet, so I cannot '
            'say which shops to visit.',
            dataUsed: 'retailer_priority_rankings',
          ),
          person: who,
        );
      }
      final List<RankedRetailerOpportunity> sorted =
          List<RankedRetailerOpportunity>.of(ranking.ranking)
            ..sort((a, b) => a.rank.compareTo(b.rank));
      final List<RankedRetailerOpportunity> chosen = sorted
          .where((RankedRetailerOpportunity r) => r.chosen)
          .toList(growable: false);
      final List<RankedRetailerOpportunity> shown =
          (chosen.isEmpty ? sorted : chosen)
              .take(chosen.isEmpty ? 5 : 8)
              .toList(growable: false);
      final DateTime monday = _mondayFor(week);
      final String firstName = _firstName(who.name);
      final List<String> lines = <String>[
        for (final RankedRetailerOpportunity row in shown)
          '${row.rank}. ${row.retailerName}'
              '${row.isExploration ? ' (trial pick)' : ''} · expected order '
              '${formatRm(row.expectedOrderValueRm)} · '
              '${row.daysSinceLastVisit == null ? 'no visit on record' : '${row.daysSinceLastVisit!.round()} days since the last visit'}',
      ];
      return ScoutAnswer(
        CopilotReply(
          'The weekly ranking (week ${ranking.weekKey}) puts these shops first '
          'for ${who.name}.',
          card: ScoutCard(
            sections: <ScoutSection>[ScoutSection(lines: lines)],
            buttons: <ScoutButton>[
              ScoutButton(
                label: 'Open the planner for $firstName',
                personName: who.name,
                salesmanUid: who.id,
                weekStart: DateTime(monday.year, monday.month, monday.day),
              ),
            ],
          ),
          dataUsed:
              'retailer_priority_rankings · document ${ranking.rankingId} · week ${ranking.weekKey}',
        ),
        person: who,
      );
    });
  }

  Future<ScoutAnswer> due({bool stoppedOnly = false}) {
    return _guard(() async {
      final List<AiInsight> all = await _read(
        'the weekly alerts',
        sources.insights,
      );
      final List<RoutePlan> plans = await _livePlans();
      final List<EntityRef> people = _peoplePool(
        await _people(),
        plans,
        const <RetailerPriorityRanking>[],
      );
      DateTime? newest;
      for (final AiInsight i in all) {
        if (i.isDemo || i.lastObservedWeekStart == null) continue;
        final DateTime week = malaysiaWeekStart(i.lastObservedWeekStart!);
        if (newest == null || week.isAfter(newest)) newest = week;
      }
      if (newest == null) {
        return _say(
          'No weekly alert is stored yet, so nobody is listed as due.',
          dataUsed: 'ai_insights',
        );
      }
      final DateTime jobWeek = newest;
      final Set<String> wantedTypes = stoppedOnly
          ? <String>{'stopped_product'}
          : <String>{'overdue_reorder', 'stopped_product'};
      final List<AiInsight> open = <AiInsight>[
        for (final AiInsight i in all)
          if (!i.isDemo &&
              i.isActive &&
              wantedTypes.contains(i.type) &&
              i.lastObservedWeekStart != null &&
              malaysiaWeekStart(i.lastObservedWeekStart!) == jobWeek)
            i,
      ];
      final String weekText = 'week of ${_dm(jobWeek)}';
      if (open.isEmpty) {
        return _say(
          stoppedOnly
              ? 'No shop has stopped buying: no open stopped-buying alert in '
                    'the newest weekly run ($weekText).'
              : 'Nobody is due: no open overdue or stopped-buying alert in the '
                    'newest weekly run ($weekText).',
          dataUsed: 'ai_insights · $weekText',
        );
      }
      final DateTime next = _nextMonday;
      String shopKey(AiInsight i) =>
          i.retailerId.trim().isEmpty ? i.retailerName : i.retailerId;
      final Map<String, Map<String, List<AiInsight>>> byPerson =
          <String, Map<String, List<AiInsight>>>{};
      for (final AiInsight i in open) {
        final EntityRef who = _personFor(
          people,
          i.salesmanUid,
          i.salesmanCode,
          '',
        );
        byPerson
            .putIfAbsent(
              who.name.isEmpty ? 'Unassigned' : who.name,
              () => <String, List<AiInsight>>{},
            )
            .putIfAbsent(shopKey(i), () => <AiInsight>[])
            .add(i);
      }
      String route(AiInsight i) {
        final RoutePlan? plan = _preferred(
          plans.where(
            (RoutePlan p) =>
                malaysiaWeekStart(p.weekStart) == next &&
                ((i.salesmanUid.isNotEmpty && p.salesmanUid == i.salesmanUid) ||
                    (i.salesmanCode.isNotEmpty &&
                        p.salesmanCode == i.salesmanCode)),
          ),
        );
        if (plan == null) return 'no route plan for next week';
        final bool on = plan.days.any(
          (RouteDay d) =>
              d.stops.any((RouteStop s) => s.retailerId == i.retailerId),
        );
        return on ? "on next week's route" : "not on next week's route";
      }

      String risk(AiInsight i) =>
          i.valueAtRiskRm > 0 ? ' (${formatRm(i.valueAtRiskRm)} at risk)' : '';
      String reason(AiInsight i) => i.type == 'stopped_product'
          ? 'stopped buying ${i.productName}${risk(i)}'
          : 'reorder overdue${risk(i)}';

      final List<String> names = byPerson.keys.toList()..sort();
      final List<ScoutSection> sections = <ScoutSection>[
        for (final String name in names)
          ScoutSection(
            title: '$name (${byPerson[name]!.length})',
            lines: <String>[
              for (final List<AiInsight> shopRows in byPerson[name]!.values)
                '${shopRows.first.retailerName} · '
                    '${<String>{for (final AiInsight i in shopRows) reason(i)}.join(', ')}'
                    ' · ${route(shopRows.first)}',
            ],
          ),
      ];
      final Set<String> distinct = <String>{
        for (final AiInsight i in open) shopKey(i),
      };
      final int count = distinct.length;
      final String headline = stoppedOnly
          ? '$count ${count == 1 ? 'shop has' : 'shops have'} stopped buying in '
                'the newest weekly run ($weekText).'
          : '$count ${count == 1 ? 'shop is' : 'shops are'} due or '
                '${count == 1 ? 'has' : 'have'} stopped buying in the newest '
                'weekly run ($weekText).';

      EntityRef? only;
      _ChartResult chart = const _ChartResult(<ScoutChart>[]);
      if (count == 1) {
        final AiInsight first = open.first;
        only = EntityRef(
          kind: EntityKind.retailer,
          id: first.retailerId,
          name: first.retailerName,
          orderKeys: <String>{first.retailerId.toLowerCase()},
        );
        if (first.retailerId.trim().isNotEmpty) {
          chart = await _chartsFor(only, <({String id, String name})>[
            for (final AiInsight i in open)
              if (i.type == 'stopped_product')
                (id: i.productId, name: i.productName.trim()),
          ]);
        }
      }
      return ScoutAnswer(
        CopilotReply(
          '$headline${chart.note == null ? '' : '\n${chart.note}'}',
          card: ScoutCard(sections: sections),
          dataUsed: 'ai_insights · $weekText',
        ),
        shop: only,
        charts: chart.charts,
      );
    });
  }

  Future<ScoutBriefPart> brief(String? spoken, EntityRef? memoryShop) async {
    final List<Map<String, dynamic>> briefs;
    final List<RetailerPriorityRanking> rankings;
    try {
      briefs = await _read('the visit briefs', sources.visitBriefs);
      rankings = await _read('the weekly ranking', sources.rankings);
    } on _ScoutReadError catch (error) {
      return ScoutBriefPart(text: 'I could not read ${error.what}. Try again.');
    }
    final List<EntityRef> shops = _shopPool(
      rankings,
      const <RoutePlan>[],
      briefs,
      const <AiInsight>[],
    );
    EntityRef? shop = memoryShop;
    if (spoken != null) {
      final Resolution r = resolveEntity(spoken, shops);
      if (r is! One) return const ScoutBriefPart();
      shop = r.entity;
    }
    if (shop == null) return const ScoutBriefPart();
    final EntityRef theShop = shop;
    final List<Map<String, dynamic>> mine =
        briefs
            .where(
              (Map<String, dynamic> b) =>
                  '${b['retailerId'] ?? ''}' == theShop.id &&
                  b['isDemo'] != true &&
                  b['isActive'] != false,
            )
            .toList()
          ..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
            final DateTime? da = aiDataTimestamp(a);
            final DateTime? db = aiDataTimestamp(b);
            if (da == null && db == null) return 0;
            if (da == null) return 1;
            if (db == null) return -1;
            return db.compareTo(da);
          });
    if (mine.isEmpty) {
      return ScoutBriefPart(
        text:
            'Visit brief · ${theShop.name}\nNo visit brief is stored for this shop yet.',
        dataUsed: 'visit_briefs',
        shop: theShop,
      );
    }
    final Map<String, dynamic> doc = mine.first;
    final DateTime? written = aiDataTimestamp(doc);
    final List<String> lines = <String>[
      'Visit brief · ${theShop.name}'
          '${written == null ? '' : ' · written ${_dm(malaysiaDay(written))}'}',
    ];
    final Object? focus = doc['focusItems'];
    int count = 0;
    ({String id, String name})? focusProduct;
    if (focus is List) {
      for (final Object? raw in focus) {
        if (raw is! Map || count >= 3) continue;
        final String product = '${raw['productName'] ?? ''}'.trim();
        final String signal = '${raw['signal'] ?? raw['title'] ?? ''}'.trim();
        final String action = '${raw['action'] ?? ''}'.trim();
        if (signal.isEmpty && action.isEmpty) continue;
        count++;
        final String sentence =
            signal.isEmpty || RegExp(r'[.!?]$').hasMatch(signal)
            ? signal
            : '$signal.';
        lines.add(
          '• ${product.isEmpty ? '' : '$product: '}$sentence'
          '${action.isEmpty ? '' : '${sentence.isEmpty ? '' : ' '}Next step: $action'}',
        );
        if (focusProduct == null) {
          final String productId = '${raw['productId'] ?? ''}'.trim();
          if (productId.isNotEmpty || product.isNotEmpty) {
            focusProduct = (id: productId, name: product);
          }
        }
      }
    }
    final Object? restock = doc['replenishment'];
    if (restock is List) {
      for (final Object? raw in restock) {
        if (raw is! Map || raw['suggestedQty'] is! num) continue;
        final String product = '${raw['productName'] ?? raw['productId'] ?? ''}'
            .trim();
        final String why = '${raw['rationale'] ?? ''}'.trim();
        lines.add(
          '• Suggested reorder: ${_numberText(raw['suggestedQty'] as num)}'
          '${product.isEmpty ? '' : ' of $product'}'
          '${why.isEmpty ? '' : ' ($why)'}',
        );
        break;
      }
    }
    if (count == 0 && lines.length == 1) {
      final String headline = '${doc['emptyStateHeadline'] ?? ''}'.trim();
      lines.add(
        headline.isEmpty ? 'The brief lists nothing to raise.' : headline,
      );
    }
    final ({String id, String name})? picked = focusProduct;
    final _ChartResult chart = picked == null
        ? const _ChartResult(<ScoutChart>[])
        : await _chartsFor(theShop, <({String id, String name})>[picked]);
    final String note = chart.note ?? '';
    if (note.isNotEmpty) lines.add(note);
    return ScoutBriefPart(
      charts: chart.charts,
      text: lines.join('\n'),
      dataUsed:
          'visit_briefs · document ${doc['docId'] ?? doc['briefId'] ?? ''}'
          '${written == null ? '' : ' · written ${_dm(malaysiaDay(written))}'}',
      shop: theShop,
    );
  }

  Future<ScoutAnswer> noRoute(CopilotRange? week) {
    return _guard(() async {
      final List<RoutePlan> plans = await _livePlans();
      final DateTime monday = _mondayFor(week);
      final List<EntityRef> people = _peoplePool(
        await _people(),
        plans,
        const <RetailerPriorityRanking>[],
      );
      if (people.isEmpty) {
        return _say('There are no salespeople in your scope.');
      }
      const List<String> order = <String>['published', 'approved', 'draft'];
      final Map<String, List<String>> byStatus = <String, List<String>>{};
      for (final EntityRef p in people) {
        String? best;
        for (final RoutePlan plan in plans) {
          if (malaysiaWeekStart(plan.weekStart) != monday) continue;
          if (!_isPerson(p, plan.salesmanUid, plan.salesmanCode)) continue;
          final String status = plan.status.toLowerCase();
          final int rank = order.indexOf(status);
          final int current = best == null ? 99 : order.indexOf(best);
          if (best == null ||
              (rank >= 0 ? rank : 98) < (current >= 0 ? current : 98)) {
            best = status;
          }
        }
        byStatus.putIfAbsent(best ?? 'none', () => <String>[]).add(p.name);
      }
      String title(String key) => switch (key) {
        'none' => 'No plan yet',
        'draft' => 'Draft, not approved',
        'approved' => 'Approved, not published',
        'published' => 'Published',
        _ => key,
      };
      final List<String> keys = <String>[
        'none',
        'draft',
        'approved',
        ...byStatus.keys.where(
          (String k) =>
              !<String>['none', 'draft', 'approved', 'published'].contains(k),
        ),
        'published',
      ].where(byStatus.containsKey).toList(growable: false);
      final int published = byStatus['published']?.length ?? 0;
      final int without = people.length - published;
      final String weekLabel = scoutWeekText(monday);
      return _say(
        without == 0
            ? 'Every salesperson has a published route for $weekLabel.'
            : '$without of ${people.length} salespeople have no published route for $weekLabel.',
        dataUsed: 'route_plans · week of ${_dm(monday)}',
      ).withCard(
        ScoutCard(
          sections: <ScoutSection>[
            for (final String key in keys)
              ScoutSection(
                title: '${title(key)} (${byStatus[key]!.length})',
                lines: (byStatus[key]!..sort()),
              ),
          ],
        ),
      );
    });
  }

  Future<ScoutPlannerTarget> planWeek({
    String? person,
    EntityRef? memoryPerson,
    CopilotRange? week,
  }) async {
    final List<EntityRef> people;
    try {
      people = await _people();
    } on _ScoutReadError catch (error) {
      return ScoutPlannerTarget(
        message: 'I could not read ${error.what}. Try again.',
      );
    }
    EntityRef? who = memoryPerson;
    if (person != null) {
      final Resolution r = resolveEntity(person, people);
      final ScoutAnswer? problem = _pickProblem(r, person, 'salesperson');
      if (problem != null) {
        return ScoutPlannerTarget(message: problem.reply.text);
      }
      who = (r as One).entity;
    }
    if (who == null) {
      return ScoutPlannerTarget(message: _needPerson().reply.text);
    }
    final DateTime monday = _mondayFor(week);
    return ScoutPlannerTarget(
      person: who,
      weekStart: DateTime(monday.year, monday.month, monday.day),
      weekLabel: scoutWeekText(monday),
    );
  }
}

extension on ScoutAnswer {
  ScoutAnswer withCard(ScoutCard card) => ScoutAnswer(
    CopilotReply(reply.text, card: card, dataUsed: reply.dataUsed),
    shop: shop,
    person: person,
  );
}
