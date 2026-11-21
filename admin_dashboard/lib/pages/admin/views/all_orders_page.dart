import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/csv_downloader.dart';
import '../../../utils/collection_rows.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/order_csv.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/order_id_resolver.dart';
import '../../../utils/order_waiting_statuses.dart';
import '../../../utils/server_price_check.dart';
import '../../../widgets/dso_filter_controls.dart';
import '../../../widgets/tip_text.dart';
import '../widgets/cms_panel.dart';
import '../widgets/order_details_dialog.dart';
import '../../../utils/money_format.dart';
import '../../../security/team_scope.dart';

OrderPageCursor? oldestOrderPageCursor(Iterable<Map<String, dynamic>> rows) {
  OrderPageCursor? oldest;
  for (final Map<String, dynamic> row in rows) {
    final Object? value = row['submittedAt'];
    final Object? rawDocumentId = row['docId'];
    final String documentId = rawDocumentId is String ? rawDocumentId : '';
    if (value is! Timestamp || documentId.isEmpty) continue;
    if (oldest == null) {
      oldest = OrderPageCursor(submittedAt: value, documentId: documentId);
      continue;
    }
    final int timestampComparison = value.compareTo(oldest.submittedAt);
    if (timestampComparison < 0 ||
        (timestampComparison == 0 &&
            documentId.compareTo(oldest.documentId) < 0)) {
      oldest = OrderPageCursor(submittedAt: value, documentId: documentId);
    }
  }
  return oldest;
}

int compareOrderPageCursor(OrderPageCursor a, OrderPageCursor b) {
  final int byTime = b.submittedAt.compareTo(a.submittedAt);
  return byTime != 0 ? byTime : b.documentId.compareTo(a.documentId);
}

class AllOrdersPage extends StatefulWidget {
  const AllOrdersPage({
    super.key,
    required this.currentUser,
    this.viewOnly = false,
  });

  final UserProfile currentUser;

  final bool viewOnly;

  @override
  State<AllOrdersPage> createState() => _AllOrdersPageState();
}

class _AllOrdersPageState extends State<AllOrdersPage> {
  final CmsRepository _repository = CmsRepository();
  final TextEditingController _searchController = TextEditingController();
  final GlobalKey _filtersKey = GlobalKey();

  String _statusFilter = 'all';
  String _salesmanFilter = 'all';
  String _retailerFilter = 'all';
  DateTimeRange? _dateRange;

  static const int _olderPageSize = 200;
  final List<Map<String, dynamic>> _olderOrders = <Map<String, dynamic>>[];
  final Map<String, _OrderStatusOverride> _statusOverrides =
      <String, _OrderStatusOverride>{};
  bool _loadingOlder = false;
  bool _reachedEnd = false;
  bool _exporting = false;
  int _pagesLoaded = 1;
  String _filterSignature = '';

  OrderPageCursor? _historyTop;
  bool _backfilling = false;

  static const String _ordersOrderBy = 'submittedAt';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<bool> _loadOlderOrders(List<Map<String, dynamic>> currentRows) async {
    if (_loadingOlder) return true;
    if (_reachedEnd) return true;
    setState(() => _loadingOlder = true);
    try {
      final OrderPageCursor? cursor = _olderOrders.isNotEmpty
          ? oldestOrderPageCursor(_olderOrders)
          : oldestOrderPageCursor(currentRows);
      final List<Map<String, dynamic>> page = await _repository
          .getOrdersPageBefore(before: cursor, limit: _olderPageSize);
      if (!mounted) return false;
      setState(() {
        if (_olderOrders.isEmpty) _historyTop = cursor;
        final Set<String> known = <String>{
          ...currentRows.map((Map<String, dynamic> row) => '${row['docId']}'),
          ..._olderOrders.map((Map<String, dynamic> row) => '${row['docId']}'),
        };
        _olderOrders.addAll(
          page.where(
            (Map<String, dynamic> row) => !known.contains('${row['docId']}'),
          ),
        );
        if (page.length < _olderPageSize) _reachedEnd = true;
        _loadingOlder = false;
      });
      return true;
    } catch (_) {
      if (mounted) setState(() => _loadingOlder = false);
      return false;
    }
  }

