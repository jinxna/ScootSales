import 'package:flutter/foundation.dart';

import '../../models/action_centre_item.dart';
import '../../models/user_profile.dart';
import 'copilot_dates.dart';
import 'copilot_grammar.dart';
import 'order_search_session.dart';

enum CopilotEntryKind { answer, refusal, error }

class CopilotEntry {
  const CopilotEntry.user(this.text)
    : fromUser = true,
      items = null,
      pending = null,
      card = null,
      kind = CopilotEntryKind.answer,
      retryText = null;
  const CopilotEntry.assistant(
    this.text, {
    this.items,
    this.pending,
    this.card,
    this.kind = CopilotEntryKind.answer,
    this.retryText,
  }) : fromUser = false;

  final bool fromUser;
  final String text;
  final CopilotEntryKind kind;

  final String? retryText;
  final List<ActionCentreItem>? items;
  final PendingStatusChange? pending;

  final Object? card;
}

class PendingStatusChange {
  const PendingStatusChange({
    required this.item,
    required this.status,
    required this.shownStatus,
    required this.expiresAt,
  });

  final ActionCentreItem item;
  final String status;
  final String shownStatus;
  final DateTime expiresAt;
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
    this.openOrder,
    this.openPage,
    this.explainRank,
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

  final void Function(Map<String, dynamic> order)? openOrder;

  final Future<bool> Function(String pageKey)? openPage;

  final Future<CopilotReply> Function(RankWhyIntent intent)? explainRank;

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
  PendingStatusChange? _pending;
  bool _busy = false;
  int _generation = 0;

  bool _ordersShownLast = false;
  ExportCard? _exportCard;
  ChoiceCard? _choiceCard;

  bool get busy => _busy;
  List<ActionCentreItem> get shownItems => _shown;
  ActionCentreItem? get focus => _focus;
  PendingStatusChange? get pending => _pending;

  ExportCard? get liveExportCard =>
      orders?.pendingExport == null ? null : _exportCard;

  ChoiceCard? get liveChoiceCard =>
      orders?.choices == null ? null : _choiceCard;

  Future<bool> handle(String transcript) async {
    final CopilotIntent? intent = interpretCopilot(transcript, now: _clock());
    if (intent == null) return false;
    await run(intent, transcript);
    return true;
  }

  Future<void> run(CopilotIntent intent, String transcript) async {
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
            intent is RankWhyIntent)) {
      _say(
        'That is not in this edition. I can still search and export orders, '
        'rank top retailers and products, and open pages.',
      );
      notifyListeners();
      return;
    }
    if (intent is! ConfirmIntent &&
        intent is! CancelIntent &&
        _pending != null) {
      _dropPending(silent: true);
    }
    if (intent is! ConfirmIntent &&
        intent is! CancelIntent &&
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
        case SmallTalkIntent():
          _say(
            advanced
                ? 'I am doing well, thanks. I can brief you on what needs attention, '
                      'search and export orders, rank top retailers and products, explain '
                      'why a retailer is ranked first, and '
                      'open pages. Try "what needs my attention today", "orders this '
                      'week", "top retailers in September" or "open notifications".'
                : 'I am doing well, thanks. I can search and export orders, rank '
                      'top retailers and products, and open pages. Try "orders this '
                      'week", "top retailers in September" or "open notifications".',
          );
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

  void _reply(CopilotReply reply) {
    final Object? card = reply.card;
    if (card is ChoiceCard) _choiceCard = card;
    entries.add(CopilotEntry.assistant(reply.text, card: card));
  }

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
    CopilotReply? found;
    if (session != null) {
      found = await session.search(
        SearchOrdersIntent(
          status: 'submitted',
          anyName: name,
          period:
              intent.range ??
              copilotRange(CopilotRangeKind.pastDays, _clock(), days: 90),
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
    final bool opened = await openPage?.call('all_orders') ?? false;
    if (generation != _generation) return;
    final Object? card = found?.card;
    final String count = card is OrderResultsCard
        ? '${card.total} order${card.total == 1 ? ' is' : 's are'} waiting for approval.'
        : 'No orders are waiting for approval.';
    final String action = ordersViewOnly
        ? 'Order approval is view only for your role.'
        : 'I never approve orders for you: review each order there and approve it yourself.';
    _ordersShownLast = card is OrderResultsCard;
    entries.add(
      CopilotEntry.assistant(
        '$count ${opened ? 'Opened All Orders. ' : ''}$action',
        card: card,
        kind: CopilotEntryKind.refusal,
      ),
    );
  }

  Future<void> _briefRetailer(
    BriefRetailerIntent intent,
    int generation,
  ) async {
    final OrderSearchSession? session = orders;
    if (session == null) {
      _say('Retailer briefs are not available for this account.');
      return;
    }
    final CopilotReply reply = await session.briefRetailer(intent);
    if (generation != _generation) return;
    _ordersShownLast = true;
    _reply(reply);
  }

  Future<void> _rankWhy(RankWhyIntent intent, int generation) async {
    final Future<CopilotReply> Function(RankWhyIntent)? explain = explainRank;
    if (explain == null) {
      _say('Ranking explanations are not available for this account.');
      return;
    }
    final CopilotReply reply = await explain(intent);
    if (generation != _generation) return;
    _ordersShownLast = false;
    _reply(reply);
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
    final PendingStatusChange? pending = _pending;
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

const Set<String> _kAdvancedSuggestions = <String>{
  _kBriefing,
  'Explain the second item',
  'Mark it as in review',
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
    _ => _kBasicFollowUps,
  };
  return advanced
      ? all
      : all
            .where((String s) => !_kAdvancedSuggestions.contains(s))
            .toList(growable: false);
}
