import '../../utils/money_format.dart' show formatRm;
import '../../utils/order_csv.dart';
import '../../utils/order_data_utils.dart';
import '../../utils/my_team_roster.dart';
import 'copilot_dates.dart';
import 'copilot_entity_resolver.dart';
import 'copilot_grammar.dart';

class OrderWindow {
  const OrderWindow({required this.rows, this.truncated = false});
  final List<Map<String, dynamic>> rows;
  final bool truncated;
}

class CopilotReply {
  const CopilotReply(this.text, {this.card});
  final String text;
  final Object? card;
}

class OrderQuery {
  const OrderQuery({
    this.salesperson,
    this.retailer,
    required this.period,
    this.status,
  });
  final EntityRef? salesperson;
  final EntityRef? retailer;
  final CopilotRange period;

  final String? status;
}

class OrderResultSet {
  const OrderResultSet({
    required this.query,
    required this.start,
    required this.end,
    required this.readAt,
    required this.window,
    required this.rows,
    required this.truncated,
  });
  final OrderQuery query;
  final DateTime start;
  final DateTime end;
  final DateTime readAt;

  final List<Map<String, dynamic>> window;

  final List<Map<String, dynamic>> rows;
  final bool truncated;
}

class OrderResultsCard {
  const OrderResultsCard({
    required this.chips,
    required this.statusCounts,
    required this.valueText,
    required this.rows,
    required this.total,
    required this.shown,
    required this.truncated,
    required this.spokenSummary,
  });

  final List<String> chips;

  final Map<String, int> statusCounts;
  final String valueText;

  final List<String> rows;
  final int total;
  final int shown;
  final bool truncated;
  final String spokenSummary;
}

class ChoiceCard {
  const ChoiceCard({required this.prompt, required this.choices});
  final String prompt;

  final List<String> choices;
}

class ExportCard {
  const ExportCard({
    required this.rowCount,
    required this.label,
    required this.filename,
    this.truncatedWarning,
  });
  final int rowCount;
  final String label;
  final String filename;
  final String? truncatedWarning;
}

class PendingExport {
  const PendingExport({
    required this.set,
    required this.filename,
    required this.expiresAt,
  });
  final OrderResultSet set;
  final String filename;
  final DateTime expiresAt;
}

typedef ReadOrderWindow =
    Future<OrderWindow> Function(DateTime start, DateTime end);
typedef CountWaitingOrders = Future<int> Function();
typedef LoadSalespeople = Future<List<EntityRef>> Function();
typedef DownloadCsv = bool Function(String filename, String csv);
typedef RecordExport =
    Future<void> Function(OrderResultSet set, String filename);

const String _copilotNotFoundPrefix = "I can't find";

String copilotNotFound(String spoken) =>
    "$_copilotNotFoundPrefix \"$spoken\" among the records your role can see.";

bool isCopilotNotFound(String text) => text.startsWith(_copilotNotFoundPrefix);

class _Tally {
  _Tally(this.name);
  final String name;
  double amount = 0;
  int quantity = 0;
  int orders = 0;
}

const int kOrderRowsShown = 10;
const int kChoiceLimit = 5;
const Duration kOrderWindowReuse = Duration(minutes: 5);
const Duration kExportConfirmWindow = Duration(seconds: 60);

class _Todo {
  const _Todo(this.kind, this.spoken);
  final EntityKind? kind;
  final String spoken;
}

class _Pending {
  const _Pending({
    required this.period,
    required this.status,
    required this.salesperson,
    required this.retailer,
    required this.todo,
  });
  final CopilotRange period;
  final String? status;
  final EntityRef? salesperson;
  final EntityRef? retailer;
  final List<_Todo> todo;
}