  Future<void> _backfillGap(OrderPageCursor liveOldest) async {
    final OrderPageCursor? top = _historyTop;
    if (_backfilling || top == null) return;
    _backfilling = true;
    try {
      final List<Map<String, dynamic>> gap = <Map<String, dynamic>>[];
      OrderPageCursor? cursor = liveOldest;
      bool reachedTop = false;
      while (!reachedTop && cursor != null) {
        final List<Map<String, dynamic>> page = await _repository
            .getOrdersPageBefore(before: cursor, limit: _olderPageSize);
        for (final Map<String, dynamic> row in page) {
          final OrderPageCursor? at = oldestOrderPageCursor(
            <Map<String, dynamic>>[row],
          );
          if (at == null) continue;
          if (compareOrderPageCursor(at, top) > 0) {
            reachedTop = true;
            break;
          }
          gap.add(row);
        }
        if (page.length < _olderPageSize) break;
        cursor = oldestOrderPageCursor(page);
      }
      if (!mounted) return;
      setState(() {
        final Set<String> known = _olderOrders
            .map((Map<String, dynamic> row) => '${row['docId']}')
            .toSet();
        _olderOrders.insertAll(
          0,
          gap.where(
            (Map<String, dynamic> row) => !known.contains('${row['docId']}'),
          ),
        );
        _historyTop = liveOldest;
      });
    } catch (_) {
    } finally {
      _backfilling = false;
    }
  }

  Future<void> _retryOrdersStream() async {
    await _repository.resetCollectionStream(
      'orders',
      orderBy: _ordersOrderBy,
      descending: true,
    );
    if (!mounted) return;
    setState(() {
      _olderOrders.clear();
      _historyTop = null;
      _reachedEnd = false;
      _loadingOlder = false;
    });
  }

