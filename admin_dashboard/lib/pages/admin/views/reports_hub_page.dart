import 'package:flutter/material.dart';

import '../../../app/build_flags.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../theme/dso_theme.dart';
import 'package:scoot_design/scoot_design.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/forecast_catalogue_provenance.dart';
import '../../../utils/ai_data_freshness.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../../../widgets/page_states.dart';
import 'master_data_hygiene_panel.dart';
import 'monthly_retailer_scorecard_page.dart';
import 'weekly_ai_summary_panel.dart';
import '../../../utils/money_format.dart';
import '../../../security/team_scope.dart';

class ReportsHubPage extends StatefulWidget {
  const ReportsHubPage({
    super.key,
    required this.currentUser,
    this.onNavigateRequested,
    this.loadOrders,
    this.loadForecasts,
  });

  final UserProfile currentUser;
  final ValueChanged<String>? onNavigateRequested;
  final Future<OrderWindowRead> Function(DateTime start, DateTime end)?
  loadOrders;
  final Future<ForecastCatalogueSelection> Function()? loadForecasts;

  @override
  State<ReportsHubPage> createState() => _ReportsHubPageState();
}

class _ReportsHubPageState extends State<ReportsHubPage>
    with SingleTickerProviderStateMixin {
  late final CmsRepository _repository = CmsRepository();
  late final TabController _tabController;
  late Future<ForecastCatalogueSelection>? _forecastsFuture;

  DateTime _anchor = DateTime(DateTime.now().year, DateTime.now().month);
  bool _includeRejected = false;

  Future<OrderWindowRead>? _ordersFuture;
  DateTime? _ordersAnchor;

  Future<OrderWindowRead> _ordersForAnchor({bool refresh = false}) {
    if (refresh || _ordersFuture == null || _ordersAnchor != _anchor) {
      _ordersAnchor = _anchor;
      final DateTime start = DateTime(_anchor.year, _anchor.month - 1);
      final DateTime end = DateTime(_anchor.year, _anchor.month + 1);
      _ordersFuture =
          widget.loadOrders?.call(start, end) ??
          _repository.getOrdersSubmittedBetween(start: start, end: end);
    }
    return _ordersFuture!;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: (widget.currentUser.isAdmin ? 7 : 5) - (isBasicEdition ? 1 : 0),
      vsync: this,
    );
    _tabController.addListener(_handleTabChange);
    _forecastsFuture = isBasicEdition
        ? null
        : (widget.loadForecasts?.call() ?? _verifiedForecasts());
  }

  Future<ForecastCatalogueSelection> _verifiedForecasts() async {
    final Future<List<Map<String, dynamic>>?> catalogueRead = _repository
        .getCollectionOnce('products', limit: 2000)
        .then<List<Map<String, dynamic>>?>(
          (List<Map<String, dynamic>> rows) => rows,
          onError: (Object _) => null,
        );
    final List<Map<String, dynamic>> forecasts = await _repository
        .getCollectionOnce(
          'demand_forecasts',
          orderBy: 'forecastMonth',
          descending: true,
          limit: 120,
        );
    final List<Map<String, dynamic>>? catalogue = await catalogueRead;
    return selectCatalogueForecasts(forecasts: forecasts, catalogue: catalogue);
  }

  bool get _showingRetailerScorecard =>
      widget.currentUser.isAdmin &&
      _tabController.index == _tabController.length - 1;

  int _lastRenderedTabIndex = 0;

  void _handleTabChange() {
    if (_tabController.indexIsChanging ||
        _lastRenderedTabIndex == _tabController.index) {
      return;
    }
    _lastRenderedTabIndex = _tabController.index;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _reload() => setState(() {
    _ordersForAnchor(refresh: true);
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OrderWindowRead>(
      future: _ordersForAnchor(),
      builder: (BuildContext context, AsyncSnapshot<OrderWindowRead> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return _ReportsSkeleton(onRetry: () => _reload());
        }
        if (snapshot.hasError) {
          return ScootCard(
            child: PageErrorState(
              error: snapshot.error,
              title: 'Reports could not load',
              onRetry: () => _reload(),
            ),
          );
        }
        final List<Map<String, dynamic>> all =
            snapshot.data?.rows ?? <Map<String, dynamic>>[];
        final List<Map<String, dynamic>> scoped = _scope(all);
        final List<Map<String, dynamic>> monthRows = _filterByMonth(
          scoped,
          _anchor,
        );
        final List<Map<String, dynamic>> includedRows = _includeRejected
            ? monthRows
            : operationalReportOrders(monthRows);
        final DateTime previousAnchor = DateTime(
          _anchor.year,
          _anchor.month - 1,
        );
        final List<Map<String, dynamic>> previousMonthRows = _filterByMonth(
          scoped,
          previousAnchor,
        );
        final List<Map<String, dynamic>> previousIncludedRows = _includeRejected
            ? previousMonthRows
            : operationalReportOrders(previousMonthRows);

        final int rejectedCount =
            monthRows.length - operationalReportOrders(monthRows).length;

        final bool windowIncomplete = snapshot.data?.truncated ?? false;

        final bool scopedToNothing =
            all.isNotEmpty &&
            scoped.isEmpty &&
            (widget.currentUser.isSupervisor ||
                widget.currentUser.isBranchManager);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!_showingRetailerScorecard)
              _toolbar(rejectedCount: rejectedCount),
            if (!_showingRetailerScorecard && windowIncomplete) ...<Widget>[
              const SizedBox(height: 12),
              const ScootNotice(
                tone: ScootTone.warning,
                title: 'Read limit',
                message:
                    'This month has more orders than the report reads at once. Totals are a lower bound.',
              ),
            ],
            if (!_showingRetailerScorecard && scopedToNothing) ...<Widget>[
              const SizedBox(height: 12),
              _ScopeNotice(
                rawCount: all.length,
                isBranch: widget.currentUser.isBranchManager,
              ),
            ],
            if (!_showingRetailerScorecard) ...<Widget>[
              const SizedBox(height: 16),
              _summaryStrip(includedRows, previousIncludedRows),
            ],
            const SizedBox(height: 12),
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabs: <Tab>[
                Tab(text: 'Monthly Summary'),
                Tab(text: 'Order Trend'),
                Tab(text: 'Top Products'),
                Tab(text: 'Top Retailers'),
                if (!isBasicEdition) Tab(text: 'Weekly AI'),
                if (widget.currentUser.isAdmin) ...<Tab>[
                  const Tab(text: 'Data Hygiene'),
                  const Tab(text: 'Retailer Scorecard'),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: <Widget>[
                  _MonthlySummaryTab(
                    rows: includedRows,
                    previousRows: previousIncludedRows,
                    monthAnchor: _anchor,
                    forecastsFuture: _forecastsFuture,
                    onGoCurrent: () => setState(
                      () => _anchor = DateTime(
                        DateTime.now().year,
                        DateTime.now().month,
                      ),
                    ),
                  ),
                  _OrderTrendTab(rows: includedRows, monthAnchor: _anchor),
                  _TopProductsTab(rows: includedRows),
                  _TopRetailersTab(rows: includedRows),
                  if (!isBasicEdition)
                    WeeklyAiSummaryPanel(
                      currentUser: widget.currentUser,
                      embedded: true,
                    ),
                  if (widget.currentUser.isAdmin) ...<Widget>[
                    MasterDataHygienePanel(
                      currentUser: widget.currentUser,
                      onNavigateRequested: widget.onNavigateRequested,
                    ),
                    MonthlyRetailerScorecardPage(
                      currentUser: widget.currentUser,
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _toolbar({required int rejectedCount}) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        SizedBox(width: 260, child: _monthNavigator()),
        _rejectedToggle(rejectedCount),
        _thisMonthButton(),
        IconButton(
          tooltip: 'Reload orders',
          icon: const Icon(ScootIcons.refresh, size: 18),
          onPressed: () => _reload(),
        ),
      ],
    );
  }

  Widget _monthNavigator() {
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: 'Previous month',
          onPressed: () => setState(
            () => _anchor = DateTime(_anchor.year, _anchor.month - 1),
          ),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Center(
            child: Text(
              '${_monthName(_anchor.month)} ${_anchor.year}',
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Next month',
          onPressed:
              _anchor.isBefore(
                DateTime(DateTime.now().year, DateTime.now().month),
              )
              ? () => setState(
                  () => _anchor = DateTime(_anchor.year, _anchor.month + 1),
                )
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  Widget _rejectedToggle(int rejectedCount) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: MergeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Switch(
                  value: _includeRejected,
                  onChanged: (bool value) =>
                      setState(() => _includeRejected = value),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Include rejected',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (rejectedCount > 0) ...<Widget>[
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: context.dso.dangerSoft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$rejectedCount',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: context.dso.dangerText,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _thisMonthButton() {
    return OutlinedButton.icon(
      onPressed: () => setState(
        () => _anchor = DateTime(DateTime.now().year, DateTime.now().month),
      ),
      icon: const Icon(Icons.today, size: 16),
      label: const Text('This month'),
    );
  }

  Widget _summaryStrip(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> previousRows,
  ) {
    final _SummaryStats now = _SummaryStats.fromRows(rows);
    final _SummaryStats before = _SummaryStats.fromRows(previousRows);
    final String previousName = _monthNameText(
      DateTime(_anchor.year, _anchor.month - 1).month,
    ).substring(0, 3);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth < ScootDataTable.phoneWidth
            ? constraints.maxWidth
            : 200;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: <Widget>[
            _Kpi(
              width: width,
              label: 'Orders',
              value: '${now.orderCount}',
              change: _change(
                now.orderCount.toDouble(),
                before.orderCount,
                previousName,
              ),
            ),
            _Kpi(
              width: width,
              label: 'Revenue',
              value: formatRm(now.revenue),
              change: _change(now.revenue, before.revenue, previousName),
            ),
            _Kpi(width: width, label: 'Boxes', value: '${now.quantity}'),
            _Kpi(
              width: width,
              label: 'Retailers',
              value: '${now.retailers.length}',
            ),
            _Kpi(
              width: width,
              label: 'Salespeople',
              value: '${now.salesmen.length}',
            ),
          ],
        );
      },
    );
  }

  String? _change(double current, num previous, String previousName) {
    if (previous <= 0) return null;
    final double pct = (current - previous) / previous * 100;
    return '${pct >= 0 ? '+' : '-'}${pct.abs().toStringAsFixed(0)} % vs $previousName';
  }

  List<Map<String, dynamic>> _scope(List<Map<String, dynamic>> orders) {
    return TeamScope.filter(widget.currentUser, orders);
  }

  DateTime? _submittedDate(Map<String, dynamic> order) => _toDate(
    pickFirst(order, const <String>[
      'submittedAt',
      'submitted_at',
      'orderDate',
      'order_date',
      'createdAt',
      'created_at',
      'timestamp',
    ]),
  );

  List<Map<String, dynamic>> _filterByMonth(
    List<Map<String, dynamic>> orders,
    DateTime anchor,
  ) {
    final DateTime start = DateTime(anchor.year, anchor.month);
    final DateTime nextMonth = DateTime(anchor.year, anchor.month + 1);
    return orders
        .where((Map<String, dynamic> o) {
          final DateTime? submitted = _submittedDate(o);
          if (submitted == null) return false;
          return !submitted.isBefore(start) && submitted.isBefore(nextMonth);
        })
        .toList(growable: false);
  }

  DateTime? _toDate(Object? value) => parseFlexibleDate(value);

  String _monthName(int month) {
    const List<String> names = <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return names[month - 1];
  }
}

class _MonthlySummaryTab extends StatelessWidget {
  const _MonthlySummaryTab({
    required this.rows,
    required this.previousRows,
    required this.monthAnchor,
    required this.forecastsFuture,
    required this.onGoCurrent,
  });

  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> previousRows;
  final DateTime monthAnchor;
  final VoidCallback onGoCurrent;

  final Future<ForecastCatalogueSelection>? forecastsFuture;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      final DateTime now = DateTime.now();
      final bool isCurrent =
          monthAnchor.year == now.year && monthAnchor.month == now.month;
      return _EmptyState(
        icon: Icons.summarize_outlined,
        label: 'No orders in ${_monthLabel(monthAnchor)}',
        message: 'Pick another month.',
        action: isCurrent
            ? null
            : OutlinedButton(
                onPressed: onGoCurrent,
                child: Text('Go to ${_monthNameText(now.month)}'),
              ),
      );
    }

    final _SummaryStats current = _SummaryStats.fromRows(rows);
    final _SummaryStats previous = _SummaryStats.fromRows(previousRows);

    return FutureBuilder<ForecastCatalogueSelection>(
      future: forecastsFuture,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<ForecastCatalogueSelection> forecastSnap,
          ) {
            final Map<String, dynamic>? highlightedForecast =
                forecastSnap.data == null
                ? null
                : _highlightForecastRow(forecastSnap.data!.rows);
            return ListView(
              children: <Widget>[
                Text(
                  '${_monthLabel(monthAnchor)} recorded ${current.orderCount} order${current.orderCount == 1 ? '' : 's'} '
                  'with ${formatRm(current.revenue)} revenue and ${current.quantity} box/item quantity. '
                  '${_movementText(current.orderCount, previous.orderCount)} ${_moneyMovementText(current.revenue, previous.revenue)}',
                  style: ScootType.body.copyWith(
                    color: ScootColors.of(context).muted,
                  ),
                ),
                const SizedBox(height: 16),
                _topTables(context, current),
                const SizedBox(height: 16),
                _summaryLines(
                  context: context,
                  current: current,
                  rows: rows,
                  forecastSnap: forecastSnap,
                  highlightedForecast: highlightedForecast,
                ),
              ],
            );
          },
    );
  }

  Widget _topTables(BuildContext context, _SummaryStats current) {
    final ScootColors c = ScootColors.of(context);
    Widget line(String name, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ScootLongText(
              name,
              maxLines: 1,
              style: ScootType.body.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: ScootType.bodyStrong.copyWith(
              color: c.ink,
              fontFeatures: ScootType.tabular,
            ),
          ),
        ],
      ),
    );
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: <Widget>[
        SizedBox(
          width: 520,
          child: ScootCard(
            title: 'Top products',
            child: current.topProducts.isEmpty
                ? Text(
                    'No item-level product data for this month.',
                    style: ScootType.body.copyWith(color: c.muted),
                  )
                : Column(
                    children: <Widget>[
                      for (final _SummaryProduct p in current.topProducts)
                        line(p.name, '${p.quantity} qty'),
                    ],
                  ),
          ),
        ),
        SizedBox(
          width: 520,
          child: ScootCard(
            title: 'Top retailers',
            child: current.topRetailers.isEmpty
                ? Text(
                    'No retailer name is attached to the orders in this month.',
                    style: ScootType.body.copyWith(color: c.muted),
                  )
                : Column(
                    children: <Widget>[
                      for (final _SummaryRetailer r in current.topRetailers)
                        line(r.name, formatRm(r.revenue)),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _summaryLines({
    required BuildContext context,
    required _SummaryStats current,
    required List<Map<String, dynamic>> rows,
    required AsyncSnapshot<ForecastCatalogueSelection> forecastSnap,
    required Map<String, dynamic>? highlightedForecast,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _summaryLine(
          context: context,
          icon: Icons.group_outlined,
          title: 'Salesman activity note',
          value: current.salesmen.isEmpty
              ? 'No salesman identity was attached to these orders.'
              : '${current.salesmen.length} active ${current.salesmen.length == 1 ? 'salesperson' : 'salespeople'} submitted orders this month.',
        ),
        if (!isBasicEdition)
          _summaryLine(
            context: context,
            icon: Icons.auto_graph_outlined,
            title: 'Forecast note',
            value:
                forecastSnap.connectionState == ConnectionState.waiting &&
                    !forecastSnap.hasData
                ? 'Checking saved demand forecasts...'
                : _forecastNote(forecastSnap.data),
          ),
        if (!isBasicEdition && forecastSnap.hasData) ...<Widget>[
          const SizedBox(height: 6),
          AiFreshnessChip(
            hasData: highlightedForecast != null,
            timestamps: <DateTime?>[
              if (highlightedForecast != null)
                _forecastAiTimestamp(highlightedForecast),
            ],
            hasMissingTimestamp:
                highlightedForecast != null &&
                _forecastAiTimestamp(highlightedForecast) == null,
          ),
        ],
        if (_dataWarning(rows).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ScootNotice(
              tone: ScootTone.warning,
              title: 'Data warning',
              message: _dataWarning(rows),
            ),
          ),
      ],
    );
  }
}

class _SummaryStats {
  _SummaryStats({
    required this.orderCount,
    required this.revenue,
    required this.quantity,
    required this.retailers,
    required this.salesmen,
    required this.bestProduct,
    required this.bestRetailer,
    required this.topProducts,
    required this.topRetailers,
  });

  final int orderCount;
  final double revenue;
  final int quantity;
  final Set<String> retailers;
  final Set<String> salesmen;
  final _SummaryProduct? bestProduct;
  final _SummaryRetailer? bestRetailer;
  final List<_SummaryProduct> topProducts;
  final List<_SummaryRetailer> topRetailers;

  factory _SummaryStats.fromRows(List<Map<String, dynamic>> rows) {
    final Set<String> retailers = <String>{};
    final Set<String> salesmen = <String>{};
    final Map<String, _SummaryProduct> products = <String, _SummaryProduct>{};
    final Map<String, _SummaryRetailer> retailerAggs =
        <String, _SummaryRetailer>{};
    double revenue = 0;
    int quantity = 0;

    for (final Map<String, dynamic> row in rows) {
      final double rowRevenue = _rowRevenue(row);
      revenue += rowRevenue;
      quantity += _rowQuantity(row);

      final String retailer = _summaryText(
        row['retailerName'] ?? row['retailer_name'],
      );
      if (retailer.isNotEmpty) {
        retailers.add(retailer);
        final _SummaryRetailer agg = retailerAggs.putIfAbsent(
          retailer,
          () => _SummaryRetailer(name: retailer),
        );
        agg.orders += 1;
        agg.revenue += rowRevenue;
      }

      final String salesman = reportSalesmanKey(row);
      if (salesman.isNotEmpty) salesmen.add(salesman);

      final Object? rawItems =
          row['items'] ?? row['orderItems'] ?? row['order_items'];
      if (rawItems is List) {
        for (final Object? raw in rawItems) {
          if (raw is! Map) continue;
          final Map<String, dynamic> item = Map<String, dynamic>.from(raw);
          final String name = _summaryText(
            item['productName'] ??
                item['product_name'] ??
                item['itemName'] ??
                item['name'],
          );
          if (name.isEmpty) continue;
          final _SummaryProduct product = products.putIfAbsent(
            name,
            () => _SummaryProduct(name: name),
          );
          product.quantity += _itemQuantity(item);
          if (product.category.isEmpty) {
            product.category = _summaryText(
              item['category'] ??
                  item['categoryName'] ??
                  item['department'] ??
                  item['departmentName'],
            );
          }
        }
      }
    }

    final List<_SummaryProduct> sortedProducts = products.values.toList()
      ..sort(
        (_SummaryProduct a, _SummaryProduct b) =>
            b.quantity.compareTo(a.quantity),
      );
    final List<_SummaryRetailer> sortedRetailers = retailerAggs.values.toList()
      ..sort(
        (_SummaryRetailer a, _SummaryRetailer b) =>
            b.revenue.compareTo(a.revenue),
      );

    return _SummaryStats(
      orderCount: rows.length,
      revenue: revenue,
      quantity: quantity,
      retailers: retailers,
      salesmen: salesmen,
      bestProduct: sortedProducts.isEmpty ? null : sortedProducts.first,
      bestRetailer: sortedRetailers.isEmpty ? null : sortedRetailers.first,
      topProducts: sortedProducts.take(5).toList(growable: false),
      topRetailers: sortedRetailers.take(5).toList(growable: false),
    );
  }
}

class _SummaryProduct {
  _SummaryProduct({required this.name});
  final String name;
  int quantity = 0;
  String category = '';
}

class _SummaryRetailer {
  _SummaryRetailer({required this.name});
  final String name;
  int orders = 0;
  double revenue = 0;
}

Widget _summaryLine({
  required BuildContext context,
  required IconData icon,
  required String title,
  required String value,
}) {
  final ScootColors c = ScootColors.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: c.brand),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: ScootType.smallStrong.copyWith(color: c.ink)),
              const SizedBox(height: 2),
              Text(value, style: ScootType.body.copyWith(color: c.muted)),
            ],
          ),
        ),
      ],
    ),
  );
}