class OrderSearchSession {
  OrderSearchSession({
    required this.readWindow,
    required this.loadSalespeople,
    required this.download,
    required this.recordExport,
    required this.scopeNote,
    this.countWaiting,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ReadOrderWindow readWindow;
  final LoadSalespeople loadSalespeople;
  final DownloadCsv download;
  final RecordExport recordExport;
  final CountWaitingOrders? countWaiting;

  final String? scopeNote;
  final DateTime Function() _clock;

  OrderResultSet? _current;
  List<EntityRef>? _choices;
  _Pending? _pending;
  PendingExport? _pendingExport;

  bool _briefNext = false;
  List<EntityRef>? _salespeople;
  OrderWindow? _window;
  DateTime? _windowStart;
  DateTime? _windowEnd;
  DateTime? _windowReadAt;

  OrderResultSet? get current => _current;
  List<EntityRef>? get choices => _choices;
  PendingExport? get pendingExport => _pendingExport;

  Map<String, dynamic>? shownOrder(int position) {
    final List<Map<String, dynamic>>? rows = _current?.rows;
    if (rows == null || position < 1) return null;
    if (position > kOrderRowsShown || position > rows.length) return null;
    return rows[position - 1];
  }

  void reset() {
    _current = null;
    dropPending();
  }

  void dropPending() {
    _choices = null;
    _pending = null;
    _pendingExport = null;
  }

  Future<CopilotReply> briefRetailer(BriefRetailerIntent intent) => search(
    SearchOrdersIntent(retailer: intent.name, period: intent.period),
    brief: true,
  );

  Future<CopilotReply> search(
    SearchOrdersIntent intent, {
    bool brief = false,
  }) async {
    dropPending();
    _briefNext = brief;
    final OrderQuery? frame = _current?.query;
    final bool waitingState =
        intent.status == 'submitted' && intent.period == null && !intent.refine;
    final CopilotRange period =
        intent.period ??
        (waitingState
            ? copilotRange(CopilotRangeKind.allTime, _clock())
            : frame?.period.kind == CopilotRangeKind.allTime && !intent.refine
            ? null
            : frame?.period) ??
        copilotRange(CopilotRangeKind.thisMonth, _clock());
    final String? status = intent.status ?? frame?.status;
    final bool keep = intent.refine;
    final List<_Todo> todo = <_Todo>[
      if (intent.salesperson != null)
        _Todo(EntityKind.salesperson, intent.salesperson!),
      if (intent.retailer != null) _Todo(EntityKind.retailer, intent.retailer!),
      if (intent.anyName != null) _Todo(null, intent.anyName!),
    ];
    final bool newSalesperson = todo.any(
      (_Todo t) => t.kind == EntityKind.salesperson,
    );
    final bool newRetailer = todo.any(
      (_Todo t) => t.kind == EntityKind.retailer,
    );
    return _run(
      period: period,
      status: status,
      salesperson: keep && !newSalesperson ? frame?.salesperson : null,
      retailer: keep && !newRetailer ? frame?.retailer : null,
      todo: todo,
    );
  }

  Future<CopilotReply?> pick(int position) async {
    final List<EntityRef>? options = _choices;
    final _Pending? pending = _pending;
    if (options == null || pending == null) return null;
    if (position < 1 || position > options.length) {
      return CopilotReply('Choose a number from 1 to ${options.length}.');
    }
    return _choose(options[position - 1], pending);
  }

  Future<CopilotReply?> pickByName(String spoken) async {
    final List<EntityRef>? options = _choices;
    final _Pending? pending = _pending;
    if (options == null || pending == null) return null;
    final Resolution r = resolveEntity(spoken, options);
    return r is One ? _choose(r.entity, pending) : null;
  }

  Future<CopilotReply> _choose(EntityRef chosen, _Pending p) {
    _choices = null;
    _pending = null;
    final bool person = chosen.kind == EntityKind.salesperson;
    return _run(
      period: p.period,
      status: p.status,
      salesperson: person ? chosen : p.salesperson,
      retailer: person ? p.retailer : chosen,
      todo: p.todo,
    );
  }

  Future<CopilotReply> _run({
    required CopilotRange period,
    required String? status,
    required EntityRef? salesperson,
    required EntityRef? retailer,
    required List<_Todo> todo,
  }) async {
    final DateTime now = _clock();
    final OrderWindow window;
    try {
      window = await _windowFor(period, now);
    } on StateError catch (e) {
      return CopilotReply(e.message);
    } catch (_) {
      return const CopilotReply(
        'I could not read the orders right now. Try again, or open All Orders.',
      );
    }
    if (window.rows.isEmpty && scopeNote != null) {
      return CopilotReply(scopeNote!);
    }

    final List<String> notes = <String>[];
    if (todo.isNotEmpty) {
      _salespeople ??= await _loadSalespeople();
      final List<EntityRef> pool = <EntityRef>[
        ..._salespeople!,
        ...entityPoolFromOrders(window.rows, _salespeople!),
      ];
      for (int i = 0; i < todo.length; i++) {
        final _Todo t = todo[i];
        Resolution r = resolveEntity(t.spoken, _ofKind(pool, t.kind));
        if (r is None && t.kind != null) {
          final EntityKind other = t.kind == EntityKind.salesperson
              ? EntityKind.retailer
              : EntityKind.salesperson;
          final Resolution fallback = resolveEntity(
            t.spoken,
            _ofKind(pool, other),
          );
          if (fallback is! None) {
            r = fallback;
            notes.add(
              'I could not find a ${_kindWord(t.kind)} called "${t.spoken}", '
              'so I used the ${_kindWord(other)}.',
            );
          }
        }
        switch (r) {
          case One(:final EntityRef entity):
            if (entity.kind == EntityKind.salesperson) {
              salesperson = entity;
            } else {
              retailer = entity;
            }
          case Many(:final List<EntityRef> entities):
            final List<EntityRef> options = entities
                .take(kChoiceLimit)
                .toList(growable: false);
            _choices = options;
            _pending = _Pending(
              period: period,
              status: status,
              salesperson: salesperson,
              retailer: retailer,
              todo: todo.sublist(i + 1),
            );
            return CopilotReply(
              'Which one do you mean by "${t.spoken}"? '
              'Say a number from 1 to ${options.length}.',
              card: ChoiceCard(
                prompt: 'Which one do you mean by "${t.spoken}"?',
                choices: <String>[
                  for (int n = 0; n < options.length; n++)
                    '${n + 1}. ${options[n].name}'
                        '${options[n].code.isEmpty ? '' : ' · ${options[n].code}'}'
                        ' · ${options[n].kindLabel}',
                ],
              ),
            );
          case None():
            return CopilotReply(copilotNotFound(t.spoken));
        }
      }
    }

    final OrderQuery query = OrderQuery(
      salesperson: salesperson,
      retailer: retailer,
      period: period,
      status: status,
    );
    final bool waitingAll =
        period.kind == CopilotRangeKind.allTime &&
        status == 'submitted' &&
        salesperson == null &&
        retailer == null &&
        countWaiting != null;
    final List<Map<String, dynamic>> matched = _filter(window.rows, query);
    final List<Map<String, dynamic>> rows = waitingAll
        ? matched.where(isPendingApprovalOrder).toList(growable: false)
        : matched;
    final OrderResultSet set = OrderResultSet(
      query: query,
      start: period.start,
      end: period.end,
      readAt: _windowReadAt ?? now,
      window: window.rows,
      rows: rows,
      truncated: window.truncated,
    );
    _current = set;
    int? waitingTotal;
    if (waitingAll) {
      try {
        waitingTotal = await countWaiting!();
      } catch (_) {
        waitingTotal = null;
      }
    }
    final CopilotReply reply = _describe(set, now, notes, waitingTotal);
    if (!_briefNext) return reply;
    _briefNext = false;
    return set.rows.isEmpty || retailer == null
        ? reply
        : CopilotReply(_briefText(set, now, notes), card: reply.card);
  }

  String _briefText(OrderResultSet set, DateTime now, List<String> notes) {
    int active = 0, waiting = 0;
    double value = 0, waitingValue = 0;
    final Map<String, int> bySalesperson = <String, int>{};
    for (final Map<String, dynamic> o in set.rows) {
      final String who = '${o['salesmanName'] ?? o['salesman_name'] ?? ''}'
          .trim();
      if (who.isNotEmpty) bySalesperson[who] = (bySalesperson[who] ?? 0) + 1;
      if (isRejectedOrder(o)) continue;
      active++;
      value += orderRevenue(o);
      if (_isSubmitted(o)) {
        waiting++;
        waitingValue += orderRevenue(o);
      }
    }
    final Map<String, dynamic> last = set.rows.first;
    final String lastWho =
        '${last['salesmanName'] ?? last['salesman_name'] ?? ''}'.trim();
    final List<MapEntry<String, int>> people = bySalesperson.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final int rejected = set.rows.length - active;
    return <String>[
      'Brief · ${_entityLabel(set.query.retailer!)} · '
          '${set.query.period.label}',
      '${_plural(set.rows.length, 'order', 'orders')}, ${formatRm(value)}'
          '${active == 0 ? '' : ' (average ${formatRm(value / active)})'}'
          '${rejected > 0 ? ', ${_group(rejected)} rejected and left out of the value' : ''}.',
      'Latest: ${_rowLine(1, last).substring(3)}'
          '${lastWho.isEmpty ? '' : ' · $lastWho'}',
      if (people.isNotEmpty)
        'Ordered by: ${people.take(3).map((e) => '${e.key} (${e.value})').join(', ')}.',
      if (waiting > 0)
        'Waiting for approval: ${_plural(waiting, 'order', 'orders')}, '
            '${formatRm(waitingValue)}.',
      if (set.truncated)
        'At least ${_group(set.window.length)} orders in this period; '
            'these numbers cover the newest ${_group(set.window.length)}.',
      ...notes,
    ].join('\n');
  }

  Future<List<EntityRef>> _loadSalespeople() async {
    try {
      return await loadSalespeople();
    } catch (_) {
      return const <EntityRef>[];
    }
  }

  static Iterable<EntityRef> _ofKind(List<EntityRef> pool, EntityKind? kind) =>
      kind == null ? pool : pool.where((EntityRef e) => e.kind == kind);

  static String _kindWord(EntityKind? k) =>
      k == EntityKind.retailer ? 'retailer' : 'salesperson';

  Future<bool> knowsSalesperson(String spoken) async {
    _salespeople ??= await _loadSalespeople();
    return resolveEntity(spoken, _salespeople!) is! None;
  }

  Future<CopilotReply> top(TopIntent intent) async {
    dropPending();
    final DateTime now = _clock();
    final OrderWindow window;
    try {
      window = await _windowFor(intent.range, now);
    } on StateError catch (e) {
      return CopilotReply(e.message);
    } catch (_) {
      return const CopilotReply(
        'I could not read the orders right now. Try again, or open All Orders.',
      );
    }
    if (window.rows.isEmpty && scopeNote != null) {
      return CopilotReply(scopeNote!);
    }
    final Map<String, _Tally> tallies = <String, _Tally>{};
    for (final Map<String, dynamic> o in window.rows) {
      if (isRejectedOrder(o)) continue;
      if (intent.retailers) {
        final String name = '${o['retailerName'] ?? o['retailer_name'] ?? ''}'
            .trim();
        if (name.isEmpty) continue;
        final String id = '${o['retailerId'] ?? o['retailer_id'] ?? ''}'
            .trim()
            .toLowerCase();
        final _Tally t = tallies.putIfAbsent(
          id.isNotEmpty ? id : normaliseEntityName(name),
          () => _Tally(name),
        );
        t.amount += orderRevenue(o);
        t.orders++;
      } else {
        for (final Map<String, dynamic> item in authoritativeOrderItems(o)) {
          final String name = '${item['productName'] ?? item['name'] ?? ''}'
              .trim();
          final int qty = itemQuantity(item);
          if (name.isEmpty || qty <= 0) continue;
          final String id = '${item['productId'] ?? ''}'.trim().toLowerCase();
          final _Tally t = tallies.putIfAbsent(
            id.isNotEmpty ? id : normaliseEntityName(name),
            () => _Tally(name),
          );
          t.quantity += qty;
          t.orders++;
        }
      }
    }
    final String what = intent.retailers ? 'retailers' : 'products';
    if (tallies.isEmpty) {
      return CopilotReply(
        'No orders ${intent.range.name}, so there are no top $what.',
      );
    }
    final List<_Tally> ranked = tallies.values.toList()
      ..sort((_Tally a, _Tally b) {
        final int c = intent.retailers
            ? b.amount.compareTo(a.amount)
            : b.quantity.compareTo(a.quantity);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
    final List<String> lines = <String>[
      'Top $what · ${intent.range.label} · by '
          '${intent.retailers ? 'order value' : 'boxes sold'}, rejected orders left out',
      for (int i = 0; i < ranked.length && i < intent.limit; i++)
        intent.retailers
            ? '${i + 1}. ${ranked[i].name} · ${formatRm(ranked[i].amount)} · '
                  '${_plural(ranked[i].orders, 'order', 'orders')}'
            : '${i + 1}. ${ranked[i].name} · '
                  '${_plural(ranked[i].quantity, 'box', 'boxes')} · '
                  '${_plural(ranked[i].orders, 'order', 'orders')}',
      if (window.truncated)
        'At least ${_group(window.rows.length)} orders in this period; '
            'this ranking covers the newest ${_group(window.rows.length)}.',
    ];
    return CopilotReply(lines.join('\n'));
  }

  Future<OrderWindow> _windowFor(CopilotRange range, DateTime now) async {
    final OrderWindow? cached = _window;
    final DateTime? at = _windowReadAt;
    if (cached != null &&
        at != null &&
        _windowStart == range.start &&
        _windowEnd == range.end &&
        now.difference(at) < kOrderWindowReuse) {
      return cached;
    }
    final OrderWindow read = await readWindow(range.start, range.end);
    final OrderWindow window = OrderWindow(
      rows: read.rows
          .where((Map<String, dynamic> r) => !isDemoRow(r))
          .toList(growable: false),
      truncated: read.truncated,
    );
    _window = window;
    _windowStart = range.start;
    _windowEnd = range.end;
    _windowReadAt = now;
    return window;
  }

  static bool _statusMatches(Map<String, dynamic> row, String? status) {
    if (status == null) return true;
    final bool rejected = isRejectedOrder(row);
    switch (status) {
      case 'rejected':
        return rejected;
      case 'approved':
        return !rejected && orderStatus(row) == 'approved';
      case 'submitted':
        return !rejected && _isSubmitted(row);
    }
    return true;
  }

  static bool _isSubmitted(Map<String, dynamic> row) => const <String>{
    '',
    'submitted',
    'pending',
    'pending_approval',
    'held_for_review',
  }.contains(orderStatus(row));

  static List<Map<String, dynamic>> _filter(
    List<Map<String, dynamic>> window,
    OrderQuery q,
  ) {
    final List<Map<String, dynamic>> rows = window.where((
      Map<String, dynamic> o,
    ) {
      if (q.salesperson != null && !orderMatchesEntity(q.salesperson!, o)) {
        return false;
      }
      if (q.retailer != null && !orderMatchesEntity(q.retailer!, o)) {
        return false;
      }
      return _statusMatches(o, q.status);
    }).toList();
    rows.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final DateTime? da = orderDateFromRow(a);
      final DateTime? db = orderDateFromRow(b);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
    return rows;
  }

  static String _periodName(CopilotRange p, DateTime now) => p.name;

  static String _group(int n) {
    final String s = n.toString();
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return out.toString();
  }

  static String _plural(int n, String one, String many) =>
      '${_group(n)} ${n == 1 ? one : many}';

  static String _entityLabel(EntityRef e) =>
      e.code.isEmpty ? e.name : '${e.name} (${e.code})';

  static const List<String> _days = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  static const List<String> _months = <String>[
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

  static String _rowLine(int n, Map<String, dynamic> o) {
    final DateTime? when = orderDateFromRow(o);
    String date = '—';
    if (when != null) {
      final DateTime kl = malaysiaWallTime(when);
      date =
          '${_days[kl.weekday - 1]} ${kl.day} ${_months[kl.month - 1]} '
          '${kl.hour.toString().padLeft(2, '0')}:'
          '${kl.minute.toString().padLeft(2, '0')}';
    }
    final String id = '${o['orderId'] ?? o['docId'] ?? ''}'.trim();
    final String retailer = '${o['retailerName'] ?? o['retailer_name'] ?? ''}'
        .trim();
    final String status = orderStatus(o);
    return '$n. ${id.isEmpty ? 'Order' : id} · '
        '${retailer.isEmpty ? 'Unknown retailer' : retailer} · $date · '
        '${formatRm(orderRevenue(o))} · ${status.isEmpty ? 'submitted' : status}';
  }

  CopilotReply _describe(
    OrderResultSet set,
    DateTime now,
    List<String> notes, [
    int? waitingTotal,
  ]) {
    final OrderQuery q = set.query;
    final String periodLabel = q.period.label;
    final String periodName = _periodName(q.period, now);
    final String extra = notes.isEmpty ? '' : '\n${notes.join(' ')}';
    if (waitingTotal != null) {
      final int listed = set.rows.length < kOrderRowsShown
          ? set.rows.length
          : kOrderRowsShown;
      return CopilotReply(
        waitingTotal == 0
            ? 'No orders are waiting for approval ($periodLabel).$extra'
            : '${_group(waitingTotal)} waiting for approval ($periodLabel).'
                  '${listed == 0 ? '' : ' Newest $listed shown.'}$extra',
        card: OrderResultsCard(
          chips: <String>[periodLabel, 'submitted'],
          statusCounts: <String, int>{
            if (waitingTotal > 0) 'submitted': waitingTotal,
          },
          valueText: '',
          rows: <String>[
            for (int i = 0; i < listed; i++) _rowLine(i + 1, set.rows[i]),
          ],
          total: waitingTotal,
          shown: listed,
          truncated: false,
          spokenSummary:
              '${_plural(waitingTotal, 'order', 'orders')} waiting for approval.',
        ),
      );
    }
    final String truncatedText = set.truncated
        ? 'At least ${_group(set.window.length)} orders — showing the newest '
              '${_group(set.window.length)}. Narrow the period for a complete list.'
        : '';

    if (set.rows.isEmpty) {
      final String from = q.salesperson == null
          ? ''
          : ' from ${q.salesperson!.name}';
      final String at = q.retailer == null ? '' : ' for ${q.retailer!.name}';
      final String text =
          'No ${q.status == null ? '' : '${q.status} '}orders$from$at '
          '$periodName.';
      return CopilotReply(
        '$text${set.truncated ? '\n$truncatedText' : ''}$extra',
      );
    }

    int submitted = 0, approved = 0, rejected = 0, other = 0;
    double value = 0;
    for (final Map<String, dynamic> o in set.rows) {
      if (isRejectedOrder(o)) {
        rejected++;
      } else {
        value += orderRevenue(o);
        if (_isSubmitted(o)) {
          submitted++;
        } else if (orderStatus(o) == 'approved') {
          approved++;
        } else {
          other++;
        }
      }
    }
    final Map<String, int> counts = <String, int>{
      if (submitted > 0) 'submitted': submitted,
      if (approved > 0) 'approved': approved,
      if (rejected > 0) 'rejected': rejected,
      if (other > 0) 'other': other,
    };
    final String who = <String>[
      if (q.salesperson != null) _entityLabel(q.salesperson!),
      if (q.retailer != null) _entityLabel(q.retailer!),
    ].join(', ');
    final String countText = counts.entries
        .map((MapEntry<String, int> e) => '${_group(e.value)} ${e.key}')
        .join(', ');
    final String valueText =
        'Value ${formatRm(value)}${rejected > 0 ? ' (rejected excluded)' : ''}.';
    final String text =
        '${_plural(set.rows.length, 'order', 'orders')} · '
        '${who.isEmpty ? 'all salespeople and retailers' : who} · '
        '$periodLabel · ${q.status == null ? 'all statuses' : '${q.status} only'}. '
        '$countText. $valueText';

    final int shown = set.rows.length < kOrderRowsShown
        ? set.rows.length
        : kOrderRowsShown;
    final String spokenWho = <String>[
      if (q.salesperson != null) q.salesperson!.name,
      if (q.retailer != null) q.retailer!.name,
    ].join(' and ');
    return CopilotReply(
      '$text${set.truncated ? '\n$truncatedText' : ''}$extra',
      card: OrderResultsCard(
        chips: <String>[
          if (q.salesperson != null) _entityLabel(q.salesperson!),
          if (q.retailer != null) _entityLabel(q.retailer!),
          periodLabel,
          if (q.status != null) q.status!,
        ],
        statusCounts: counts,
        valueText: formatRm(value),
        rows: <String>[
          for (int i = 0; i < shown; i++) _rowLine(i + 1, set.rows[i]),
        ],
        total: set.rows.length,
        shown: shown,
        truncated: set.truncated,
        spokenSummary:
            '${_plural(set.rows.length, 'order', 'orders')}'
            '${spokenWho.isEmpty ? '' : ' from $spokenWho'} $periodName.',
      ),
    );
  }

  CopilotReply offerExport() {
    _pendingExport = null;
    final OrderResultSet? set = _current;
    if (set == null || set.rows.isEmpty) {
      return const CopilotReply(
        'There are no orders to export. Search for orders first.',
      );
    }
    final DateTime now = _clock();
    final String filename = _filename(set, now);
    _pendingExport = PendingExport(
      set: set,
      filename: filename,
      expiresAt: now.add(kExportConfirmWindow),
    );
    final OrderQuery q = set.query;
    final String label = <String>[
      if (q.salesperson != null) q.salesperson!.name,
      if (q.retailer != null) q.retailer!.name,
      _periodName(q.period, now),
      if (q.status != null) q.status!,
    ].join(', ');
    final String? warning = set.truncated
        ? 'This file has the newest ${_group(set.window.length)} orders only; '
              'the period has more.'
        : null;
    return CopilotReply(
      'Download ${_plural(set.rows.length, 'order', 'orders')} ($label) as CSV?'
      '${warning == null ? '' : '\n$warning'}',
      card: ExportCard(
        rowCount: set.rows.length,
        label: label,
        filename: filename,
        truncatedWarning: warning,
      ),
    );
  }

  Future<CopilotReply> confirmExport() async {
    final PendingExport? pending = _pendingExport;
    _pendingExport = null;
    if (pending == null) {
      return const CopilotReply('There is no export waiting.');
    }
    if (!_clock().isBefore(pending.expiresAt)) {
      return const CopilotReply(
        'That export expired. Say "export these" again.',
      );
    }
    final bool ok = download(
      pending.filename,
      buildOrdersCsv(pending.set.rows),
    );
    if (!ok) {
      return const CopilotReply('Export works only in the web dashboard.');
    }
    try {
      await recordExport(pending.set, pending.filename);
    } catch (_) {}
    return CopilotReply(
      'Downloaded ${_plural(pending.set.rows.length, 'order', 'orders')} as '
      '${pending.filename}.',
    );
  }

  static String _slug(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  static String _filename(OrderResultSet set, DateTime now) {
    final DateTime kl = malaysiaWallTime(now);
    String two(int n) => n.toString().padLeft(2, '0');
    final String stamp =
        '${kl.year.toString().padLeft(4, '0')}${two(kl.month)}${two(kl.day)}'
        '_${two(kl.hour)}${two(kl.minute)}';
    final OrderQuery q = set.query;
    final String period = _slug(_periodName(q.period, now));
    final String tail =
        '_$period${q.status == null ? '' : '_${q.status}'}_$stamp'
        '${set.truncated ? '_partial' : ''}.csv';
    String who = <String>[
      if (q.salesperson != null) _slug(q.salesperson!.name),
      if (q.retailer != null) _slug(q.retailer!.name),
    ].where((String s) => s.isNotEmpty).join('_');
    if (who.isEmpty) who = 'all';
    final int room = 80 - 'orders_'.length - tail.length;
    if (who.length > room) who = who.substring(0, room);
    return 'orders_$who$tail';
  }
}