  List<ScootTableColumn<Map<String, dynamic>>> _columns(
    Set<String> possibleDuplicates, {
    required bool cards,
    required Set<String> repeatedReferences,
  }) {
    return <ScootTableColumn<Map<String, dynamic>>>[
      ScootTableColumn<Map<String, dynamic>>(
        label: 'Order ID',
        flex: 4,
        cell: (BuildContext context, Map<String, dynamic> order) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (cards)
              OrderCardReference(
                orderId: _text(order['orderId'] ?? order['docId']),
                repeated: repeatedReferences,
              )
            else
              TipText(
                _text(order['orderId'] ?? order['docId']),
                style: ScootType.bodyStrong,
              ),
            if (possibleDuplicates.contains(
              _text(order['docId'] ?? order['orderId']),
            ))
              const PossibleDuplicateChip(),
          ],
        ),
      ),
      ScootTableColumn<Map<String, dynamic>>(
        label: 'Retailer',
        flex: 5,
        cell: (BuildContext context, Map<String, dynamic> order) => TipText(
          _text(order['retailerName'] ?? order['retailer_name'], fallback: '—'),
        ),
      ),
      ScootTableColumn<Map<String, dynamic>>(
        label: 'Salesman',
        flex: 4,
        cell: (BuildContext context, Map<String, dynamic> order) => TipText(
          _text(order['salesmanName'] ?? order['salesman_name'], fallback: '—'),
        ),
      ),
      ScootTableColumn<Map<String, dynamic>>(
        label: 'Submitted',
        flex: 4,
        cell: (BuildContext context, Map<String, dynamic> order) => Text(
          _formatDate(_toDate(order['submittedAt'] ?? order['createdAt'])),
          style: ScootType.body.copyWith(color: ScootColors.of(context).muted),
        ),
      ),
      ScootTableColumn<Map<String, dynamic>>(
        label: 'Items',
        flex: 2,
        numeric: true,
        cell: (BuildContext context, Map<String, dynamic> order) =>
            Text('${orderItemCount(order)}'),
      ),
      ScootTableColumn<Map<String, dynamic>>(
        label: 'Total',
        flex: 3,
        numeric: true,
        cell: (BuildContext context, Map<String, dynamic> order) => Text(
          formatRm(dataNumber(order['totalPrice'])),
          style: ScootType.bodyStrong,
        ),
      ),
      ScootTableColumn<Map<String, dynamic>>(
        label: 'Status',
        flex: 3,
        cell: (BuildContext context, Map<String, dynamic> order) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: _statusPill(_text(order['status'], fallback: 'submitted')),
            ),
            if (ServerPriceCheck.fromOrder(order) != null) ...<Widget>[
              const SizedBox(width: 6),
              ServerPriceCheckMark(check: ServerPriceCheck.fromOrder(order)!),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _ordersTable(
    List<Map<String, dynamic>> filtered,
    List<Map<String, dynamic>> streamRows, {
    ScootLoadPhase phase = ScootLoadPhase.ready,
    bool cards = false,
    bool liveComplete = false,
    List<Map<String, dynamic>> loaded = const <Map<String, dynamic>>[],
  }) {
    final Set<String> possibleDuplicates = possibleDuplicateOrders(filtered);
    final Set<String> repeatedReferences = cards
        ? repeatedShortOrderReferences(
            loaded.map(
              (Map<String, dynamic> order) =>
                  _text(order['orderId'] ?? order['docId']),
            ),
          )
        : const <String>{};
    final bool moreLoaded =
        _pagesLoaded * ScootPaging.pageSize < filtered.length;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: ScootColors.of(context).line),
        borderRadius: ScootRadius.cardAll,
      ),
      clipBehavior: Clip.antiAlias,
      child: ScootDataTable<Map<String, dynamic>>(
        columns: _columns(
          possibleDuplicates,
          cards: cards,
          repeatedReferences: repeatedReferences,
        ),
        rows: filtered,
        phase: phase,
        onRetry: _retryOrdersStream,
        emptyTitle: 'No orders found',
        emptyMessage: _anyFilterActive
            ? 'Try other filters.'
            : 'Orders will show here when salespeople submit them.',
        pagesLoaded: _pagesLoaded,
        hasMore: ordersHaveMore(
          moreLoaded: moreLoaded,
          reachedEnd: _reachedEnd,
          liveComplete: liveComplete,
        ),
        loadingMore: _loadingOlder,
        onLoadMore: (_loadingOlder || _exporting)
            ? null
            : () {
                if (moreLoaded) {
                  setState(() => _pagesLoaded++);
                } else {
                  _loadOlderOrders(streamRows).then((bool ok) {
                    if (ok && mounted) setState(() => _pagesLoaded++);
                  });
                }
              },
        onRowTap: _openOrder,
        rowLabel: (Map<String, dynamic> order) =>
            'Order ${_text(order['orderId'] ?? order['docId'])}, '
            '${_text(order['retailerName'] ?? order['retailer_name'], fallback: 'no retailer')}',
        countLabel: ordersLoadedLabel(
          filtered.length,
          all: _reachedEnd || liveComplete,
        ),
        live: true,
        minTableWidth: OrdersListLayout.minTableWidth,
      ),
    );
  }

  Future<void> _openOrder(Map<String, dynamic> order) async {
    final String documentId = OrderIdResolver.resolve(order);
    if (documentId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This order could not be opened. Reload the list and try again.',
          ),
        ),
      );
      return;
    }
    final String? action = await OrderDetailsDialog.show(
      context,
      orderDocumentId: documentId,
      repository: _repository,
      initialOrder: order,
      currentUser: widget.currentUser,
      showActions: !widget.viewOnly,
    );
    if (!mounted) return;
    if (action == 'delete') {
      setState(
        () => _olderOrders.removeWhere(
          (Map<String, dynamic> row) =>
              OrderIdResolver.resolve(row) == documentId,
        ),
      );
      return;
    }
    if (action != 'approve' && action != 'reject') return;
    setState(() {
      _statusOverrides[documentId] = _OrderStatusOverride(
        status: action == 'approve' ? 'approved' : 'rejected',
        appliedAt: DateTime.now().toUtc(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return CmsPanel(
      title: widget.viewOnly ? 'Branch order list' : 'Order list',
      trailing: _SmallChip(
        label: widget.viewOnly ? 'View only' : 'Live records',
      ),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _repository.watchCollection(
          'orders',
          orderBy: _ordersOrderBy,
          descending: true,
        ),
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
            ) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: _ordersTable(
                    const <Map<String, dynamic>>[],
                    const <Map<String, dynamic>>[],
                    phase: ScootLoadPhase.loading,
                  ),
                );
              }
              if (snapshot.hasError && !snapshot.hasData) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: _ordersTable(
                    const <Map<String, dynamic>>[],
                    const <Map<String, dynamic>>[],
                    phase: ScootLoadPhase.error,
                  ),
                );
              }
              final List<Map<String, dynamic>> streamRows =
                  _applyStatusOverrides(
                    snapshot.data ?? <Map<String, dynamic>>[],
                  );
              final Set<String> streamIds = streamRows
                  .map((Map<String, dynamic> row) => '${row['docId']}')
                  .toSet();
              final OrderPageCursor? liveOldest = oldestOrderPageCursor(
                streamRows,
              );
              final OrderPageCursor? historyTop = _historyTop;
              if (historyTop != null &&
                  liveOldest != null &&
                  !_backfilling &&
                  compareOrderPageCursor(liveOldest, historyTop) < 0) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _backfillGap(liveOldest),
                );
              }
              final List<Map<String, dynamic>> allRows = <Map<String, dynamic>>[
                ...streamRows,
                ..._applyStatusOverrides(_olderOrders).where(
                  (Map<String, dynamic> row) =>
                      !streamIds.contains('${row['docId']}'),
                ),
              ];
              final List<Map<String, dynamic>> orders = _scope(allRows);
              final List<Map<String, dynamic>> filtered = _applyFilters(orders);
              final String signature =
                  '${_searchController.text}|$_statusFilter|$_salesmanFilter|$_retailerFilter|$_dateRange';
              if (signature != _filterSignature) {
                _filterSignature = signature;
                _pagesLoaded = 1;
              }

              final List<String> salesmen = _distinctValues(orders, <String>[
                'salesmanName',
                'salesman_name',
              ]);
              final List<String> retailers = _distinctValues(orders, <String>[
                'retailerName',
                'retailer_name',
              ]);

              return OrdersListLayout(
                filters: KeyedSubtree(
                  key: _filtersKey,
                  child: _filtersBar(
                    salesmen: salesmen,
                    retailers: retailers,
                    filtered: filtered,
                    totalBeforeFilter: orders.length,
                  ),
                ),
                tableBuilder: (bool cards) => _ordersTable(
                  filtered,
                  streamRows,
                  cards: cards,
                  liveComplete: collectionRowsComplete(snapshot.data),
                  loaded: orders,
                ),
                rowCount: filtered.length,
                note: _exporting
                    ? Text(
                        'Loading orders for export… ${orders.length} loaded',
                        style: ScootType.small.copyWith(
                          color: context.dso.muted,
                        ),
                      )
                    : null,
              );
            },
      ),
    );
  }

  bool get _anyFilterActive =>
      _searchController.text.isNotEmpty ||
      _statusFilter != 'all' ||
      _salesmanFilter != 'all' ||
      _retailerFilter != 'all' ||
      _dateRange != null;

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _statusFilter = 'all';
      _salesmanFilter = 'all';
      _retailerFilter = 'all';
      _dateRange = null;
    });
  }

  Widget _filtersBar({
    required List<String> salesmen,
    required List<String> retailers,
    required List<Map<String, dynamic>> filtered,
    required int totalBeforeFilter,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget countText = Text(
      'Showing ${filtered.length} of $totalBeforeFilter orders',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: context.dso.muted),
    );
    final Widget exportButton = DsoFilterButton(
      icon: ScootIcons.download,
      label: 'Export CSV',
      showChevron: false,
      onPressed: (_exporting || _loadingOlder) ? null : () => _exportCsv(),
    );
    final List<Widget> controls = <Widget>[
      DsoFilterSearchField(
        controller: _searchController,
        width: 280,
        hintText: 'Search ID, retailer, salesman',
        onChanged: (_) => setState(() {}),
      ),
      _filterMenu(
        label: 'Status',
        value: _statusFilter,
        options: const <String>[
          'all',
          'waiting',
          'submitted',
          'held_for_review',
          'approved',
          'rejected',
        ],
        capitalise: true,
        onChanged: (String value) => setState(() => _statusFilter = value),
      ),
      _filterMenu(
        label: 'Salesman',
        value: _salesmanFilter,
        options: <String>['all', ...salesmen],
        onChanged: (String value) => setState(() => _salesmanFilter = value),
      ),
      _filterMenu(
        label: 'Retailer',
        value: _retailerFilter,
        options: <String>['all', ...retailers],
        onChanged: (String value) => setState(() => _retailerFilter = value),
      ),
      DsoFilterButton(
        icon: ScootIcons.calendar,
        label: _dateRangeLabel(),
        active: _dateRange != null,
        onPressed: _pickDateRange,
      ),
      if (_anyFilterActive)
        TextButton(
          onPressed: _clearFilters,
          style: TextButton.styleFrom(
            textStyle: const TextStyle(fontSize: DsoFilterMetrics.fontSize),
            foregroundColor: scheme.primary,
            minimumSize: const Size(0, DsoFilterMetrics.height),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Clear search and filters'),
        ),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 900;
        Widget wrap(List<Widget> children) => Wrap(
          spacing: DsoFilterMetrics.gap,
          runSpacing: DsoFilterMetrics.gap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(child: wrap(controls)),
              const SizedBox(width: 12),
              countText,
              const SizedBox(width: 12),
              exportButton,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            wrap(<Widget>[...controls, exportButton]),
            const SizedBox(height: 8),
            countText,
          ],
        );
      },
    );
  }

  Widget _filterMenu({
    required String label,
    required String value,
    required List<String> options,
    required ValueChanged<String> onChanged,
    bool capitalise = false,
  }) {
    final String current = options.contains(value) ? value : 'all';
    String display(String o) => capitalise && o.isNotEmpty
        ? '${o[0].toUpperCase()}${o.substring(1).replaceAll('_', ' ')}'
        : o;
    return MenuAnchor(
      style: const MenuStyle(
        maximumSize: WidgetStatePropertyAll<Size>(Size(320, 360)),
      ),
      menuChildren: options
          .map(
            (String o) => MenuItemButton(
              style: MenuItemButton.styleFrom(
                minimumSize: const Size(0, DsoFilterMetrics.height),
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              leadingIcon: Icon(
                o == current ? ScootIcons.check : null,
                size: DsoFilterMetrics.iconSize,
              ),
              onPressed: () => onChanged(o),
              child: Text(
                o == 'all' ? 'All' : display(o),
                style: const TextStyle(fontSize: DsoFilterMetrics.fontSize),
              ),
            ),
          )
          .toList(growable: false),
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: DsoFilterButton(
            label: current == 'all'
                ? '$label: All'
                : '$label: ${display(current)}',
            active: current != 'all',
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        );
      },
    );
  }

  Future<void> _pickDateRange() async {
    final DateTime now = DateTime.now();
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _dateRange,
    );
    if (picked != null) setState(() => _dateRange = picked);
  }

  String _dateRangeLabel() {
    if (_dateRange == null) return 'Date: Any';
    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
    return 'Date: ${fmt(_dateRange!.start)}–${fmt(_dateRange!.end)}';
  }

  List<Map<String, dynamic>> _scope(List<Map<String, dynamic>> orders) {
    return TeamScope.filter(
      widget.currentUser,
      orders.where((Map<String, dynamic> order) => !isDemoRow(order)),
    );
  }

  _OrderFilterSnapshot _currentOrderFilters() => _OrderFilterSnapshot(
    searchText: _searchController.text,
    status: _statusFilter,
    salesman: _salesmanFilter,
    retailer: _retailerFilter,
    dateRange: _dateRange,
  );

  List<Map<String, dynamic>> _applyFilters(
    List<Map<String, dynamic>> orders, {
    _OrderFilterSnapshot? filters,
  }) {
    final _OrderFilterSnapshot activeFilters =
        filters ?? _currentOrderFilters();
    final String query = activeFilters.searchText.trim().toLowerCase();
    final DateTimeRange? dateRange = activeFilters.dateRange;
    return orders
        .where((Map<String, dynamic> order) {
          if (activeFilters.status != 'all') {
            final String status = _text(order['status']).toLowerCase();
            final String effective = status.isEmpty ? 'submitted' : status;
            final bool matches = activeFilters.status == 'waiting'
                ? kWaitingForApprovalStatuses.contains(effective)
                : effective == activeFilters.status;
            if (!matches) return false;
          }
          if (activeFilters.salesman != 'all') {
            final String name = _text(
              order['salesmanName'] ?? order['salesman_name'],
            );
            if (name != activeFilters.salesman) return false;
          }
          if (activeFilters.retailer != 'all') {
            final String retailer = _text(
              order['retailerName'] ?? order['retailer_name'],
            );
            if (retailer != activeFilters.retailer) return false;
          }
          if (dateRange != null) {
            final DateTime? submitted = orderDateFromRow(order);
            if (submitted == null) return false;
            final DateTime start = DateTime(
              dateRange.start.year,
              dateRange.start.month,
              dateRange.start.day,
            );
            final DateTime endExclusive = DateTime(
              dateRange.end.year,
              dateRange.end.month,
              dateRange.end.day,
            ).add(const Duration(days: 1));
            if (submitted.isBefore(start) ||
                !submitted.isBefore(endExclusive)) {
              return false;
            }
          }
          if (query.isNotEmpty) {
            final String haystack = <String>[
              _text(order['orderId']),
              _text(order['docId']),
              _text(order['retailerName'] ?? order['retailer_name']),
              _text(order['salesmanName'] ?? order['salesman_name']),
            ].join(' ').toLowerCase();
            if (!haystack.contains(query)) return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  List<String> _distinctValues(
    List<Map<String, dynamic>> orders,
    List<String> keys,
  ) {
    final Set<String> seen = <String>{};
    for (final Map<String, dynamic> order in orders) {
      for (final String k in keys) {
        final String v = _text(order[k]);
        if (v.isNotEmpty) {
          seen.add(v);
          break;
        }
      }
    }
    final List<String> sorted = seen.toList()..sort();
    return sorted;
  }

  Widget _statusPill(String status) {
    final ScootTone tone = switch (status.toLowerCase()) {
      'approved' => ScootTone.success,
      'rejected' => ScootTone.danger,
      'pending' => ScootTone.warning,
      _ => ScootTone.info,
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: ScootBadge(label: orderStatusLabel(status), tone: tone),
    );
  }

  Future<void> _exportCsv() async {
    if (_exporting || _loadingOlder) return;
    final _OrderFilterSnapshot filters = _currentOrderFilters();
    final DateTime exportStartedAt = DateTime.now();
    setState(() => _exporting = true);
    try {
      late final List<Map<String, dynamic>> allOrders;
      try {
        allOrders = await _repository.getOrdersForExport();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not load all orders. Export cancelled.'),
            ),
          );
        }
        return;
      }
      if (!mounted) return;

      final List<Map<String, dynamic>> filtered = _applyFilters(
        _scope(allOrders),
        filters: filters,
      );
      if (filtered.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nothing to export for the current filters.'),
          ),
        );
        return;
      }

      final DateTimeRange? selectedRange = filters.dateRange;
      final String dateRange = selectedRange == null
          ? 'all_dates'
          : '${_dateStamp(selectedRange.start)}_to_${_dateStamp(selectedRange.end)}';
      final bool ok = downloadCsv(
        filename:
            'orders_export_${dateRange}_${_fileStamp(exportStartedAt)}.csv',
        csv: buildOrdersCsv(filtered),
      );
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Export is only available in the web build.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _dateStamp(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';

  String _fileStamp(DateTime now) {
    return '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
  }

  String _text(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    final String text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
    return text;
  }

  List<Map<String, dynamic>> _applyStatusOverrides(
    List<Map<String, dynamic>> rows,
  ) {
    if (_statusOverrides.isEmpty) return rows;
    return rows
        .map((Map<String, dynamic> row) {
          final String id = OrderIdResolver.resolve(row);
          final _OrderStatusOverride? override = _statusOverrides[id];
          if (override == null) return row;

          final String serverStatus = _text(row['status']).toLowerCase();
          if (serverStatus == override.status ||
              _serverUpdatedAfter(row, override.appliedAt)) {
            _statusOverrides.remove(id);
            return row;
          }
          return <String, dynamic>{...row, 'status': override.status};
        })
        .toList(growable: false);
  }

  bool _serverUpdatedAfter(Map<String, dynamic> row, DateTime appliedAt) {
    final DateTime? serverUpdatedAt = parseFlexibleDate(
      row['updatedAt'] ?? row['updated_at'],
    );
    if (serverUpdatedAt == null) return false;
    return !serverUpdatedAt.toUtc().isBefore(appliedAt);
  }

  DateTime? _toDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '—';
    final DateTime local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

String ordersLoadedLabel(int count, {required bool all}) =>
    '$count ${count == 1 ? 'order' : 'orders'} loaded${all ? ' (all)' : ''}';

bool ordersHaveMore({
  required bool moreLoaded,
  required bool reachedEnd,
  required bool liveComplete,
}) => moreLoaded || !(reachedEnd || liveComplete);

class OrdersListLayout extends StatelessWidget {
  const OrdersListLayout({
    super.key,
    required this.filters,
    required this.tableBuilder,
    this.rowCount,
    this.note,
  });

  final Widget filters;
  final Widget Function(bool cards) tableBuilder;
  final int? rowCount;
  final Widget? note;

  static const double minTableWidth = 760;
  static const double minCardListHeight = 200;
  static const double shortestCardHeight = 100;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compactHeight =
            constraints.maxHeight < 360 ||
            MediaQuery.sizeOf(context).height < 360;
        final bool cards = constraints.maxWidth - 32 < minTableWidth;
        final Widget table = tableBuilder(cards);
        final List<Widget> noteBelow = <Widget>[
          if (note != null) ...<Widget>[const SizedBox(height: 8), note!],
        ];
        final bool manyRows =
            rowCount == null ||
            rowCount! * shortestCardHeight > constraints.maxHeight;
        if (cards && manyRows && constraints.maxHeight >= minCardListHeight) {
          return ClipRect(
            child: NestedScrollView(
              headerSliverBuilder: (BuildContext context, bool scrolled) =>
                  <Widget>[
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      sliver: SliverToBoxAdapter(child: filters),
                    ),
                  ],
              body: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: constraints.maxHeight,
                maxHeight: constraints.maxHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(child: table),
                      ...noteBelow,
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        final Widget content = Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              filters,
              const SizedBox(height: 12),
              if (compactHeight)
                SizedBox(height: 360, child: table)
              else if (cards)
                table
              else
                Expanded(child: table),
              ...noteBelow,
            ],
          ),
        );
        return compactHeight || cards
            ? SingleChildScrollView(child: content)
            : content;
      },
    );
  }
}