String _monthLabel(DateTime date) =>
    '${_monthNameText(date.month)} ${date.year}';

String _monthNameText(int month) {
  const List<String> names = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return names[month - 1];
}

String _movementText(int current, int previous) {
  if (previous == 0) {
    return 'There is no previous-month order baseline to compare against.';
  }
  if (current == previous) {
    return 'Orders were unchanged compared to the previous month.';
  }
  final double pct = ((current - previous) / previous) * 100;
  return 'Orders ${pct >= 0 ? 'increased' : 'decreased'} by ${pct.abs().toStringAsFixed(0)}% compared to the previous month.';
}

String _moneyMovementText(double current, double previous) {
  if (previous <= 0) return '';
  final double pct = ((current - previous) / previous) * 100;
  return 'Revenue ${pct >= 0 ? 'increased' : 'decreased'} by ${pct.abs().toStringAsFixed(0)}%.';
}

String _forecastNote(ForecastCatalogueSelection? selection) {
  if (selection == null) {
    return 'Checking saved demand forecasts...';
  }
  if (selection.rows.isEmpty) {
    if (selection.excludedCount > 0) {
      return '${selection.excludedCount} saved forecast row(s) are hidden '
          'because they are not in the master product catalogue.';
    }
    return 'No saved demand_forecasts data found for forecast notes.';
  }
  return _forecastNoteForRows(selection.rows);
}

