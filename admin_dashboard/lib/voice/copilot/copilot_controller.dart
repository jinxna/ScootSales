import 'package:flutter/foundation.dart';

import '../../models/action_centre_item.dart';
import '../../models/user_profile.dart';
import '../../utils/order_data_utils.dart';

import 'copilot_dates.dart';
import 'copilot_entity_resolver.dart';
import 'copilot_grammar.dart';
import 'copilot_scout.dart';
import 'order_search_session.dart';

enum CopilotEntryKind { answer, refusal, error }

class CopilotEntry {
  const CopilotEntry.user(this.text)
    : fromUser = true,
      items = null,
      pending = null,
      card = null,
      dataUsed = null,
      charts = const <ScoutChart>[],
      kind = CopilotEntryKind.answer,
      retryText = null;
  const CopilotEntry.assistant(
    this.text, {
    this.items,
    this.pending,
    this.card,
    this.dataUsed,
    this.charts = const <ScoutChart>[],
    this.kind = CopilotEntryKind.answer,
    this.retryText,
  }) : fromUser = false;

  final bool fromUser;
  final String text;
  final CopilotEntryKind kind;

  final String? retryText;
  final List<ActionCentreItem>? items;
  final PendingAction? pending;

  final Object? card;
  final String? dataUsed;
  final List<ScoutChart> charts;
}

enum PlannerOpen { withChoice, pageOnly, unavailable }

sealed class PendingAction {
  const PendingAction({required this.expiresAt});
  final DateTime expiresAt;
}

class PendingStatusChange extends PendingAction {
  const PendingStatusChange({
    required this.item,
    required this.status,
    required this.shownStatus,
    required super.expiresAt,
  });

  final ActionCentreItem item;
  final String status;
  final String shownStatus;
}

class PendingOrderApproval extends PendingAction {
  const PendingOrderApproval({
    required this.orders,
    required this.lines,
    required super.expiresAt,
  });

  final List<Map<String, dynamic>> orders;
  final List<String> lines;
}

const int kCopilotApprovalLimit = 10;

class OrderApprovalActions {
  const OrderApprovalActions({
    required this.canDecide,
    required this.limitWarnings,
    required this.approve,
  });

  final bool Function(Map<String, dynamic> order) canDecide;
  final Future<List<String>> Function(Map<String, dynamic> order) limitWarnings;
  final Future<String?> Function(Map<String, dynamic> order) approve;
}

typedef LoadItems =
    Future<({List<ActionCentreItem> items, List<String> failedSources})>
    Function();
typedef ReadStatus = Future<String> Function(String itemId);

typedef WriteStatus =
    Future<bool> Function(
      ActionCentreItem item,
      String expectedStatus,
      String status,
    );

class CopilotMemory {
  final List<CopilotEntry> entries = <CopilotEntry>[];
  List<ActionCentreItem> shown = const <ActionCentreItem>[];
  ActionCentreItem? focus;

  CopilotIntent? lastIntent;

  EntityRef? lastShop;
  EntityRef? lastPerson;
  ScoutTopic? lastTopic;

  void forgetSubjects() {
    lastShop = null;
    lastPerson = null;
    lastTopic = null;
  }
}

const Duration kCopilotConfirmWindow = Duration(seconds: 60);

String copilotStatusLabel(String status) => switch (status) {
  'in_review' => 'in review',
  'ignored' => 'ignored',
  'resolved' => 'resolved',
  _ => 'new',
};

class CopilotController extends ChangeNotifier {
  CopilotController({
    required this.allowed,
    required this.loadItems,
    required this.readStatus,
    required this.writeStatus,
    this.orders,
    this.approvals,
    this.openOrder,
    this.openPage,
    this.scout,
    this.openPlanner,
    this.routesViewOnly = false,
    this.ordersViewOnly = false,
    this.advanced = true,
    CopilotMemory? memory,
    DateTime Function()? clock,
  }) : memory = memory ?? CopilotMemory(),
       _clock = clock ?? DateTime.now;

  final CopilotMemory memory;

  final bool allowed;
  final LoadItems loadItems;
  final ReadStatus readStatus;
  final WriteStatus writeStatus;

  final OrderSearchSession? orders;

  final OrderApprovalActions? approvals;

  final void Function(Map<String, dynamic> order)? openOrder;

  final Future<bool> Function(String pageKey)? openPage;

  final ScoutEngine? scout;

  final Future<PlannerOpen> Function(String salesmanUid, DateTime weekStart)?
  openPlanner;

  final bool routesViewOnly;
  final bool ordersViewOnly;

  final bool advanced;
  final DateTime Function() _clock;

  List<CopilotEntry> get entries => memory.entries;
  List<ActionCentreItem> get _shown => memory.shown;
  set _shown(List<ActionCentreItem> value) => memory.shown = value;
  ActionCentreItem? get _focus => memory.focus;
  set _focus(ActionCentreItem? value) => memory.focus = value;
  int _epoch = 0;
  PendingAction? _pending;
  bool _busy = false;
  int _generation = 0;

