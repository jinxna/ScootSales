import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../../app/build_flags.dart';
import '../../../../models/action_centre_item.dart';
import '../../../../models/user_profile.dart';
import '../../../../repositories/cms_repository.dart';
import '../../../../security/team_scope.dart';
import '../../../../services/dashboard_preferences_service.dart';
import '../../../../utils/collection_rows.dart';
import '../../../../utils/forecast_catalogue_provenance.dart';
import '../../../../utils/order_data_utils.dart';
import '../../../../utils/visit_data_utils.dart';
import '../../../../widgets/admin_setup_checklist.dart';
import 'home_decisions.dart';
import 'home_parts.dart';
import 'overview_metrics.dart';

const int _forecastAlertRowLimit = 500;

Stream<List<Map<String, dynamic>>> watchForecastAlertRows(
  CmsRepository repository,
) => repository.watchCollection(
  'demand_forecasts',
  orderBy: 'periodStart',
  descending: true,
  limit: _forecastAlertRowLimit,
  coverageProbe: false,
);

({int count, bool complete}) forecastAlertsTile(
  List<Map<String, dynamic>> rows,
) {
  final List<Map<String, dynamic>> counted = rows
      .where((Map<String, dynamic> row) => !isDemoRow(row))
      .toList(growable: false);
  return (
    count: forecastRestockSignalCount(counted),
    complete:
        (collectionRowsComplete(rows) ||
            collectionRowsCoverage(rows) != null) &&
        forecastWindowCoversLatestPeriod(
          rows,
          counted,
          limit: _forecastAlertRowLimit,
        ),
  );
}

enum _DashboardTimeframe { today, week, month }

class _DashCardSpec {
  const _DashCardSpec(this.id, this.label);
  final String id;
  final String label;
}

class _Need {
  const _Need({
    required this.count,
    required this.tone,
    required this.one,
    required this.many,
    required this.detail,
    required this.action,
    required this.pageKey,
    this.primary = false,
  });

  final int count;
  final ScootTone tone;
  final String one;
  final String many;
  final String detail;
  final String action;
  final String pageKey;
  final bool primary;
}

class _FieldPerson {
  _FieldPerson(this.key, this.name);
  final String key;
  String name;
  int visits = 0;
  int orders = 0;
  DateTime? last;
  DateTime? lastOrder;
}

class RoleHomeSection extends StatefulWidget {
  const RoleHomeSection({
    super.key,
    required this.repository,
    required this.currentUser,
    required this.actionItemsFuture,
    required this.onRetryActions,
    this.onNavigateRequested,
  });

  final CmsRepository repository;
  final UserProfile currentUser;
  final Future<List<ActionCentreItem>> actionItemsFuture;
  final VoidCallback onRetryActions;
  final ValueChanged<String>? onNavigateRequested;

  @override
  State<RoleHomeSection> createState() => _RoleHomeSectionState();
}

class _RoleHomeSectionState extends State<RoleHomeSection> {
  static const List<_DashCardSpec> _kAllCards = <_DashCardSpec>[
    _DashCardSpec('orders_today', 'Orders Today'),
    _DashCardSpec('pending_orders', 'Pending / Submitted Orders'),
    _DashCardSpec('active_salesmen', 'Active Salesmen'),
    _DashCardSpec('visits_today', 'Completed Visits'),
    _DashCardSpec('revenue', 'Operational order value'),
    _DashCardSpec('action_items', 'Action Items (top 3)'),
    _DashCardSpec('forecast_alerts', 'Forecast Alerts'),
    _DashCardSpec('overdue_retailers', 'Overdue Retailers'),
    _DashCardSpec('salesman_summary', 'Salesman Performance Summary'),
  ];

  bool get _isAdmin => widget.currentUser.isAdmin;
  bool get _isSupervisor => widget.currentUser.isSupervisor;
  bool get _isBranchManager => widget.currentUser.isBranchManager;

  List<_DashCardSpec> get _kCards => _kAllCards
      .where(
        (_DashCardSpec c) =>
            !(isBasicEdition && c.id == 'forecast_alerts') &&
            (_isAdmin || c.id != 'pending_orders'),
      )
      .toList(growable: false);

  List<String> get _defaultSelected => _isAdmin
      ? const <String>[
          'orders_today',
          'pending_orders',
          'active_salesmen',
          'visits_today',
          'revenue',
        ]
      : _isSupervisor
      ? const <String>[
          'orders_today',
          'visits_today',
          'active_salesmen',
          'revenue',
        ]
      : const <String>[
          'orders_today',
          'revenue',
          'visits_today',
          'active_salesmen',
        ];

  List<String> _defaultOrder() {
    final List<String> ids = _kCards.map((_DashCardSpec c) => c.id).toList();
    return <String>[
      ..._defaultSelected,
      ...ids.where((String id) => !_defaultSelected.contains(id)),
    ];
  }

  final DashboardPreferencesService _prefsService =
      DashboardPreferencesService();

  late Stream<List<Map<String, dynamic>>> _ordersStream = _watchFrameOrders();
  late Stream<int> _pendingStream = widget.repository
      .watchPendingApprovalCount();
  late Stream<List<Map<String, dynamic>>> _visitsStream = widget.repository
      .watchCollection('visit_logs', limit: 500);

  _DashboardTimeframe _timeframe = _DashboardTimeframe.today;
  late List<String> _order = _defaultOrder();
  late Set<String> _selected = _defaultSelected.toSet();

  Stream<List<Map<String, dynamic>>> _watchFrameOrders() =>
      widget.repository.watchOrdersSince(_ordersFetchStartUtc());

  void _setTimeframe(_DashboardTimeframe value) {
    _timeframe = value;
    _ordersStream = _watchFrameOrders();
  }

  void _retry() {
    setState(() {
      _ordersStream = _watchFrameOrders();
      _pendingStream = widget.repository.watchPendingApprovalCount();
      _visitsStream = widget.repository.watchCollection(
        'visit_logs',
        limit: 500,
      );
    });
    widget.onRetryActions();
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final DashboardPreferences? prefs = await _prefsService.load(
      widget.currentUser.uid ?? '',
    );
    if (!mounted || prefs == null) return;
    final List<String> validIds = _kCards
        .map((_DashCardSpec c) => c.id)
        .toList();
    final List<String> order = <String>[
      ...prefs.cardOrder.where(validIds.contains),
      ...validIds.where((String id) => !prefs.cardOrder.contains(id)),
    ];
    setState(() {
      _order = order.isEmpty ? validIds : order;
      _selected = prefs.selectedCards.where(validIds.contains).toSet();
      if (_selected.isEmpty) _selected = _defaultSelected.toSet();
      _setTimeframe(_timeframeFromString(prefs.defaultTimeframe));
    });
  }