String _forecastNoteForRows(List<Map<String, dynamic>> forecasts) {
  if (forecasts.isEmpty) {
    return 'No saved demand_forecasts data found for forecast notes.';
  }
  final Map<String, dynamic> highlighted =
      _highlightForecastRow(forecasts) ?? forecasts.first;
  final String product = _summaryText(
    highlighted['productName'] ??
        highlighted['product_name'] ??
        highlighted['productId'] ??
        highlighted['product_id'],
  );
  final String action = _summaryText(
    highlighted['recommendedAction'] ?? highlighted['recommended_action'],
  );
  if (product.isEmpty && action.isEmpty) {
    return 'Saved demand forecasts exist, but no product-level recommendation fields were found.';
  }
  return product.isEmpty
      ? action
      : '$product: ${action.isEmpty ? 'review saved forecast demand' : action}.';
}

Map<String, dynamic>? _highlightForecastRow(
  List<Map<String, dynamic>> forecasts,
) {
  if (forecasts.isEmpty) return null;
  final List<Map<String, dynamic>> latest = selectLatestForecastPeriod(
    forecasts,
  );
  for (final Map<String, dynamic> row in latest) {
    if (_summaryText(
      row['recommendedAction'] ?? row['recommended_action'],
    ).isNotEmpty) {
      return row;
    }
  }
  return latest.first;
}