class _OrderStatusOverride {
  const _OrderStatusOverride({required this.status, required this.appliedAt});

  final String status;
  final DateTime appliedAt;
}

class _OrderFilterSnapshot {
  const _OrderFilterSnapshot({
    required this.searchText,
    required this.status,
    required this.salesman,
    required this.retailer,
    required this.dateRange,
  });

  final String searchText;
  final String status;
  final String salesman;
  final String retailer;
  final DateTimeRange? dateRange;
}

class OrderCardReference extends StatelessWidget {
  const OrderCardReference({
    super.key,
    required this.orderId,
    required this.repeated,
  });

  final String orderId;
  final Set<String> repeated;

  @override
  Widget build(BuildContext context) {
    final String reference = shortOrderReference(orderId);
    final bool showFullId = repeated.contains(reference);
    return TipText(
      showFullId ? orderId : reference,
      style: ScootType.bodyStrong,
    );
  }
}

class PossibleDuplicateChip extends StatelessWidget {
  const PossibleDuplicateChip({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 4),
      child: Tooltip(
        message:
            'Another order for this retailer has the same items '
            'within 30 minutes. Check that it is not sent twice. '
            'Both orders stay open.',
        child: _SmallChip(label: 'Possible duplicate'),
      ),
    );
  }
}

class _SmallChip extends StatelessWidget {
  const _SmallChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 2,
        softWrap: true,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