  bool _ordersShownLast = false;
  ExportCard? _exportCard;
  ChoiceCard? _choiceCard;

  bool get busy => _busy;
  List<ActionCentreItem> get shownItems => _shown;
  ActionCentreItem? get focus => _focus;
  PendingAction? get pending => _pending;

  ExportCard? get liveExportCard =>
      orders?.pendingExport == null ? null : _exportCard;

  ChoiceCard? get liveChoiceCard =>
      orders?.choices == null ? null : _choiceCard;

  Future<bool> handle(String transcript) async {
    final CopilotIntent? intent = interpretCopilot(transcript, now: _clock());
    if (intent == null) return false;
    if (intent is SmallTalkIntent &&
        intent.kind == SmallTalkKind.offTopic &&
        await _namesSomeoneKnown(transcript)) {
      return false;
    }
    await run(intent, transcript);
    return true;
  }

  static String _plainWords(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<List<String>> salespersonNames() async => <String>[
    for (final EntityRef person in <EntityRef>[
      ...?await orders?.salespeople(),
      ?memory.lastPerson,
    ])
      person.name,
  ];

  Future<bool> _namesSomeoneKnown(String transcript) async {
    final String said = ' ${_plainWords(transcript)} ';
    final List<EntityRef> known = <EntityRef>[
      ...?await orders?.salespeople(),
      ?memory.lastShop,
      ?memory.lastPerson,
    ];
    return known.any(
      (EntityRef entity) => <String>[
        ..._plainWords(
          entity.name,
        ).split(' ').where((String part) => part.length >= 3),
        _plainWords(entity.name),
        _plainWords(entity.code),
      ].any((String part) => part.isNotEmpty && said.contains(' $part ')),
    );
  }

  Future<void> run(CopilotIntent requested, String transcript) async {
    final CopilotIntent intent = requested is FollowUpIntent
        ? _resolveFollowUp(requested)
        : requested;
    if (_busy) {
      _say('Wait for the last answer first.');
      return;
    }
    memory.lastIntent = intent;
    entries.add(CopilotEntry.user(transcript.trim()));
    if (!allowed) {
      _say('This account cannot use Scout.');
      return;
    }
    if (!advanced &&
        (intent is BriefingIntent ||
            intent is ExplainIntent ||
            intent is SetStatusIntent ||
            intent is RankWhyIntent ||
            intent is RouteWhyIntent ||
            intent is PersonVisitsIntent ||
            intent is DueIntent ||
            intent is PlanWeekIntent ||
            intent is NoRouteIntent ||
            intent is OpenPlannerIntent ||
            intent is ShopsOfPersonIntent ||
            intent is TeamIntent)) {
      _say(
        'That is not in this edition. I can still search and export orders, '
        'rank top retailers and products, and open pages.',
      );
      notifyListeners();
      return;
    }
    final bool acknowledged =
        intent is SmallTalkIntent && intent.kind == SmallTalkKind.acknowledged;
    if (intent is! ConfirmIntent &&
        intent is! CancelIntent &&
        !acknowledged &&
        _pending != null) {
      _dropPending(silent: true);
    }
    if (intent is! ConfirmIntent &&
        intent is! CancelIntent &&
        !acknowledged &&
        intent is! PickIntent &&
        intent is! SearchOrdersIntent &&
        intent is! BriefRetailerIntent &&
        intent is! ResetFiltersIntent) {
      orders?.dropPending();
    }

    final int generation = ++_generation;
    final int epoch = _epoch;
    _busy = true;
    notifyListeners();
    try {
      switch (intent) {
        case BriefingIntent():
          await _briefing(generation);
        case ExplainIntent(:final int? position):
          _explain(position);
        case SetStatusIntent(:final String status, :final int? position):
          await _propose(status, position);
        case ConfirmIntent():
          await _confirm();
        case CancelIntent():
          _pending == null && orders?.pendingExport == null
              ? _say('Nothing to cancel.')
              : _dropPending();
        case CompoundIntent():
          _say('Give me one command at a time.');
        case SearchOrdersIntent():
          await _searchOrders(intent, generation);
        case BriefRetailerIntent():
          await _briefRetailer(intent, generation);
        case RankWhyIntent():
          await _rankWhy(intent, generation);
        case RouteWhyIntent():
          await _scoutAnswer(
            (ScoutEngine e) => e.routeWhy(
              shop: intent.shop,
              person: intent.person,
              either: intent.subject,
              memoryShop: memory.lastShop,
              memoryPerson: memory.lastPerson,
            ),
            ScoutTopic.routeWhy,
            generation,
          );
        case PersonVisitsIntent():
          await _scoutAnswer(
            (ScoutEngine e) => e.personVisits(
              person: intent.person,
              memoryPerson: memory.lastPerson,
              week: intent.week,
            ),
            ScoutTopic.personVisits,
            generation,
          );
        case DueIntent():
          await _scoutAnswer(
            (ScoutEngine e) => e.due(stoppedOnly: intent.stoppedOnly),
            ScoutTopic.due,
            generation,
          );
        case NoRouteIntent():
          await _scoutAnswer(
            (ScoutEngine e) => e.noRoute(intent.week),
            ScoutTopic.noRoute,
            generation,
          );
        case PlanWeekIntent():
          await _planWeek(intent, generation);
        case ShopsOfPersonIntent(:final String words):
          await _scoutAnswer(
            (ScoutEngine e) =>
                e.shopsOf(words, memoryPerson: memory.lastPerson),
            ScoutTopic.shops,
            generation,
          );
        case TeamIntent(:final String words):
          await _scoutAnswer(
            (ScoutEngine e) => e.teamOf(words, memoryPerson: memory.lastPerson),
            ScoutTopic.team,
            generation,
          );
        case OpenPlannerIntent():
          await _openPlannerFor(
            EntityRef(
              kind: EntityKind.salesperson,
              id: intent.salesmanUid,
              name: intent.personName,
            ),
            intent.weekStart,
          );
        case HelpIntent():
          _say(_helpText);
        case FollowUpIntent():
          _say('I am not sure what you mean, so I did not change anything.');
        case ExportResultsIntent(:final SearchOrdersIntent? search):
          await _exportResults(search, generation);
        case PickIntent(:final int position):
          await _pick(position);
        case OpenResultIntent(:final int position):
          _openResult(position);
        case ResetFiltersIntent():
          orders?.reset();
          _ordersShownLast = false;
          _say(
            'Filters cleared. Ask for orders again, for example "orders this week".',
          );
        case SmallTalkIntent(:final SmallTalkKind kind):
          _say(_smallTalkText(kind));
        case TopIntent():
          await _top(intent, generation);
        case OpenProgressIntent():
          await _openProgress(intent);
        case ActionRequestIntent():
          await _actionRequest(intent, generation);
        case UnclearIntent():
          _say(
            advanced
                ? 'I am not sure what you mean, so I did not change anything. '
                      'Say for example "explain item 2" or "mark item 2 as in review".'
                : 'I am not sure what you mean, so I did not change anything. '
                      'Say for example "orders this week" or "open notifications".',
          );
      }
    } catch (_) {
      _say('That did not work. No change was made. Try again.');
    } finally {
      if (epoch != _epoch) _clearChat();
      _busy = false;
      notifyListeners();
    }
  }

  void newChat() {
    _epoch++;
    _generation++;
    _clearChat();
    notifyListeners();
  }

  void _clearChat() {
    memory.forgetSubjects();
    entries.clear();
    _shown = const <ActionCentreItem>[];
    _focus = null;
    _pending = null;
    _exportCard = null;
    _choiceCard = null;
    _ordersShownLast = false;
    memory.lastIntent = null;
    orders?.reset();
  }

  void clearFocus() {
    if (_focus == null) return;
    _focus = null;
    notifyListeners();
  }

  void exchange(
    String transcript,
    String answer, {
    CopilotEntryKind kind = CopilotEntryKind.answer,
    String? retryText,
  }) {
    _pending = null;
    orders?.dropPending();
    memory.lastIntent = null;
    entries
      ..add(CopilotEntry.user(transcript.trim()))
      ..add(CopilotEntry.assistant(answer, kind: kind, retryText: retryText));
    notifyListeners();
  }

  void dropLastExchange() {
    if (entries.length < 2) return;
    entries
      ..removeLast()
      ..removeLast();
    notifyListeners();
  }

  void invalidatePending() {
    orders?.dropPending();
    if (_pending == null) return;
    _dropPending(silent: true);
    notifyListeners();
  }

  Future<void> confirmPending() => handle('confirm');

  void cancelPending() {
    if (_pending != null || orders?.pendingExport != null) {
      entries.add(const CopilotEntry.user('cancel'));
      _dropPending();
      notifyListeners();
    }
  }

  void _reply(
    CopilotReply reply, {
    List<ScoutChart> charts = const <ScoutChart>[],
  }) {
    final Object? card = reply.card;
    if (card is ChoiceCard) _choiceCard = card;
    entries.add(
      CopilotEntry.assistant(
        reply.text,
        card: card,
        dataUsed: reply.dataUsed,
        charts: charts,
      ),
    );
  }

  void _rememberFromOrders() {
    final OrderQuery? query = orders?.current?.query;
    if (query == null) return;
    if (query.retailer != null) memory.lastShop = query.retailer;
    if (query.salesperson != null) memory.lastPerson = query.salesperson;
    memory.lastTopic = ScoutTopic.orders;
  }

  CopilotIntent _resolveFollowUp(FollowUpIntent follow) {
    final CopilotIntent fallback =
        follow.orderFallback ?? const UnclearIntent();
    if (!advanced || scout == null) return fallback;
    final String? subject = follow.subject;
    switch (memory.lastTopic) {
      case ScoutTopic.rankWhy:
        return follow.personPronoun
            ? const PersonVisitsIntent()
            : RankWhyIntent(subject ?? '');
      case ScoutTopic.routeWhy:
        return RouteWhyIntent(subject: subject);
      case ScoutTopic.personVisits:
        return PersonVisitsIntent(person: subject);
      case ScoutTopic.planWeek:
        return PlanWeekIntent(person: subject);
      case ScoutTopic.shops:
        return ShopsOfPersonIntent(subject ?? '');
      case ScoutTopic.team:
        return TeamIntent(subject ?? '');
      case ScoutTopic.brief:
        return follow.personPronoun
            ? const PersonVisitsIntent()
            : BriefRetailerIntent(subject ?? '', fromMemory: subject == null);
      case ScoutTopic.noRoute:
      case ScoutTopic.due:
      case ScoutTopic.orders:
      case null:
        return fallback;
    }
  }

  Future<void> _scoutAnswer(
    Future<ScoutAnswer> Function(ScoutEngine engine) ask,
    ScoutTopic topic,
    int generation,
  ) async {
    final ScoutEngine? engine = scout;
    if (engine == null) {
      _say('Answers like this are not available for this account.');
      return;
    }
    final ScoutAnswer answer = await ask(engine);
    if (generation != _generation) return;
    _ordersShownLast = false;
    _reply(answer.reply, charts: answer.charts);
    if (answer.shop != null) memory.lastShop = answer.shop;
    if (answer.person != null) memory.lastPerson = answer.person;
    memory.lastTopic = topic;
  }

  Future<void> _planWeek(PlanWeekIntent intent, int generation) async {
    final ScoutEngine? engine = scout;
    if (engine == null) {
      _say('Answers like this are not available for this account.');
      return;
    }
    final ScoutPlannerTarget target = await engine.planWeek(
      person: intent.person,
      memoryPerson: memory.lastPerson,
      week: intent.week,
    );
    if (generation != _generation) return;
    if (target.message != null) {
      _say(target.message!);
      return;
    }
    await _openPlannerFor(target.person!, target.weekStart!);
  }

  Future<void> _openPlannerFor(EntityRef person, DateTime weekStart) async {
    memory.lastPerson = person;
    memory.lastTopic = ScoutTopic.planWeek;
    final PlannerOpen result =
        await openPlanner?.call(person.id, weekStart) ??
        PlannerOpen.unavailable;
    final String week = scoutWeekText(weekStart);
    switch (result) {
      case PlannerOpen.withChoice:
        _say(
          routesViewOnly
              ? 'Route Planner is view only for your role, so I cannot start a '
                    'route. I opened it with ${person.name} and '
                    '$week chosen so you can review.'
              : 'Opened Route Planner with ${person.name} and '
                    '$week chosen. Press Generate there. I do not create or '
                    'change routes myself.',
        );
      case PlannerOpen.pageOnly:
        _say(
          'Opened Route Planner. Choose ${person.name} and $week '
          'there. I do not create or change routes myself.',
        );
      case PlannerOpen.unavailable:
        _say('Route Planner is not available to your role.');
    }
  }

  String _smallTalkText(SmallTalkKind kind) {
    final String scope = advanced
        ? "this company's orders, routes, shops and team"
        : "this company's orders, shops and products";
    return switch (kind) {
      SmallTalkKind.greeting =>
        'Hello. I answer questions about $scope. Try one of these.',
      SmallTalkKind.howAreYou =>
        'I am doing well, thanks. I answer questions about $scope. '
            'Try one of these.',
      SmallTalkKind.thanks =>
        'You are welcome. Ask me when you need something else.',
      SmallTalkKind.acknowledged =>
        _pending != null || orders?.pendingExport != null
            ? 'Noted. Your request still waits. Say confirm or cancel.'
            : 'Noted. Ask me when you need something else.',
      SmallTalkKind.whoAreYou =>
        'I am Scout. I answer questions about $scope. Try one of these.',
      SmallTalkKind.chatter =>
        'I am here for questions about $scope. Try one of these.',
      SmallTalkKind.offTopic =>
        'I can only answer questions about $scope, so I cannot answer '
            'that. Try one of these.',
    };
  }

  String get _helpText => advanced
      ? 'Here is what I can do.\n'
            '• Search and export orders: "orders this week".\n'
            '• Rank top retailers and products: "top retailers this month".\n'
            '• Tell you what needs attention: "what needs my attention today".\n'
            '• Explain a ranking: "why is a shop ranked first".\n'
            '• Explain a route stop: "why is a shop on a salesperson\'s route".\n'
            '• Name the shops a salesperson should visit: "who should a salesperson visit next week".\n'
            '• Say who is due or has stopped buying: "who is due".\n'
            '• Show a shop\'s visit brief and orders: "brief for a shop".\n'
            '• Open the planner for a person and week: "plan next week for a salesperson".\n'
            '• Name who has no route: "who has no route next week".\n'
            '• List a salesperson\'s shops: "which shops does a salesperson cover".\n'
            '• Show a supervisor\'s team: "who reports to a supervisor".\n'
            '• Open pages: "open notifications".\n'
            'I remember the last shop and salesperson, so you can follow up with "and her?" or "that shop".'
      : 'Here is what I can do.\n'
            '• Search and export orders: "orders this week".\n'
            '• Rank top retailers and products: "top retailers this month".\n'
            '• Open pages: "open notifications".';

  Future<void> _searchOrders(SearchOrdersIntent intent, int generation) async {
    final OrderSearchSession? session = orders;
    if (session == null) {
      _say('Order search is not available for this account.');
      return;
    }
    final CopilotReply reply = await session.search(intent);
    if (generation != _generation) return;
    _ordersShownLast = true;
    _reply(reply);
    _rememberFromOrders();
  }

  Future<void> _top(TopIntent intent, int generation) async {
    final OrderSearchSession? session = orders;
    if (session == null) {
      _say('Rankings are not available for this account.');
      return;
    }
    final CopilotReply reply = await session.top(intent);
    if (generation != _generation) return;
    _ordersShownLast = false;
    _reply(reply);
  }

  Future<void> _openProgress(OpenProgressIntent intent) async {
    for (final String key in const <String>[
      'team_activity',
      'salesman_activity',
    ]) {
      if (await openPage?.call(key) ?? false) {
        _say(
          'Opened ${key == 'team_activity' ? 'Team Activity' : 'Salesman Activity'}. '
          'It shows the live position and activity of your salespeople '
          '(${intent.range.label}).',
        );
        return;
      }
    }
    _say('Salesman progress is not available to your role.');
  }

  Future<void> _actionRequest(
    ActionRequestIntent intent,
    int generation,
  ) async {
    final OrderSearchSession? session = orders;
    final String? name = intent.name;
    if (intent.kind == ActionRequestKind.createRoute) {
      if (name != null &&
          session != null &&
          !await session.knowsSalesperson(name)) {
        if (generation == _generation) _say(copilotNotFound(name));
        return;
      }
      final bool opened = await openPage?.call('route_planner') ?? false;
      if (generation != _generation) return;
      if (!opened) {
        _say('Route Planner is not available to your role.');
        return;
      }
      final String who = name == null ? '' : ' for $name';
      final String when = intent.range == null ? '' : ' ${intent.range!.name}';
      _say(
        routesViewOnly
            ? 'Route Planner is view only for your role, so I cannot start a '
                  'route$who. I opened it so you can review routes.'
            : 'Opened Route Planner. Create the route$who$when there and '
                  'publish it when it is ready. I do not create or change routes myself.',
      );
      return;
    }
    final OrderResultSet? shown = session?.current;
    final bool refersToShown =
        name == null &&
        intent.range == null &&
        _ordersShownLast &&
        shown != null &&
        !_isAllWaiting(shown.query);
    final bool useShown = refersToShown && shown.rows.isNotEmpty;
    final String emptyShownNote = refersToShown && !useShown
        ? 'The last order list had no orders, so this is every waiting order. '
        : '';
    CopilotReply? found;
    if (session != null && !useShown) {
      found = await session.search(
        SearchOrdersIntent(
          status: 'submitted',
          anyName: name,
          period: intent.range,
        ),
      );
      if (generation != _generation) return;
      final Object? card = found.card;
      if (card is ChoiceCard || isCopilotNotFound(found.text)) {
        _ordersShownLast = true;
        _reply(found);
        return;
      }
    }
    final List<Map<String, dynamic>> waiting = <Map<String, dynamic>>[
      for (final Map<String, dynamic> row
          in (session?.current?.rows ?? const <Map<String, dynamic>>[]).take(
            kOrderRowsShown,
          ))
        if (isPendingApprovalOrder(row)) row,
    ];
    final Object? card = found?.card;
    final bool allDates = name == null && intent.range == null;
    final String count = useShown
        ? '${waiting.length} of the orders shown '
              '${waiting.length == 1 ? 'waits' : 'wait'} for approval.'
        : switch (card) {
            OrderResultsCard(:final int total) =>
              '$emptyShownNote${total == 0 ? 'No' : total} order${total == 1 ? ' is' : 's are'} '
                  'waiting for approval'
                  '${allDates ? ' (all dates, the same count as the home page).' : '.'}',
            _ =>
              found?.text ?? 'Order search is not available for this account.',
          };
    final OrderApprovalActions? actions = ordersViewOnly ? null : approvals;
    if (actions == null) {
      final bool opened = await openPage?.call('all_orders') ?? false;
      if (generation != _generation) return;
      final String action = ordersViewOnly
          ? 'Order approval is view only for your role. No order was changed.'
          : 'I cannot approve orders for this account. Review each order there and approve it yourself.';
      _ordersShownLast = card is OrderResultsCard;
      entries.add(
        CopilotEntry.assistant(
          '$count ${opened ? 'Opened All Orders. ' : ''}$action',
          card: card,
          dataUsed: found?.dataUsed,
          kind: CopilotEntryKind.refusal,
        ),
      );
      return;
    }
    final List<Map<String, dynamic>> offer = waiting
        .where(actions.canDecide)
        .take(kCopilotApprovalLimit)
        .toList(growable: false);
    final String used =
        'orders · ${_plural(waiting.length, 'waiting order')} read · '
        'each one is read again when you confirm';
    if (offer.isEmpty) {
      _ordersShownLast = card is OrderResultsCard;
      entries.add(
        CopilotEntry.assistant(
          waiting.isEmpty
              ? count
              : '$count None of them can be approved by you here. '
                    'Open them on All Orders to decide.',
          card: card,
          dataUsed: used,
        ),
      );
      return;
    }
    final DateTime now = _clock();
    _ordersShownLast = false;
    _pending = PendingOrderApproval(
      orders: offer,
      lines: <String>[
        for (final Map<String, dynamic> order in offer)
          OrderSearchSession.approvalLine(order, now),
      ],
      expiresAt: now.add(kCopilotConfirmWindow),
    );
    entries.add(
      CopilotEntry.assistant(
        '$count Approve ${_plural(offer.length, 'order')}?',
        pending: _pending,
        dataUsed: used,
      ),
    );
  }

  static bool _isAllWaiting(OrderQuery query) =>
      query.period.kind == CopilotRangeKind.allTime &&
      query.status == 'submitted' &&
      query.salesperson == null &&
      query.retailer == null;

  static String _plural(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';

  Future<void> _briefRetailer(
    BriefRetailerIntent intent,
    int generation,
  ) async {
    final OrderSearchSession? session = orders;
    if (session == null) {
      _say('Retailer briefs are not available for this account.');
      return;
    }
    final String spoken = intent.fromMemory || intent.name.trim().isEmpty
        ? ''
        : isShopPronoun(intent.name.trim())
        ? ''
        : intent.name.trim();
    final EntityRef? remembered = memory.lastShop;
    if (spoken.isEmpty && remembered == null) {
      _say(
        'Which shop do you mean? Ask about one first, for example '
        '"brief for a shop".',
      );
      return;
    }
    final BriefRetailerIntent effective = spoken.isEmpty
        ? BriefRetailerIntent(remembered!.name, period: intent.period)
        : intent;
    final CopilotReply orderReply = await session.briefRetailer(effective);
    final ScoutEngine? engine = scout;
    ScoutBriefPart part = const ScoutBriefPart();
    if (engine != null) {
      part = await engine.brief(spoken.isEmpty ? null : spoken, remembered);
    }
    if (generation != _generation) return;
    _ordersShownLast = true;
    final bool ordersFound = orderReply.card is OrderResultsCard;
    final OrderQuery? query = session.current?.query;
    final EntityRef? shop =
        part.shop ?? (ordersFound ? query?.retailer : null) ?? remembered;
    if (shop != null) memory.lastShop = shop;
    memory.lastTopic = ScoutTopic.brief;
    if (part.text == null) {
      _reply(orderReply);
      return;
    }
    final bool ordersMissing =
        isCopilotNotFound(orderReply.text) || orderReply.card is ChoiceCard;
    final String period = query?.period.label ?? '';
    final String? partUsed = part.dataUsed;
    _reply(
      CopilotReply(
        ordersMissing ? part.text! : '${part.text}\n\n${orderReply.text}',
        card: ordersMissing ? null : orderReply.card,
        dataUsed: ordersMissing || period.isEmpty
            ? partUsed
            : <String>[?partUsed, 'orders · $period'].join('; '),
      ),
      charts: part.charts,
    );
  }

  Future<void> _rankWhy(RankWhyIntent intent, int generation) async {
    final ScoutEngine? engine = scout;
    if (engine == null) {
      _say('Ranking explanations are not available for this account.');
      return;
    }
    final String spoken = intent.name.trim();
    await _scoutAnswer(
      (ScoutEngine e) =>
          e.rankWhy(spoken.isEmpty ? null : spoken, memory.lastShop),
      ScoutTopic.rankWhy,
      generation,
    );
  }

  Future<void> _exportResults(
    SearchOrdersIntent? search,
    int generation,
  ) async {
    if (search != null) {
      final Object? before = orders?.current;
      await _searchOrders(search, generation);
      final OrderSearchSession? session = orders;
      if (generation != _generation ||
          session == null ||
          session.choices != null ||
          identical(session.current, before)) {
        return;
      }
    }
    _exportOffer();
  }

  void _exportOffer() {
    final OrderSearchSession? session = orders;
    if (session == null) {
      _say('Order export is not available for this account.');
      return;
    }
    final CopilotReply reply = session.offerExport();
    final Object? card = reply.card;
    _exportCard = card is ExportCard ? card : null;
    _reply(reply);
  }

  Future<void> _pick(int position) async {
    final CopilotReply? chosen = await orders?.pick(position);
    if (chosen != null) {
      _ordersShownLast = true;
      _reply(chosen);
      return;
    }
    if (_ordersShownLast && orders?.current != null) {
      _openResult(position);
      return;
    }
    _explain(position);
  }

  void _openResult(int position) {
    final OrderSearchSession? session = orders;
    final Map<String, dynamic>? order = session?.shownOrder(position);
    if (order == null) {
      final int shown = session?.current == null
          ? 0
          : (session!.current!.rows.length < kOrderRowsShown
                ? session.current!.rows.length
                : kOrderRowsShown);
      _say(
        shown == 0
            ? 'There are no orders on screen. Search for orders first.'
            : 'Only $shown orders are shown. Choose a number from 1 to $shown.',
      );
      return;
    }
    openOrder?.call(order);
    _say('Opened order $position.');
  }

  Future<void> _briefing(int generation) async {
    final ({List<ActionCentreItem> items, List<String> failedSources}) result =
        await loadItems();
    if (generation != _generation) return;
    _shown = result.items;
    _focus = null;
    _ordersShownLast = false;
    if (result.items.isEmpty) {
      _say(
        result.failedSources.isEmpty
            ? 'Nothing needs your attention now.'
            : 'No items found, but some sources could not be read (${result.failedSources.join(', ')}). The list may be incomplete.',
      );
      return;
    }
    final String partial = result.failedSources.isEmpty
        ? ''
        : ' Some sources could not be read, so the list may be incomplete.';
    entries.add(
      CopilotEntry.assistant(
        'These ${result.items.length} items need attention most.$partial',
        items: result.items,
      ),
    );
  }

  ActionCentreItem? _resolve(int? position) {
    if (_shown.isEmpty) {
      _say(
        'Ask "what needs my attention today" first. Then I can use item numbers.',
      );
      return null;
    }
    if (position == null) {
      if (_focus == null) {
        _say('Which item? Say its number, for example "the second item".');
      }
      return _focus;
    }
    if (position < 1 || position > _shown.length) {
      _say(
        'The list has ${_shown.length} items. Choose a number from 1 to ${_shown.length}.',
      );
      return null;
    }
    return _focus = _shown[position - 1];
  }

  void _explain(int? position) {
    final ActionCentreItem? item = _resolve(position);
    if (item == null) return;
    final String reason = item.reason.trim().isEmpty
        ? 'No reason is saved for this item.'
        : item.reason.trim();
    final String next = item.recommendedAction.trim().isEmpty
        ? ''
        : ' Suggested action: ${item.recommendedAction.trim()}';
    _say('${item.title}. $reason$next (confidence: ${item.confidence}).');
  }

  Future<void> _propose(String status, int? position) async {
    final ActionCentreItem? item = _resolve(position);
    if (item == null) return;
    final String current = await readStatus(item.id);
    _pending = PendingStatusChange(
      item: item,
      status: status,
      shownStatus: current,
      expiresAt: _clock().add(kCopilotConfirmWindow),
    );
    entries.add(
      CopilotEntry.assistant(
        'Set "${item.title}" to ${copilotStatusLabel(status)}? '
        'This changes only your own review status. It does not solve the problem.',
        pending: _pending,
      ),
    );
  }

  Future<void> _confirm() async {
    final PendingAction? pending = _pending;
    if (pending == null) {
      final OrderSearchSession? session = orders;
      if (session != null && session.pendingExport != null) {
        _reply(await session.confirmExport());
        _exportCard = null;
        return;
      }
      _say('Nothing to confirm.');
      return;
    }
    _pending = null;
    if (_clock().isAfter(pending.expiresAt)) {
      _say('That confirmation expired. Ask again.');
      return;
    }
    switch (pending) {
      case PendingStatusChange():
        await _confirmStatus(pending);
      case PendingOrderApproval():
        await _confirmApproval(pending);
    }
  }

  Future<void> _confirmApproval(PendingOrderApproval pending) async {
    final OrderApprovalActions? actions = ordersViewOnly ? null : approvals;
    if (actions == null) {
      _say('Order approval is view only for your role. No order was changed.');
      return;
    }
    int approved = 0;
    final List<(Map<String, dynamic>, String)> skipped =
        <(Map<String, dynamic>, String)>[];
    for (final Map<String, dynamic> order in pending.orders) {
      final List<String> warnings = await actions.limitWarnings(order);
      if (warnings.isNotEmpty) {
        skipped.add((order, warnings.join(' ')));
        continue;
      }
      final String? failure = await actions.approve(order);
      if (failure == null) {
        approved++;
      } else {
        skipped.add((order, failure));
      }
    }
    final OrderSearchSession? session = orders;
    session?.forgetReads();
    _ordersShownLast = false;
    String left;
    try {
      final int? still = await session?.countWaiting?.call();
      left = switch (still) {
        null => '',
        0 => ' No orders wait now.',
        1 => ' 1 more waits.',
        _ => ' $still more wait.',
      };
    } on Object catch (error) {
      debugPrint('Scout could not count the waiting orders: $error');
      left = ' I could not count the orders that still wait.';
    }
    final List<String> lines = <String>[
      for (final (Map<String, dynamic> order, String reason) in skipped)
        '${_orderLabel(order)} · $reason',
    ];
    entries.add(
      CopilotEntry.assistant(
        'Approved $approved.$left'
        '${skipped.isEmpty ? '' : '\nSkipped ${skipped.length}. Open ${skipped.length == 1 ? 'it' : 'each one'} to decide there.'}',
        card: skipped.isEmpty
            ? null
            : SkippedOrdersCard(
                view: OrderResultsCard(
                  chips: <String>['Skipped ${skipped.length}'],
                  statusCounts: const <String, int>{},
                  valueText: '',
                  rows: lines,
                  rowIds: <String>[
                    for (final (Map<String, dynamic> order, String _)
                        in skipped)
                      _orderId(order),
                  ],
                  total: skipped.length,
                  shown: skipped.length,
                  truncated: false,
                  spokenSummary: '${_plural(skipped.length, 'order')} skipped.',
                ),
                orders: <Map<String, dynamic>>[
                  for (final (Map<String, dynamic> order, String _) in skipped)
                    order,
                ],
              ),
        dataUsed:
            'orders · products (order limits) · approved with the Approve '
            'action and logged as from Scout · waiting count read after',
      ),
    );
  }

  static String _orderId(Map<String, dynamic> order) =>
      '${order['orderId'] ?? order['docId'] ?? 'Order'}'.trim();

  static String _orderLabel(Map<String, dynamic> order) {
    final String shop = '${order['retailerName'] ?? ''}'.trim();
    return shop.isEmpty ? _orderId(order) : '${_orderId(order)} · $shop';
  }

  Future<void> _confirmStatus(PendingStatusChange pending) async {
    final bool wrote = await writeStatus(
      pending.item,
      pending.shownStatus,
      pending.status,
    );
    if (!wrote) {
      _say(
        'This item changed since I showed it. No change was made. Ask again.',
      );
      return;
    }
    final int index = _shown.indexWhere(
      (ActionCentreItem i) => i.id == pending.item.id,
    );
    if (index != -1) {
      final List<ActionCentreItem> next = List<ActionCentreItem>.of(_shown);
      next[index] = next[index].copyWith(status: pending.status);
      _shown = next;
      _focus = next[index];
    }
    _say(
      'Done. "${pending.item.title}" is now ${copilotStatusLabel(pending.status)} for you.',
    );
  }

  void _dropPending({bool silent = false}) {
    final bool hadExport = orders?.pendingExport != null;
    _pending = null;
    orders?.dropPending();
    if (!silent) {
      _say(
        hadExport
            ? 'Cancelled. Nothing was downloaded.'
            : 'Cancelled. No change was made.',
      );
    }
  }

  void _say(String text) => entries.add(CopilotEntry.assistant(text));
}

const String _kBriefing = 'Daily briefing';
const String _kWaiting = 'Show orders waiting for approval';
const String _kOpenOrders = 'Open all orders';
const List<String> _kBasicFollowUps = <String>[
  _kBriefing,
  _kWaiting,
  _kOpenOrders,
];

List<String> copilotFirstSuggestions(
  UserProfile user, {
  bool advanced = true,
}) => <String>[
  if (advanced) _kBriefing,
  _kWaiting,
  _kOpenOrders,
  'Orders this week',
  'Top retailers this month',
  if (user.isAdmin || user.isDeveloper)
    'Open Route Planner'
  else
    'Check my salesman progress today',
];

const String _kBriefThat = 'Brief for that shop';
const String _kDue = 'Who is due?';
const String _kNoRoute = 'Who has no route next week?';
const String _kPlanHer = 'Plan next week for her';
const String _kSayThere = 'What should he say there?';

const Set<String> _kAdvancedSuggestions = <String>{
  _kBriefing,
  'Explain the second item',
  'Mark it as in review',
  _kBriefThat,
  _kDue,
  _kNoRoute,
  _kPlanHer,
  _kSayThere,
};

List<String> copilotFollowUps(CopilotIntent? last, {bool advanced = true}) {
  final List<String> all = switch (last) {
    BriefingIntent() => const <String>[
      'Explain the second item',
      _kWaiting,
      _kOpenOrders,
    ],
    ExplainIntent() => const <String>[
      'Mark it as in review',
      _kBriefing,
      _kWaiting,
    ],
    SearchOrdersIntent() || BriefRetailerIntent() => const <String>[
      'Export these orders',
      _kOpenOrders,
      _kBriefing,
    ],
    TopIntent() => const <String>['Orders this week', _kWaiting, _kBriefing],
    RankWhyIntent() => const <String>[_kBriefThat, _kDue, _kNoRoute],
    RouteWhyIntent() => const <String>[_kSayThere, _kDue, _kNoRoute],
    PersonVisitsIntent() => const <String>[_kPlanHer, _kDue, _kNoRoute],
    DueIntent() => const <String>[_kNoRoute, _kBriefing, _kWaiting],
    NoRouteIntent() => const <String>[_kDue, _kBriefing, _kWaiting],
    PlanWeekIntent() => const <String>[_kDue, _kNoRoute, _kBriefing],
    _ => _kBasicFollowUps,
  };
  return advanced
      ? all
      : all
            .where((String s) => !_kAdvancedSuggestions.contains(s))
            .toList(growable: false);
}