DateTime? _forecastAiTimestamp(Map<String, dynamic> row) =>
    aiDataTimestamp(<String, dynamic>{
      ...row,
      'generatedAt':
          row['generatedAt'] ?? row['runCreatedAt'] ?? row['createdAt'],
    });

String _dataWarning(List<Map<String, dynamic>> rows) {
  final int missingRetailer = rows.where((Map<String, dynamic> row) {
    return _summaryText(row['retailerName'] ?? row['retailer_name']).isEmpty;
  }).length;
  final int missingItems = rows.where((Map<String, dynamic> row) {
    final Object? items =
        row['items'] ?? row['orderItems'] ?? row['order_items'];
    return items is! List || items.isEmpty;
  }).length;
  final int unpriced = rows.where(orderLacksLinePrices).length;
  if (missingRetailer == 0 && missingItems == 0 && unpriced == 0) return '';
  final String unpricedNote = unpriced == 0
      ? ''
      : ' $unpriced order(s) have no line prices recorded, so their products add no revenue to the product totals.';
  return '$missingRetailer order(s) are missing retailer names and $missingItems order(s) have no item list.$unpricedNote';
}

double _rowRevenue(Map<String, dynamic> row) {
  return orderRevenue(row);
}

int _rowQuantity(Map<String, dynamic> row) {
  return orderQuantity(row);
}