  void _go(String pageKey) {
    if (pageKey.isNotEmpty) widget.onNavigateRequested?.call(pageKey);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _ordersStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> orders,
          ) => StreamBuilder<List<Map<String, dynamic>>>(
            stream: _visitsStream,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, dynamic>>> visits,
                ) => StreamBuilder<int>(
                  stream: _pendingStream,
                  builder:
                      (BuildContext context, AsyncSnapshot<int> pending) =>
                          _content(context, orders, visits, pending),
                ),
          ),
    );
  }

  Widget _content(
    BuildContext context,
    AsyncSnapshot<List<Map<String, dynamic>>> orders,
    AsyncSnapshot<List<Map<String, dynamic>>> visits,
    AsyncSnapshot<int> pending,
  ) {
    final List<Widget> tiles = <Widget>[
      for (final String id in _order)
        if (_selected.contains(id) && _kCards.any((c) => c.id == id))
          _tile(id, orders, visits, pending),
    ];
    final bool loading =
        (!orders.hasData && !orders.hasError) ||
        (!visits.hasData && !visits.hasError);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double width = box.maxWidth;
        final bool wide = width >= 1000;
        final Widget tileGrid = tiles.isEmpty
            ? _emptyTilesHint()
            : HomeTileGrid(
                tiles: tiles,
                columns: _isAdmin
                    ? (width >= 1000 ? 5 : (width >= 640 ? 2 : 1))
                    : _isSupervisor
                    ? 2
                    : (width >= 1000 ? 4 : (width >= 640 ? 2 : 1)),
              );
        final Widget needs = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            HomeDecisionsCard(
              currentUser: widget.currentUser,
              title: _isBranchManager
                  ? 'Needs a decision in your branch'
                  : 'Needs your decision',
              onNavigate: _go,
            ),
            const SizedBox(height: ScootSpace.blockGap),
            _needsCard(pending),
          ],
        );
        final DateTime nowKl = DateTime.now().toUtc().add(
          const Duration(hours: 8),
        );
        final List<Map<String, dynamic>> todayVisits = _todayVisits(
          visits.data ?? const <Map<String, dynamic>>[],
        );
        final List<Map<String, dynamic>> todayOrders = _todayOrders(
          orders.data ?? const <Map<String, dynamic>>[],
        );
        final Widget visitsFailed = visits.hasError
            ? ScootErrorState(onRetry: _retry)
            : const SizedBox.shrink();
        final bool visitsLoading = !visits.hasData && !visits.hasError;

        final List<Widget> body = <Widget>[
          _header(nowKl),
          if (loading) ...<Widget>[
            const SizedBox(height: 12),
            HomeStillLoading(onRetry: _retry),
          ],
          _coverage(orders, visits),
          if (_isAdmin && widget.onNavigateRequested != null) ...<Widget>[
            const SizedBox(height: ScootSpace.blockGap),
            AdminSetupChecklist(
              currentUser: widget.currentUser,
              onNavigate: widget.onNavigateRequested!,
            ),
          ],
          const SizedBox(height: ScootSpace.blockGap),
        ];

        if (_isAdmin) {
          body.addAll(<Widget>[
            tileGrid,
            const SizedBox(height: ScootSpace.blockGap),
            _twoColumn(wide, 7, needs, 5, _adminFieldCard(visits, todayVisits, visitsLoading, visitsFailed)),
          ]);
        } else if (_isSupervisor) {
          body.addAll(<Widget>[
            _twoColumn(wide, 7, needs, 5, tileGrid, crossStart: true),
            const SizedBox(height: ScootSpace.blockGap),
            _twoColumn(
              wide,
              7,
              _timelineCard(orders, visits, todayOrders, todayVisits),
              5,
              _teamCard(todayVisits, todayOrders, visitsLoading),
            ),
          ]);
        } else {
          body.addAll(<Widget>[
            tileGrid,
            const SizedBox(height: ScootSpace.blockGap),
            _twoColumn(
              wide,
              6,
              needs,
              6,
              _branchFieldCard(todayVisits, todayOrders, visitsLoading, visits.hasError),
            ),
            const SizedBox(height: ScootSpace.blockGap),
            _latestVisitsCard(todayVisits, visitsLoading, visits.hasError),
          ]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: body,
        );
      },
    );
  }

  Widget _twoColumn(
    bool wide,
    int leftFlex,
    Widget left,
    int rightFlex,
    Widget right, {
    bool crossStart = true,
  }) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          left,
          const SizedBox(height: ScootSpace.blockGap),
          right,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(flex: leftFlex, child: left),
        const SizedBox(width: ScootSpace.blockGap),
        Expanded(flex: rightFlex, child: right),
      ],
    );
  }

  Widget _header(DateTime nowKl) {
    final UserProfile user = widget.currentUser;
    final String first = user.name.trim().isEmpty
        ? 'there'
        : user.name.trim().split(RegExp(r'\s+')).first;
    final String greeting = '${homeGreeting(nowKl.hour)}, $first';
    final String date = homeDateLabel(nowKl);
    final String title = _isAdmin
        ? greeting
        : _isSupervisor
        ? 'Team overview'
        : 'Branch overview';
    final String fact = _isAdmin
        ? '$date · ${'All branches'}'
        : _isSupervisor
        ? date
        : '$date · $greeting';
    final Widget switcher = HomePeriodSwitch<_DashboardTimeframe>(
      values: _DashboardTimeframe.values,
      labels: const <String>['Today', 'This week', 'This month'],
      selected: _timeframe,
      onChanged: (_DashboardTimeframe v) => setState(() => _setTimeframe(v)),
    );
    final Widget edit = _isAdmin
        ? IconButton.outlined(
            tooltip: 'Edit dashboard',
            onPressed: _openEditor,
            icon: const Icon(ScootIcons.settings, size: 18),
          )
        : OutlinedButton(
            onPressed: _openEditor,
            child: Text(_isSupervisor ? 'Edit layout' : 'Customise'),
          );
    return SizedBox(
      width: double.infinity,
      child: ScootPageHeader(
        title: title,
        fact: fact,
        actions: <Widget>[switcher, edit],
      ),
    );
  }

  Widget _coverage(
    AsyncSnapshot<List<Map<String, dynamic>>> orders,
    AsyncSnapshot<List<Map<String, dynamic>>> visits,
  ) {
    final List<String> notes = <String>[
      if (orders.hasData && !_coversFrame(orders.data))
        'Orders in this period are more than the newest rows the page reads. Totals are held back.',
      if (visits.hasData && !_coversFrame(visits.data))
        'Visits in this period are more than the newest 500 rows the page reads. Totals are held back.',
      if (visits.hasData &&
          _coversFrame(visits.data) &&
          !_locationsCoverFrame(visits.data))
        'Location points in this period are more than the newest 500 rows the page reads. Active salespeople and average visit figures are held back.',
    ];
    if (notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ScootNotice(
        tone: ScootTone.neutral,
        title: 'Part of the data',
        message: notes.join(' '),
      ),
    );
  }

  Widget _emptyTilesHint() {
    return ScootCard(
      child: Row(
        children: <Widget>[
          const Expanded(
            child: Text(
              'No cards are on. Use the edit button to add some.',
            ),
          ),
          OutlinedButton(onPressed: _openEditor, child: const Text('Add cards')),
        ],
      ),
    );
  }

  String _periodWord() => switch (_timeframe) {
    _DashboardTimeframe.today => 'today',
    _DashboardTimeframe.week => 'this week',
    _DashboardTimeframe.month => 'this month',
  };

  Widget _tile(
    String id,
    AsyncSnapshot<List<Map<String, dynamic>>> orders,
    AsyncSnapshot<List<Map<String, dynamic>>> visits,
    AsyncSnapshot<int> pending,
  ) {
    final List<Map<String, dynamic>> allOrders =
        orders.data ?? const <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> allVisits =
        visits.data ?? const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> live(List<Map<String, dynamic>> rows) => rows
        .where((Map<String, dynamic> o) => !isRejectedOrder(o))
        .toList(growable: false);
    HomeLoad ordersLoad() => orders.hasError
        ? HomeLoad.failed
        : orders.hasData
        ? HomeLoad.ready
        : HomeLoad.loading;
    HomeLoad visitsLoad() => visits.hasError
        ? HomeLoad.failed
        : visits.hasData
        ? HomeLoad.ready
        : HomeLoad.loading;
    final String period = _periodWord();
    final String deltaLabel = _isBranchManager
        ? 'vs prior 7 days'
        : _isSupervisor
        ? 'on the previous 7 days'
        : 'last 7 days vs the 7 before';
    switch (id) {
      case 'orders_today':
        final List<double> series = dailySeries<Map<String, dynamic>>(
          live(_scopeRows(allOrders)),
          dateOf: orderDateFromRow,
        );
        return HomeKpiTile(
          label: 'Orders $period',
          value: '${live(_ordersInFrame(allOrders)).length}',
          sub: _isBranchManager ? 'orders placed' : 'Not counting rejected orders',
          delta: halfOverHalfDelta(series),
          deltaLabel: deltaLabel,
          load: ordersLoad(),
          incomplete: orders.hasData && !_coversFrame(orders.data),
          onRetry: _retry,
        );
      case 'revenue':
        final List<double> series = dailySeries<Map<String, dynamic>>(
          live(_scopeRows(allOrders)),
          dateOf: orderDateFromRow,
          valueOf: orderRevenue,
        );
        final double revenue = live(_ordersInFrame(allOrders)).fold<double>(
          0,
          (double a, Map<String, dynamic> o) => a + orderRevenue(o),
        );
        return HomeKpiTile(
          label: 'Order value $period',
          value: _ringgit(revenue),
          sub: _isBranchManager
              ? 'Rejected and cancelled orders are not counted'
              : _isSupervisor
              ? 'Rejected, cancelled and void orders are not counted'
              : 'Not counting rejected orders',
          delta: halfOverHalfDelta(series),
          deltaLabel: deltaLabel,
          load: ordersLoad(),
          incomplete: orders.hasData && !_coversFrame(orders.data),
          onRetry: _retry,
        );
      case 'visits_today':
        final List<Map<String, dynamic>> done = _visitsInFrame(
          allVisits,
        ).where(_isCompletedVisit).toList();
        final Set<String> shops = done.map(_shopName).where((s) => s.isNotEmpty).toSet();
        return HomeKpiTile(
          label: _isAdmin ? 'Visits completed' : 'Visits completed $period',
          value: '${done.length}',
          sub: _isAdmin
              ? 'Arrival and departure logged'
              : _isBranchManager
              ? 'at ${shops.length} ${shops.length == 1 ? 'shop' : 'shops'}'
              : shops.take(2).join(', '),
          load: visitsLoad(),
          incomplete: visits.hasData && !_coversFrame(visits.data),
          onRetry: _retry,
        );
      case 'active_salesmen':
        final List<Map<String, dynamic>> inFrame = _visitsInFrame(allVisits);
        final int active = _activeKeys(inFrame).length;
        final int team = widget.currentUser.assignedSalesmanCodes.length;
        DateTime? last;
        for (final Map<String, dynamic> row in inFrame) {
          final DateTime? at = _visitMoment(row);
          if (at != null && (last == null || at.isAfter(last))) last = at;
        }
        return HomeKpiTile(
          label: _isAdmin ? 'Active salespeople' : 'Salespeople active $period',
          value: _isSupervisor && team > 0 ? '$active of $team' : '$active',
          sub: _isAdmin
              ? 'With a visit $period'
              : _isSupervisor
              ? (last == null ? 'No activity yet' : 'Last activity ${homeClock(last)}')
              : 'logged field activity',
          load: visitsLoad(),
          incomplete: visits.hasData && !_locationsCoverFrame(visits.data),
          onRetry: _retry,
        );
      case 'pending_orders':
        return HomeKpiTile(
          label: 'Waiting for approval',
          value: '${pending.data ?? 0}',
          sub: 'All open orders',
          load: pending.hasError
              ? HomeLoad.failed
              : pending.hasData
              ? HomeLoad.ready
              : HomeLoad.loading,
          onRetry: _retry,
          action: 'Review orders',
          onAction: () => _go('all_orders'),
        );
      case 'action_items':
        return _actionTile('Action items', (List<ActionCentreItem> items) {
          final int high = items
              .where((i) => i.priority.toLowerCase() == 'high')
              .length;
          return (
            '${items.length}',
            high == 0 ? 'Open suggestions' : '$high high priority',
          );
        });
      case 'forecast_alerts':
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: watchForecastAlertRows(widget.repository),
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<Map<String, dynamic>>> snap,
              ) {
                final ({int count, bool complete}) alerts = forecastAlertsTile(
                  snap.data ?? const <Map<String, dynamic>>[],
                );
                return HomeKpiTile(
                  label: 'Forecast Alerts',
                  value: '${alerts.count}',
                  sub: 'forecast changes',
                  load: snap.hasError
                      ? HomeLoad.failed
                      : snap.hasData
                      ? HomeLoad.ready
                      : HomeLoad.loading,
                  incomplete: snap.hasData && !alerts.complete,
                  onRetry: _retry,
                );
              },
        );
      case 'overdue_retailers':
        return _actionTile('Overdue Retailers', (List<ActionCentreItem> items) {
          final int count = items
              .where((i) => i.category.toLowerCase() == 'retailer visit')
              .length;
          return ('$count', 'Retailer Visit');
        });
      case 'salesman_summary':
        final List<Map<String, dynamic>> inFrame = _visitsInFrame(allVisits);
        final int completed = inFrame.where(_isCompletedVisit).length;
        final int salesmen = _activeKeys(inFrame).length;
        return HomeKpiTile(
          label: 'Avg Visits / Salesman',
          value: salesmen == 0 ? '0' : (completed / salesmen).toStringAsFixed(1),
          sub: 'team average',
          load: visitsLoad(),
          incomplete: visits.hasData && !_locationsCoverFrame(visits.data),
          onRetry: _retry,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _actionTile(
    String label,
    (String, String) Function(List<ActionCentreItem>) read,
  ) {
    return FutureBuilder<List<ActionCentreItem>>(
      future: widget.actionItemsFuture,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<ActionCentreItem>> snapshot,
          ) {
            final (String, String) shown = read(
              snapshot.data ?? const <ActionCentreItem>[],
            );
            return HomeKpiTile(
              label: label,
              value: shown.$1,
              sub: shown.$2,
              load: snapshot.hasError
                  ? HomeLoad.failed
                  : snapshot.hasData
                  ? HomeLoad.ready
                  : HomeLoad.loading,
              onRetry: _retry,
            );
          },
    );
  }

  List<_Need> _needs(int pending, List<ActionCentreItem> items) {
    int sum(bool Function(ActionCentreItem) test) => items
        .where(test)
        .fold<int>(0, (int a, ActionCentreItem i) => a + _leadingCount(i));
    String pageOf(bool Function(ActionCentreItem) test, String fallback) {
      for (final ActionCentreItem i in items) {
        if (test(i) && i.relatedPageKey.isNotEmpty) return i.relatedPageKey;
      }
      return fallback;
    }

    String reasonOf(bool Function(ActionCentreItem) test, String fallback) {
      for (final ActionCentreItem i in items) {
        if (test(i) && i.reason.trim().isNotEmpty) return i.reason.trim();
      }
      return fallback;
    }

    bool cat(ActionCentreItem i, String c) =>
        i.category.toLowerCase() == c.toLowerCase();
    bool special(ActionCentreItem i) => cat(i, 'Special Request');
    bool coords(ActionCentreItem i) =>
        i.relatedEntityType == 'retailer_coordinates';
    bool route(ActionCentreItem i) => cat(i, 'Route Workflow');
    bool follow(ActionCentreItem i) => cat(i, 'Salesman Follow-up');
    bool overdue(ActionCentreItem i) => cat(i, 'Retailer Visit');
    bool stock(ActionCentreItem i) =>
        cat(i, 'Restock') || cat(i, 'Sales Change');
    return <_Need>[
      _Need(
        count: pending,
        tone: ScootTone.warning,
        one: 'Order waits for approval',
        many: 'Orders wait for approval',
        detail: _isAdmin
            ? 'This counts every order waiting, old ones too. In All Orders, '
                  'choose Status: Waiting. The list holds the newest orders only.'
            : 'Open the orders page and choose Status: Waiting.',
        action: _isAdmin ? 'Review' : 'Open orders',
        pageKey: 'all_orders',
      ),
      _Need(
        count: sum(special),
        tone: ScootTone.warning,
        one: 'Special request waits more than 24 hours',
        many: 'Special requests wait more than 24 hours',
        detail: reasonOf(special, 'Open the requests to answer them.'),
        action: _isSupervisor ? 'Decide' : 'Open',
        pageKey: 'special_requests',
        primary: _isSupervisor,
      ),
      _Need(
        count: sum(route),
        tone: ScootTone.info,
        one: 'Route plan to review or publish',
        many: 'Route plans to review or publish',
        detail: reasonOf(route, 'Open the route planner.'),
        action: _isSupervisor ? 'Plan route' : 'Open',
        pageKey: pageOf(route, 'route_planner'),
      ),
      _Need(
        count: sum(coords),
        tone: ScootTone.danger,
        one: 'Shop location to verify',
        many: 'Shop locations to verify',
        detail: reasonOf(coords, 'Check the location on the map.'),
        action: 'Open',
        pageKey: pageOf(coords, ''),
      ),
      _Need(
        count: sum(follow),
        tone: ScootTone.danger,
        one: 'Salesperson to follow up',
        many: 'Salespeople to follow up',
        detail: reasonOf(follow, 'Open the activity page.'),
        action: 'Open',
        pageKey: pageOf(follow, 'salesman_activity'),
      ),
      _Need(
        count: sum(overdue),
        tone: ScootTone.warning,
        one: 'Overdue shop visit',
        many: 'Overdue shop visits',
        detail: reasonOf(overdue, 'Open the visit logs.'),
        action: 'Open',
        pageKey: pageOf(overdue, 'visit_logs'),
      ),
      _Need(
        count: sum(stock),
        tone: ScootTone.info,
        one: 'Stock or sales signal',
        many: 'Stock and sales signals',
        detail: reasonOf(stock, 'Open the reports.'),
        action: 'Open',
        pageKey: pageOf(stock, 'reports'),
      ),
    ];
  }

  Widget _needsCard(AsyncSnapshot<int> pending) {
    final String title = _isBranchManager
        ? 'Waiting on others'
        : 'Orders and requests';
    return FutureBuilder<List<ActionCentreItem>>(
      future: widget.actionItemsFuture,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<ActionCentreItem>> actions,
          ) {
            final bool loading =
                (!pending.hasData && !pending.hasError) ||
                (actions.connectionState == ConnectionState.waiting &&
                    !actions.hasData);
            final bool failed = pending.hasError || actions.hasError;
            final List<_Need> open = _needs(
              pending.data ?? 0,
              actions.data ?? const <ActionCentreItem>[],
            ).where((_Need n) => n.count > 0).toList();
            final int actionCount = (actions.data ?? const <ActionCentreItem>[]).length;
            final Widget body;
            if (loading) {
              body = const HomeRowSkeletons(rows: 3);
            } else if (failed) {
              body = ScootErrorState(onRetry: _retry);
            } else if (open.isEmpty) {
              body = ScootEmptyState(
                title: _isBranchManager
                    ? 'Nothing waits on others'
                    : 'Nothing waits for you',
                message: 'New orders and requests appear here.',
                icon: ScootIcons.success,
              );
            } else {
              body = HomeDivided(
                children: <Widget>[
                  for (final _Need n in open)
                    HomeNeedRow(
                      count: n.count,
                      tone: n.tone,
                      title: n.count == 1 ? n.one : n.many,
                      detail: n.detail,
                      action: n.action,
                      primary: n.primary,
                      onAction: n.pageKey.isEmpty ? null : () => _go(n.pageKey),
                    ),
                ],
              );
            }
            return ScootCard(
              title: title,
              trailing: _isBranchManager
                  ? null
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_isBranchManager) ...<Widget>[
                    Text(
                      'Open each page to see who the work waits on.',
                      style: ScootType.caption.copyWith(
                        color: ScootColors.of(context).muted,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  body,
                  if (_isSupervisor && !loading && !failed) ...<Widget>[
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      children: <Widget>[
                        Text(
                          actionCount == 0
                              ? 'Action Center has no open insights.'
                              : 'Action Center has $actionCount open ${actionCount == 1 ? 'insight' : 'insights'}.',
                          style: ScootType.caption.copyWith(
                            color: ScootColors.of(context).muted,
                          ),
                        ),
                        HomeCardLink(
                          label: 'Open Action Center',
                          onTap: () => _go('team_action_center'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
    );
  }

  Widget _adminFieldCard(
    AsyncSnapshot<List<Map<String, dynamic>>> visits,
    List<Map<String, dynamic>> today,
    bool loading,
    Widget failed,
  ) {
    final ScootColors c = ScootColors.of(context);
    final Set<String> active = _activeKeys(today);
    DateTime? last;
    for (final Map<String, dynamic> row in today) {
      final DateTime? at = _visitMoment(row);
      if (at != null && (last == null || at.isAfter(last))) last = at;
    }
    final Widget body;
    if (loading) {
      body = const HomeRowSkeletons(rows: 3, rowHeight: 56);
    } else if (visits.hasError) {
      body = failed;
    } else if (today.isEmpty) {
      body = const ScootEmptyState(
        title: 'No visits yet today',
        message: 'Visits appear here when salespeople arrive at a shop.',
        icon: ScootIcons.place,
      );
    } else {
      body = HomeDivided(
        children: <Widget>[
          for (final Map<String, dynamic> row in today.take(4))
            _adminVisitRow(row),
        ],
      );
    }
    return ScootCard(
      title: 'Today in the field',
      trailing: HomeCardLink(
        label: 'Open tracking',
        onTap: () => _go('salesman_activity'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          body,
          if (!loading && !visits.hasError && today.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '${active.length} ${active.length == 1 ? 'salesperson' : 'salespeople'} active · last activity ${homeClock(last)}',
              style: ScootType.caption.copyWith(color: c.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _adminVisitRow(Map<String, dynamic> row) {
    final DateTime? arrive = _arrival(row);
    final DateTime? leave = _departure(row);
    final String span = leave == null
        ? homeClock(arrive)
        : '${homeClock(arrive)}–${homeClock(leave)}';
    final String onSite = (arrive != null && leave != null)
        ? ' · ${leave.difference(arrive).inMinutes} min on site'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              span,
              style: ScootType.caption.copyWith(
                color: ScootColors.of(context).muted,
                fontFeatures: ScootType.tabular,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _shopName(row).isEmpty ? 'Shop visit' : _shopName(row),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.bodyStrong.copyWith(
                    color: ScootColors.of(context).ink,
                  ),
                ),
                Text(
                  '${_personName(row)}$onSite',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.caption.copyWith(
                    color: ScootColors.of(context).muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _visitBadge(row),
        ],
      ),
    );
  }

  Widget _visitBadge(Map<String, dynamic> row) => _isCompletedVisit(row)
      ? const ScootBadge.approved(label: 'Completed')
      : const ScootBadge(label: 'On site', tone: ScootTone.info);

  Widget _timelineCard(
    AsyncSnapshot<List<Map<String, dynamic>>> orders,
    AsyncSnapshot<List<Map<String, dynamic>>> visits,
    List<Map<String, dynamic>> todayOrders,
    List<Map<String, dynamic>> todayVisits,
  ) {
    final ScootColors c = ScootColors.of(context);
    final List<(DateTime, Widget)> entries = <(DateTime, Widget)>[];
    for (final Map<String, dynamic> row in todayOrders) {
      final DateTime at = orderDateFromRow(row) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final String id = dataText(row['orderId'] ?? row['id']);
      final String status = orderStatus(row);
      entries.add((
        at,
        HomeFieldRow(
          lead: homeClock(at),
          title: '${id.isEmpty ? 'Order' : id} sent',
          sub: '${dataText(row['retailerName'] ?? row['retailer_name'], fallback: 'Shop')} · ${_ringgit(orderRevenue(row))}',
          badge: status == 'approved'
              ? const ScootBadge.approved()
              : isRejectedOrder(row)
              ? const ScootBadge.rejected()
              : const ScootBadge.attention(label: 'Not approved'),
        ),
      ));
    }
    for (final Map<String, dynamic> row in todayVisits) {
      final DateTime at = _visitMoment(row) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime? arrive = _arrival(row);
      final DateTime? leave = _departure(row);
      final bool done = _isCompletedVisit(row);
      entries.add((
        at,
        HomeFieldRow(
          lead: homeClock(at),
          title: '${done ? 'Visit completed' : 'Arrived'} at ${_shopName(row).isEmpty ? 'a shop' : _shopName(row)}',
          sub: arrive == null
              ? _personName(row)
              : leave == null
              ? 'Arrived ${homeClock(arrive)}'
              : 'Arrived ${homeClock(arrive)} · ${leave.difference(arrive).inMinutes} min in the shop',
          badge: _visitBadge(row),
        ),
      ));
    }
    entries.sort((a, b) => b.$1.compareTo(a.$1));
    final bool loading =
        (!orders.hasData && !orders.hasError) ||
        (!visits.hasData && !visits.hasError);
    final Widget body = loading
        ? const HomeRowSkeletons(rows: 4, rowHeight: 56)
        : (orders.hasError || visits.hasError)
        ? ScootErrorState(onRetry: _retry)
        : entries.isEmpty
        ? const ScootEmptyState(
            title: 'Nothing yet today',
            message: 'Orders and visits appear here as they happen.',
            icon: ScootIcons.visitLogs,
          )
        : HomeDivided(children: <Widget>[for (final e in entries.take(5)) e.$2]);
    return ScootCard(
      title: 'Today in the field',
      trailing: Text(
        'Orders and visits, newest first',
        style: ScootType.caption.copyWith(color: c.muted),
      ),
      child: body,
    );
  }

  List<_FieldPerson> _people(
    List<Map<String, dynamic>> todayVisits,
    List<Map<String, dynamic>> todayOrders,
  ) {
    final Map<String, _FieldPerson> people = <String, _FieldPerson>{};
    _FieldPerson personFor(Map<String, dynamic> row) {
      final String key = _salesmanKey(row);
      final _FieldPerson p = people.putIfAbsent(
        key,
        () => _FieldPerson(key, _personName(row)),
      );
      final String name = dataText(row['salesmanName'] ?? row['salesman_name']);
      if (name.isNotEmpty) p.name = name;
      return p;
    }

    for (final Map<String, dynamic> row in todayVisits) {
      if (_salesmanKey(row).isEmpty) continue;
      final _FieldPerson p = personFor(row);
      if (_isCompletedVisit(row)) p.visits++;
      final DateTime? at = _visitMoment(row);
      if (at != null && (p.last == null || at.isAfter(p.last!))) p.last = at;
    }
    for (final Map<String, dynamic> row in todayOrders) {
      if (_salesmanKey(row).isEmpty) continue;
      final _FieldPerson p = personFor(row);
      final DateTime? at = orderDateFromRow(row);
      if (orderCountsAsSale(row)) {
        p.orders++;
        if (at != null && (p.lastOrder == null || at.isAfter(p.lastOrder!))) {
          p.lastOrder = at;
        }
      }
      if (at != null && (p.last == null || at.isAfter(p.last!))) p.last = at;
    }
    final List<_FieldPerson> list = people.values.toList();
    list.sort(
      (a, b) => (b.last ?? DateTime(0)).compareTo(a.last ?? DateTime(0)),
    );
    return list;
  }

  Widget _teamCard(
    List<Map<String, dynamic>> todayVisits,
    List<Map<String, dynamic>> todayOrders,
    bool loading,
  ) {
    final ScootColors c = ScootColors.of(context);
    final List<_FieldPerson> people = _people(todayVisits, todayOrders);
    final int team = widget.currentUser.assignedSalesmanCodes.length;
    Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: ScootType.caption.copyWith(color: c.muted)),
          ),
          Text(value, style: ScootType.smallStrong.copyWith(color: c.ink)),
        ],
      ),
    );
    final Widget body = loading
        ? const HomeRowSkeletons(rows: 2, rowHeight: 84)
        : people.isEmpty
        ? const ScootEmptyState(
            title: 'No activity today',
            message: 'Your team shows here after the first visit or order.',
            icon: ScootIcons.team,
          )
        : HomeDivided(
            children: <Widget>[
              for (final _FieldPerson p in people.take(3))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: c.brand,
                            child: Text(
                              p.name.isEmpty ? '?' : p.name[0].toUpperCase(),
                              style: ScootType.smallStrong.copyWith(
                                color: c.onBrand,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ScootType.bodyStrong.copyWith(
                                    color: c.ink,
                                  ),
                                ),
                                Text(
                                  '${p.key} · last seen ${homeClock(p.last)}',
                                  style: ScootType.caption.copyWith(
                                    color: c.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const ScootBadge.approved(label: 'Active'),
                        ],
                      ),
                      const SizedBox(height: 6),
                      fact('Visits', '${p.visits} completed'),
                      fact(
                        'Orders',
                        p.orders == 0
                            ? 'None'
                            : '${p.orders} · last at ${homeClock(p.lastOrder)}',
                      ),
                    ],
                  ),
                ),
            ],
          );
    return ScootCard(
      title: 'Your team today',
      trailing: HomeCardLink(label: 'My team', onTap: () => _go('my_team')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          body,
          if (team > 0) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '$team ${team == 1 ? 'salesperson is' : 'salespeople are'} assigned to you.',
              style: ScootType.caption.copyWith(color: c.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _branchFieldCard(
    List<Map<String, dynamic>> todayVisits,
    List<Map<String, dynamic>> todayOrders,
    bool loading,
    bool failed,
  ) {
    final List<_FieldPerson> people = _people(todayVisits, todayOrders);
    final Widget body = loading
        ? const HomeRowSkeletons(rows: 3, rowHeight: 56)
        : failed
        ? ScootErrorState(onRetry: _retry)
        : people.isEmpty
        ? const ScootEmptyState(
            title: 'No field activity today',
            message: 'Salespeople show here after their first visit or order.',
            icon: ScootIcons.team,
          )
        : HomeMiniTable<_FieldPerson>(
            rows: people.take(5).toList(),
            columns: <HomeMiniColumn<_FieldPerson>>[
              HomeMiniColumn<_FieldPerson>(
                label: 'Salesperson',
                flex: 3,
                cell: (_, p) => Text(
                  p.name,
                  style: ScootType.bodyStrong,
                ),
              ),
              HomeMiniColumn<_FieldPerson>(
                label: 'Visits',
                flex: 2,
                cell: (_, p) => p.visits == 0
                    ? const ScootBadge(label: 'None yet')
                    : ScootBadge.approved(label: '${p.visits} done'),
              ),
              HomeMiniColumn<_FieldPerson>(
                label: 'Orders',
                numeric: true,
                cell: (_, p) => Text('${p.orders}'),
              ),
              HomeMiniColumn<_FieldPerson>(
                label: 'Last seen',
                flex: 2,
                cell: (_, p) => Text(homeClock(p.last)),
              ),
            ],
          );
    return ScootCard(
      title: 'Today in the field',
      padding: EdgeInsets.zero,
      trailing: HomeCardLink(
        label: 'Live map',
        onTap: () => _go('salesman_activity'),
      ),
      child: body,
    );
  }

  Widget _latestVisitsCard(
    List<Map<String, dynamic>> todayVisits,
    bool loading,
    bool failed,
  ) {
    final Widget body = loading
        ? const Padding(
            padding: EdgeInsets.all(20),
            child: HomeRowSkeletons(rows: 3, rowHeight: 48),
          )
        : failed
        ? ScootErrorState(onRetry: _retry)
        : todayVisits.isEmpty
        ? const ScootEmptyState(
            title: 'No visits yet today',
            message: 'Visits appear here when salespeople arrive at a shop.',
            icon: ScootIcons.place,
          )
        : HomeMiniTable<Map<String, dynamic>>(
            rows: todayVisits.take(5).toList(),
            columns: <HomeMiniColumn<Map<String, dynamic>>>[
              HomeMiniColumn<Map<String, dynamic>>(
                label: 'Shop',
                flex: 4,
                cell: (_, r) => Text(
                  _shopName(r).isEmpty ? 'Shop visit' : _shopName(r),
                  style: ScootType.bodyStrong,
                ),
              ),
              HomeMiniColumn<Map<String, dynamic>>(
                label: 'Salesperson',
                flex: 3,
                cell: (_, r) => Text(_personName(r)),
              ),
              HomeMiniColumn<Map<String, dynamic>>(
                label: 'Arrived',
                flex: 2,
                cell: (_, r) => Text(homeClock(_arrival(r))),
              ),
              HomeMiniColumn<Map<String, dynamic>>(
                label: 'Left',
                flex: 2,
                cell: (_, r) =>
                    Text(_departure(r) == null ? '—' : homeClock(_departure(r))),
              ),
              HomeMiniColumn<Map<String, dynamic>>(
                label: 'Status',
                flex: 2,
                cell: (_, r) => _visitBadge(r),
              ),
            ],
          );
    return ScootCard(
      title: 'Latest visits',
      padding: EdgeInsets.zero,
      trailing: HomeCardLink(
        label: 'All visit logs',
        onTap: () => _go('visit_logs'),
      ),
      child: body,
    );
  }

  String _shopName(Map<String, dynamic> row) => dataText(
    row['retailerName'] ?? row['retailer_name'] ?? row['retailer_id'],
  );

  String _personName(Map<String, dynamic> row) {
    final String name = dataText(row['salesmanName'] ?? row['salesman_name']);
    return name.isNotEmpty ? name : _salesmanKey(row);
  }

  DateTime? _arrival(Map<String, dynamic> row) =>
      parseFlexibleDate(row['arrivalTime'] ?? row['arrival_time']);

  DateTime? _departure(Map<String, dynamic> row) =>
      parseFlexibleDate(row['departureTime'] ?? row['departure_time']);

  DateTime? _visitMoment(Map<String, dynamic> row) =>
      _departure(row) ?? _arrival(row) ?? visitDateFromRow(row);

  bool _coversFrame(List<Map<String, dynamic>>? rows) =>
      collectionRowsCover(rows, _frameStartUtc());

  bool _locationsCoverFrame(List<Map<String, dynamic>>? rows) =>
      _coversFrame(rows) && locationRowsCover(rows, _frameStartUtc());

  DateTime _ordersFetchStartUtc() {
    const Duration klOffset = Duration(hours: 8);
    final DateTime nowKl = DateTime.now().toUtc().add(klOffset);
    final DateTime fourteenDayStart = DateTime.utc(
      nowKl.year,
      nowKl.month,
      nowKl.day,
    ).subtract(const Duration(days: 13)).subtract(klOffset);
    final DateTime frameStart = _frameStartUtc();
    return frameStart.isBefore(fourteenDayStart)
        ? frameStart
        : fourteenDayStart;
  }

  DateTime _frameStartUtc() {
    const Duration klOffset = Duration(hours: 8);
    final DateTime nowKl = DateTime.now().toUtc().add(klOffset);
    final DateTime todayKl = DateTime.utc(nowKl.year, nowKl.month, nowKl.day);
    final DateTime startKl = switch (_timeframe) {
      _DashboardTimeframe.today => todayKl,
      _DashboardTimeframe.week => todayKl.subtract(
        Duration(days: todayKl.weekday - 1),
      ),
      _DashboardTimeframe.month => DateTime.utc(nowKl.year, nowKl.month),
    };
    return startKl.subtract(klOffset);
  }

  List<Map<String, dynamic>> _todayVisits(List<Map<String, dynamic>> rows) {
    final List<Map<String, dynamic>> today = _scopeRows(rows)
        .where((Map<String, dynamic> row) => _isToday(visitDateFromRow(row)))
        .toList();
    today.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      return (visitDateFromRow(b) ?? DateTime(0)).compareTo(
        visitDateFromRow(a) ?? DateTime(0),
      );
    });
    return today;
  }

  List<Map<String, dynamic>> _todayOrders(List<Map<String, dynamic>> rows) {
    return _scopeRows(rows)
        .where(
          (Map<String, dynamic> row) =>
              _isToday(orderDateFromRow(row)) &&
              orderStatus(row) != 'draft',
        )
        .toList(growable: false);
  }

  bool _isToday(DateTime? value) {
    if (value == null) return false;
    final DateTime nowKl = DateTime.now().toUtc().add(const Duration(hours: 8));
    final DateTime valueKl = value.toUtc().add(const Duration(hours: 8));
    return valueKl.year == nowKl.year &&
        valueKl.month == nowKl.month &&
        valueKl.day == nowKl.day;
  }

  int _leadingCount(ActionCentreItem item) {
    final RegExpMatch? m = RegExp(r'^(\d+)\b').firstMatch(item.title.trim());
    return m == null ? 1 : (int.tryParse(m.group(1)!) ?? 1);
  }

  List<Map<String, dynamic>> _ordersInFrame(List<Map<String, dynamic>> rows) =>
      _scopeRows(rows)
          .where(
            (Map<String, dynamic> row) => _isInFrame(orderDateFromRow(row)),
          )
          .toList(growable: false);

  List<Map<String, dynamic>> _visitsInFrame(List<Map<String, dynamic>> rows) =>
      _scopeRows(rows)
          .where(
            (Map<String, dynamic> row) => _isInFrame(visitDateFromRow(row)),
          )
          .toList(growable: false);

  List<Map<String, dynamic>> _scopeRows(List<Map<String, dynamic>> rows) =>
      TeamScope.filter(
        widget.currentUser,
        rows.where((Map<String, dynamic> row) => !isDemoRow(row)),
      );

  bool _isInFrame(DateTime? date) {
    if (date == null) return false;
    final DateTime nowKl = DateTime.now().toUtc().add(const Duration(hours: 8));
    final DateTime valueKl = date.toUtc().add(const Duration(hours: 8));
    final DateTime today = DateTime(nowKl.year, nowKl.month, nowKl.day);
    final DateTime valueDay = DateTime(
      valueKl.year,
      valueKl.month,
      valueKl.day,
    );
    switch (_timeframe) {
      case _DashboardTimeframe.today:
        return valueDay == today;
      case _DashboardTimeframe.week:
        final DateTime weekStart = today.subtract(
          Duration(days: today.weekday - 1),
        );
        return !valueDay.isBefore(weekStart);
      case _DashboardTimeframe.month:
        return valueKl.year == nowKl.year && valueKl.month == nowKl.month;
    }
  }

  bool _isCompletedVisit(Map<String, dynamic> row) {
    if (isSkippedVisit(row)) return false;
    final String status = dataText(
      row['status'] ?? row['trackingStatus'],
    ).toLowerCase();
    final String departure = dataText(
      row['departureTime'] ?? row['departure_time'],
    );
    return departure.isNotEmpty ||
        status.contains('complete') ||
        status.contains('visited') ||
        status.contains('submit');
  }

  Set<String> _activeKeys(List<Map<String, dynamic>> rows) =>
      rows.map(_salesmanKey).where((String key) => key.isNotEmpty).toSet();

  String _salesmanKey(Map<String, dynamic> row) {
    return dataText(
      pickFirst(row, const <String>[
        'salesmanId',
        'salesman_id',
        'salesmanUid',
        'salesman_uid',
        'staffId',
        'staff_id',
        'employeeCode',
        'employee_code',
        'uid',
        'email',
      ]),
    );
  }

  String _ringgit(double value, ) {
    final String fixed = value.toStringAsFixed(2);
    final List<String> parts = fixed.split('.');
    final String whole = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    return 'RM $whole.${parts[1]}';
  }

  _DashboardTimeframe _timeframeFromString(String value) {
    switch (value.trim().toLowerCase()) {
      case 'week':
        return _DashboardTimeframe.week;
      case 'month':
        return _DashboardTimeframe.month;
      default:
        return _DashboardTimeframe.today;
    }
  }

  String _timeframeToString(_DashboardTimeframe tf) {
    switch (tf) {
      case _DashboardTimeframe.today:
        return 'today';
      case _DashboardTimeframe.week:
        return 'week';
      case _DashboardTimeframe.month:
        return 'month';
    }
  }

  Future<void> _openEditor() async {
    final List<String> order = List<String>.of(_order);
    final Set<String> selected = Set<String>.of(_selected);
    _DashboardTimeframe tf = _timeframe;

    final bool? saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheet) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(sheetContext).size.height * 0.8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                      child: Row(
                        children: <Widget>[
                          const Expanded(
                            child: Text(
                              'Edit dashboard',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(ScootIcons.close),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Text(
                        'Toggle cards on or off and drag to reorder. Changes save '
                        'to your account.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: ScootColors.of(context).muted,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: Row(
                        children: <Widget>[
                          Text(
                            'Default timeframe:',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: ScootColors.of(context).text2,
                            ),
                          ),
                          const SizedBox(width: 10),
                          SegmentedButton<_DashboardTimeframe>(
                            segments:
                                const <ButtonSegment<_DashboardTimeframe>>[
                                  ButtonSegment<_DashboardTimeframe>(
                                    value: _DashboardTimeframe.today,
                                    label: Text('Today'),
                                  ),
                                  ButtonSegment<_DashboardTimeframe>(
                                    value: _DashboardTimeframe.week,
                                    label: Text('Week'),
                                  ),
                                  ButtonSegment<_DashboardTimeframe>(
                                    value: _DashboardTimeframe.month,
                                    label: Text('Month'),
                                  ),
                                ],
                            selected: <_DashboardTimeframe>{tf},
                            onSelectionChanged: (Set<_DashboardTimeframe> v) =>
                                setSheet(() => tf = v.first),
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 16),
                    Expanded(
                      child: ReorderableListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: order.length,
                        onReorder: (int oldIndex, int newIndex) {
                          setSheet(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final String moved = order.removeAt(oldIndex);
                            order.insert(newIndex, moved);
                          });
                        },
                        itemBuilder: (BuildContext context, int index) {
                          final String id = order[index];
                          final String label = _kCards
                              .firstWhere((_DashCardSpec c) => c.id == id)
                              .label;
                          return Padding(
                            key: ValueKey<String>(id),
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: ScootColors.of(context).line),
                              ),
                              child: Row(
                                children: <Widget>[
                                  Checkbox(
                                    value: selected.contains(id),
                                    onChanged: (bool? v) => setSheet(() {
                                      if (v == true) {
                                        selected.add(id);
                                      } else {
                                        selected.remove(id);
                                      }
                                    }),
                                  ),
                                  Expanded(
                                    child: Text(
                                      label,
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Icon(
                                        Icons.drag_handle,
                                        color: ScootColors.of(context).muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: <Widget>[
                          OutlinedButton.icon(
                            onPressed: () =>
                                Navigator.of(sheetContext).pop(false),
                            icon: const Icon(ScootIcons.refresh, size: 18),
                            label: const Text('Reset to default'),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: () =>
                                Navigator.of(sheetContext).pop(true),
                            icon: const Icon(Icons.save_outlined, size: 18),
                            label: const Text('Save layout'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (saved == null || !mounted) return;
    final String uid = widget.currentUser.uid ?? '';
    if (saved) {
      setState(() {
        _order = order;
        _selected = selected;
        _setTimeframe(tf);
      });
      try {
        await _prefsService.save(
          uid,
          DashboardPreferences(
            selectedCards: selected.toList(),
            cardOrder: order,
            defaultTimeframe: _timeframeToString(tf),
          ),
        );
        _toast('Dashboard layout saved.');
      } catch (_) {
        _toast('Could not save layout. Please try again.');
      }
    } else {
      setState(() {
        _order = _kCards.map((_DashCardSpec c) => c.id).toList();
        _selected = _defaultSelected.toSet();
        _setTimeframe(_DashboardTimeframe.today);
      });
      await _prefsService.reset(uid);
      _toast('Dashboard reset to default.');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