int _itemQuantity(Map<String, dynamic> item) {
  return itemQuantity(item);
}

String _summaryText(Object? value) {
  if (value == null) return '';
  final String text = value.toString().trim();
  return text.isEmpty || text.toLowerCase() == 'null' ? '' : text;
}

class _OrderTrendTab extends StatelessWidget {
  const _OrderTrendTab({required this.rows, required this.monthAnchor});

  final List<Map<String, dynamic>> rows;
  final DateTime monthAnchor;

  @override
  Widget build(BuildContext context) {
    final List<_WeekBucket> weeks = _bucketByWeek(rows, monthAnchor);
    if (weeks.every((_WeekBucket w) => w.orders == 0)) {
      return const _EmptyState(
        icon: Icons.show_chart,
        label: 'No orders recorded for this month yet.',
      );
    }
    final int maxOrders = weeks.fold<int>(
      0,
      (int m, _WeekBucket w) => w.orders > m ? w.orders : m,
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        itemCount: weeks.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (BuildContext _, int index) {
          final _WeekBucket week = weeks[index];
          final double ratio = maxOrders == 0 ? 0 : week.orders / maxOrders;
          return Row(
            children: <Widget>[
              SizedBox(
                width: 70,
                child: Text(
                  week.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              SizedBox(
                width: 140,
                child: Text(
                  '${_fmt(week.start)} – ${_fmt(week.end)}',
                  style: TextStyle(fontSize: 12, color: context.dso.muted),
                ),
              ),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Container(
                      height: 22,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: ratio.clamp(0.0, 1.0),
                      child: Container(
                        height: 22,
                        decoration: BoxDecoration(
                          color: const Color(0xFF27AE60),
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 60,
                child: Text(
                  '${week.orders}',
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: Text(
                  formatRm(week.revenue),
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 12, color: context.dso.body),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<_WeekBucket> _bucketByWeek(
    List<Map<String, dynamic>> rows,
    DateTime month,
  ) {
    final DateTime monthStart = DateTime(month.year, month.month);
    final DateTime monthEndExclusive = DateTime(month.year, month.month + 1);
    final List<_WeekBucket> weeks = <_WeekBucket>[];
    DateTime weekStart = monthStart.subtract(
      Duration(days: monthStart.weekday - 1),
    );
    int idx = 1;
    while (weekStart.isBefore(monthEndExclusive)) {
      final DateTime weekEnd = weekStart.add(const Duration(days: 6));
      final DateTime visibleStart = weekStart.isBefore(monthStart)
          ? monthStart
          : weekStart;
      final DateTime visibleEndInc =
          weekEnd.isAfter(monthEndExclusive.subtract(const Duration(days: 1)))
          ? monthEndExclusive.subtract(const Duration(days: 1))
          : weekEnd;
      weeks.add(
        _WeekBucket(
          label: 'Week $idx',
          start: visibleStart,
          end: visibleEndInc,
        ),
      );
      weekStart = weekStart.add(const Duration(days: 7));
      idx += 1;
    }
    for (final Map<String, dynamic> r in rows) {
      final DateTime? submitted = orderDateFromRow(r);
      if (submitted == null) continue;
      for (final _WeekBucket w in weeks) {
        if (!submitted.isBefore(w.start) &&
            submitted.isBefore(w.end.add(const Duration(days: 1)))) {
          w.orders += 1;
          w.revenue += orderRevenue(r);
          break;
        }
      }
    }
    return weeks;
  }

  String _fmt(DateTime d) => '${d.day}/${d.month}';
}

class _WeekBucket {
  _WeekBucket({required this.label, required this.start, required this.end});
  final String label;
  final DateTime start;
  final DateTime end;
  int orders = 0;
  double revenue = 0;
}

class _TopProductsTab extends StatelessWidget {
  const _TopProductsTab({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final Map<String, _ProductAgg> aggs = <String, _ProductAgg>{};
    for (final Map<String, dynamic> order in rows) {
      for (final Map<String, dynamic> item in authoritativeOrderItems(order)) {
        final String name =
            '${item['productName'] ?? item['name'] ?? item['itemName'] ?? ''}'
                .trim();
        if (name.isEmpty) continue;
        final _ProductAgg agg = aggs.putIfAbsent(
          name,
          () => _ProductAgg(productName: name),
        );
        final int qty =
            (dataNumberOrNull(item['qty']) ??
                    dataNumberOrNull(item['orderedQty']) ??
                    0)
                .toInt();
        final double price =
            dataNumberOrNull(item['price']) ??
            dataNumberOrNull(item['unitPrice']) ??
            0.0;
        agg.totalQty += qty;
        agg.totalRevenue += qty * price;
        agg.orderCount += 1;
        if (agg.department.isEmpty) {
          agg.department =
              '${item['department'] ?? item['departmentName'] ?? ''}'.trim();
        }
      }
    }
    if (aggs.isEmpty) {
      return const _EmptyState(
        icon: Icons.inventory_2_outlined,
        label: 'No product activity for this month yet.',
      );
    }
    final List<_ProductAgg> sorted = aggs.values.toList()
      ..sort(
        (_ProductAgg a, _ProductAgg b) => b.totalQty.compareTo(a.totalQty),
      );
    final int maxQty = sorted.first.totalQty;
    return _rankList(
      sorted.take(20).toList(),
      context: context,
      maxValue: maxQty,
      headerLabel: 'Product',
      rightLabel: 'Qty',
      builder: (_ProductAgg agg) => <Widget>[
        Expanded(
          flex: 6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                agg.productName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              if (agg.department.isNotEmpty)
                Text(
                  agg.department,
                  style: TextStyle(fontSize: 11, color: context.dso.muted),
                ),
            ],
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            formatRm(agg.totalRevenue),
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 12, color: context.dso.body),
          ),
        ),
      ],
      valueOf: (_ProductAgg a) => a.totalQty,
    );
  }
}

class _ProductAgg {
  _ProductAgg({required this.productName});
  final String productName;
  int totalQty = 0;
  int orderCount = 0;
  double totalRevenue = 0;
  String department = '';
}

class _TopRetailersTab extends StatelessWidget {
  const _TopRetailersTab({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final Map<String, _RetailerAgg> aggs = <String, _RetailerAgg>{};
    int skippedNoRetailer = 0;
    for (final Map<String, dynamic> order in rows) {
      final String name =
          '${order['retailerName'] ?? order['retailer_name'] ?? ''}'.trim();
      if (name.isEmpty || name.toLowerCase() == 'null') {
        skippedNoRetailer += 1;
        continue;
      }
      final String key =
          '${order['retailerId'] ?? order['retailer_id'] ?? name}'.trim();
      final _RetailerAgg agg = aggs.putIfAbsent(
        key,
        () => _RetailerAgg(retailerName: name),
      );
      agg.orderCount += 1;
      agg.totalRevenue += orderRevenue(order);
      agg.totalBoxes += orderQuantity(order);
    }
    if (aggs.isEmpty) {
      return const _EmptyState(
        icon: Icons.storefront_outlined,
        label: 'No retailer activity for this month yet.',
      );
    }
    final List<_RetailerAgg> sorted = aggs.values.toList()
      ..sort(
        (_RetailerAgg a, _RetailerAgg b) =>
            b.totalRevenue.compareTo(a.totalRevenue),
      );
    final double maxRevenue = sorted.first.totalRevenue;
    final Widget table = _rankList(
      sorted.take(20).toList(),
      context: context,
      maxValue: maxRevenue,
      headerLabel: 'Retailer',
      rightLabel: 'Revenue',
      builder: (_RetailerAgg agg) => <Widget>[
        Expanded(
          flex: 6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                agg.retailerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                '${agg.orderCount} order${agg.orderCount == 1 ? '' : 's'} • ${agg.totalBoxes} box${agg.totalBoxes == 1 ? '' : 'es'}',
                style: TextStyle(fontSize: 11, color: context.dso.muted),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            formatRm(agg.totalRevenue),
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: context.dso.successText,
            ),
          ),
        ),
      ],
      valueOf: (_RetailerAgg a) => a.totalRevenue,
    );
    if (skippedNoRetailer == 0) return table;
    return Column(
      children: <Widget>[
        Expanded(child: table),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: context.dso.warningSoft,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: context.dso.warning.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.info_outline,
                size: 16,
                color: context.dso.warningText,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$skippedNoRetailer order${skippedNoRetailer == 1 ? '' : 's'} excluded from this tab '
                  'because they have no retailer attached. They still count toward the headline totals above.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.dso.warningText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RetailerAgg {
  _RetailerAgg({required this.retailerName});
  final String retailerName;
  int orderCount = 0;
  int totalBoxes = 0;
  double totalRevenue = 0;
}

Widget _rankList<T>(
  List<T> items, {
  required BuildContext context,
  required num maxValue,
  required String headerLabel,
  required String rightLabel,
  required List<Widget> Function(T) builder,
  required num Function(T) valueOf,
}) {
  return Container(
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 30),
              Expanded(
                flex: 6,
                child: Text(
                  headerLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: context.dso.body,
                  ),
                ),
              ),
              const Expanded(flex: 4, child: SizedBox.shrink()),
              Expanded(
                flex: 3,
                child: Text(
                  rightLabel,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: context.dso.body,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: items.length,
            padding: EdgeInsets.zero,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            itemBuilder: (BuildContext _, int index) {
              final T item = items[index];
              final num value = valueOf(item);
              final double ratio = maxValue == 0
                  ? 0
                  : (value / maxValue).clamp(0.0, 1.0).toDouble();
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                color: index.isEven
                    ? Theme.of(context).colorScheme.surface
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 30,
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: context.dso.subtle,
                        ),
                      ),
                    ),
                    ...builder(item),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 4,
                      child: Stack(
                        children: <Widget>[
                          Container(
                            height: 6,
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: ratio,
                            child: Container(
                              height: 6,
                              margin: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF27AE60),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.width,
    required this.label,
    required this.value,
    this.change,
  });

  final double width;
  final String label;
  final String value;
  final String? change;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: ScootType.small.copyWith(color: c.muted)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ScootType.kpi.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(change ?? ' ', style: ScootType.small.copyWith(color: c.muted)),
        ],
      ),
    );
  }
}

class _ReportsSkeleton extends StatelessWidget {
  const _ReportsSkeleton({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: ScootLoadingState(
        onRetry: onRetry,
        semanticLabel: 'Loading reports',
        skeleton: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: <Widget>[
                for (int i = 0; i < 5; i++)
                  const ScootSkeleton(width: 200, height: 92, radius: 12),
              ],
            ),
            const SizedBox(height: 24),
            const ScootSkeletonLines(
              widthFactors: <double>[0.9, 0.8, 0.7, 0.85, 0.6],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.label,
    this.message,
    this.action,
  });

  final IconData icon;
  final String label;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ScootCard(
      child: ScootEmptyState(
        icon: ScootIcons.inbox,
        title: label,
        message: message,
        action: action,
      ),
    );
  }
}

class _ScopeNotice extends StatelessWidget {
  const _ScopeNotice({required this.rawCount, required this.isBranch});

  final int rawCount;
  final bool isBranch;

  @override
  Widget build(BuildContext context) {
    return ScootNotice(
      tone: ScootTone.warning,
      icon: ScootIcons.info,
      title: isBranch ? 'Branch scope' : 'Team scope',
      message: isBranch
          ? 'None of the orders this month are from your branch.'
          : 'None of the orders this month are from your team.',
    );
  }
}
