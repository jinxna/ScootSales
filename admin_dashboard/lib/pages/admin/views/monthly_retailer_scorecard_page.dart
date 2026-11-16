import 'package:flutter/material.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/retailer_scorecard_repository.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/retailer_scorecard.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/horizontal_scroll_cue.dart';
import '../../../widgets/slow_loading.dart';

class MonthlyRetailerScorecardPage extends StatefulWidget {
  const MonthlyRetailerScorecardPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<MonthlyRetailerScorecardPage> createState() =>
      _MonthlyRetailerScorecardPageState();
}

class _MonthlyRetailerScorecardPageState
    extends State<MonthlyRetailerScorecardPage> {
  final RetailerScorecardRepository _repository = RetailerScorecardRepository();
  late Future<RetailerScorecardSource> _sourceFuture;
  late DateTime _month;
  String _retailerId = '';

  DateTime get _malaysiaNow =>
      DateTime.now().toUtc().add(const Duration(hours: 8));

  @override
  void initState() {
    super.initState();
    final DateTime now = _malaysiaNow;
    _month = DateTime.utc(now.year, now.month);
    _sourceFuture = _repository.load(widget.currentUser);
  }

  void _reload() => setState(() {
    _sourceFuture = _repository.load(widget.currentUser);
  });

  @override
  Widget build(BuildContext context) {
    if (!widget.currentUser.isAdmin) {
      return const Center(
        child: Text('This report is available to Admin users only.'),
      );
    }
    return FutureBuilder<RetailerScorecardSource>(
      future: _sourceFuture,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<RetailerScorecardSource> snapshot,
          ) {
            if (snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData) {
              return const SlowLoading();
            }
            if (snapshot.hasError) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.error_outline,
                        color: context.dso.dangerText,
                        size: 36,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'The requested-quantity report could not be read completely. No totals are shown.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        userFacingError(
                          snapshot.error!,
                          action: 'load the report',
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final RetailerScorecardSource? source = snapshot.data;
            if (source == null) return const SizedBox.shrink();
            final List<_RetailerOption> retailers = _retailers(source.orders);
            final List<String> unassignedOrderIds =
                unassignedRetailerScorecardOrderIds(source.orders);
            if (_retailerId.isEmpty && retailers.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _retailerId.isEmpty) {
                  setState(() => _retailerId = retailers.first.id);
                }
              });
            }
            final _RetailerOption? selected = _selectedRetailer(
              retailers,
              _retailerId,
            );
            final RetailerScorecardReport? report = selected == null
                ? null
                : buildRetailerScorecard(
                    orders: source.orders,
                    products: source.products,
                    retailerId: selected.id,
                    month: _month,
                  );
            return _content(retailers, selected, report, unassignedOrderIds);
          },
    );
  }

  Widget _content(
    List<_RetailerOption> retailers,
    _RetailerOption? selected,
    RetailerScorecardReport? report,
    List<String> unassignedOrderIds,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: context.dso.warningSoft,
            border: Border.all(
              color: context.dso.warning.withValues(alpha: 0.4),
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Provisional report · Calculated from current order records. These are requested quantities, not a frozen snapshot and not fulfilled sales. Canonical submitted quantities are boxes; legacy units come from their order lines or, when unavailable, current catalogue records. Week columns use a provisional four-week split (days 1–7, 8–14, 15–21, 22–last day) pending confirmation.',
              style: TextStyle(color: context.dso.warningText, fontSize: 12),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (unassignedOrderIds.isNotEmpty) ...<Widget>[
          _unassignedRetailersNotice(unassignedOrderIds),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _monthButton('Previous month', Icons.chevron_left, -1),
            Text(
              _monthLabel(_month),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            _monthButton(
              'Next month',
              Icons.chevron_right,
              1,
              enabled: _month.isBefore(
                DateTime.utc(_malaysiaNow.year, _malaysiaNow.month),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 320,
              child: DropdownButtonFormField<String>(
                initialValue: selected?.id,
                decoration: const InputDecoration(
                  labelText: 'Retailer',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: retailers
                    .map(
                      (_RetailerOption retailer) => DropdownMenuItem<String>(
                        value: retailer.id,
                        child: Text(
                          retailer.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (String? id) =>
                    setState(() => _retailerId = id ?? ''),
              ),
            ),
            IconButton(
              onPressed: _reload,
              tooltip: 'Reload current records',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (report == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No identifiable non-demo retailer orders are available to select.',
            ),
          )
        else ...<Widget>[
          _dataWarnings(report),
          const SizedBox(height: 12),
          if (report.lines.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  'No non-draft requested quantities were found for this retailer in this month.',
                ),
              ),
            )
          else ...<Widget>[
            Padding(
              padding: EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                'The weekly totals include every dated non-draft request for the month, regardless of its current status. Order IDs are traceable from each product row; status is shown below.\n\n'
                'Week columns are four numbered weeks. The approved requirement fixes four weeks (1–4) but does not specify their exact day boundaries, so this report shows them provisionally as days 1–7, 8–14, 15–21, and 22–last day, pending confirmation. Week 4 absorbs the remaining days and is longer in months with more than 28 days.',
                style: TextStyle(fontSize: 12, color: context.dso.body),
              ),
            ),
            _quantityTable(report),
          ],
          const SizedBox(height: 14),
          _orderDetails(report.orders),
        ],
      ],
    );
  }

  Widget _unassignedRetailersNotice(List<String> orderIds) => Card(
    color: context.dso.warningSoft,
    child: ExpansionTile(
      leading: Icon(
        Icons.warning_amber_rounded,
        color: context.dso.warningText,
      ),
      title: Text('${orderIds.length} order(s) have no retailer identity'),
      subtitle: const Text(
        'These non-draft records are excluded from retailer totals until their retailer can be identified.',
      ),
      children: orderIds
          .map((String id) => ListTile(dense: true, title: Text(id)))
          .toList(growable: false),
    ),
  );

  Widget _monthButton(
    String label,
    IconData icon,
    int delta, {
    bool enabled = true,
  }) => IconButton(
    tooltip: label,
    onPressed: enabled
        ? () => setState(
            () => _month = DateTime.utc(_month.year, _month.month + delta),
          )
        : null,
    icon: Icon(icon),
  );

  Widget _dataWarnings(RetailerScorecardReport report) {
    final List<String> warnings = <String>[
      if (report.missingDateCount > 0)
        '${report.missingDateCount} order(s) for this retailer have no parseable date and cannot be assigned to a month.',
      if (report.invalidQuantityCount > 0)
        '${report.invalidQuantityCount} line(s) had invalid quantities or malformed/missing item data and were omitted.',
      if (report.malformedCanonicalOrderCount > 0)
        '${report.malformedCanonicalOrderCount} malformed canonical order(s) were excluded in full.',
      if (report.excludedDemoProductLineCount > 0)
        '${report.excludedDemoProductLineCount} line(s) reference demo/seed products and were excluded.',
      if (report.unavailableUnitCount > 0)
        '${report.unavailableUnitCount} line(s) have no available unit. Those quantities are kept in separate unknown-unit rows.',
    ];
    if (warnings.isEmpty) return const SizedBox.shrink();
    return Card(
      color: context.dso.warningSoft,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: warnings
              .map(
                (String warning) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: context.dso.warningText,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          warning,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }

  static const double _quantityHeadingHeight = 64;
  static const double _quantityRowHeight = 88;

  Widget _quantityTable(RetailerScorecardReport report) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DataTable(
            headingRowHeight: _quantityHeadingHeight,
            dataRowMinHeight: _quantityRowHeight,
            dataRowMaxHeight: _quantityRowHeight,
            columns: const <DataColumn>[DataColumn(label: Text('Product'))],
            rows: report.lines
                .map(
                  (RetailerScorecardLine line) => DataRow(
                    cells: <DataCell>[
                      DataCell(
                        SizedBox(
                          width: 230,
                          child: Tooltip(
                            message:
                                'Contributing order IDs:\n${line.contributingOrderIds.join('\n')}',
                            child: Text(
                              '${line.productName}\n${line.productId.isEmpty ? 'Product ID unavailable' : line.productId} · ${line.unit.isEmpty ? 'Unit unavailable' : line.unit}\nOrders (${line.contributingOrderIds.length}): ${line.contributingOrderIds.take(3).join(', ')}${line.contributingOrderIds.length > 3 ? ', …' : ''}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
                .toList(growable: false),
          ),
          Expanded(
            child: HorizontalScrollCue(
              child: DataTable(
                headingRowHeight: _quantityHeadingHeight,
                dataRowMinHeight: _quantityRowHeight,
                dataRowMaxHeight: _quantityRowHeight,
                columns: <DataColumn>[
                  for (int i = 0; i < report.weeks.length; i++)
                    DataColumn(
                      label: Text(
                        'Week ${i + 1}\n${_range(report.weeks[i])}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const DataColumn(label: Text('Month total')),
                ],
                rows: report.lines
                    .map(
                      (RetailerScorecardLine line) => DataRow(
                        cells: <DataCell>[
                          for (final int quantity in line.weekQuantities)
                            DataCell(
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text('$quantity'),
                              ),
                            ),
                          DataCell(
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                '${line.total}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _orderDetails(List<RetailerScorecardOrder> orders) => Card(
    child: ExpansionTile(
      title: Text('Order records reviewed (${orders.length})'),
      subtitle: const Text(
        'Status is shown for each request. Orders without a parseable date cannot be assigned to a report month.',
      ),
      children: orders.isEmpty
          ? const <Widget>[
              ListTile(title: Text('No dated order records for this month.')),
            ]
          : orders
                .map(
                  (RetailerScorecardOrder order) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: Text(order.id),
                    subtitle: Text(
                      '${order.date == null ? 'Date unavailable' : _date(order.date!)} · ${order.lineCount} valid line(s)',
                    ),
                    trailing: _statusChip(order.status),
                  ),
                )
                .toList(growable: false),
    ),
  );

  Widget _statusChip(String status) {
    final String lower = status.toLowerCase();
    final bool alert =
        lower.startsWith('rejected') ||
        lower.startsWith('cancelled') ||
        lower.startsWith('canceled') ||
        lower.startsWith('unknown');
    return Chip(
      label: Text(status, style: const TextStyle(fontSize: 11)),
      backgroundColor: alert ? context.dso.dangerSoft : context.dso.infoSoft,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );
  }
}

List<_RetailerOption> _retailers(List<Map<String, dynamic>> orders) {
  final Map<String, _RetailerOption> options = <String, _RetailerOption>{};
  for (final Map<String, dynamic> order in orders) {
    if (isDemoRetailerScorecardOrder(order)) continue;
    final String status = orderStatus(order).trim().toLowerCase();
    if (status == 'draft') continue;
    final String id = dataText(
      pickFirst(order, const <String>[
        'retailerId',
        'retailer_id',
        'retailerCode',
        'retailer_code',
      ]),
    );
    if (id.isEmpty) continue;
    final String name = dataText(
      pickFirst(order, const <String>[
        'retailerName',
        'retailer_name',
        'outlet',
      ]),
      fallback: id,
    );
    options.putIfAbsent(id, () => _RetailerOption(id: id, name: name));
  }
  final List<_RetailerOption> result = options.values.toList(growable: false)
    ..sort(
      (_RetailerOption a, _RetailerOption b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  return result;
}

class _RetailerOption {
  const _RetailerOption({required this.id, required this.name});
  final String id;
  final String name;
}

_RetailerOption? _selectedRetailer(List<_RetailerOption> retailers, String id) {
  for (final _RetailerOption retailer in retailers) {
    if (retailer.id == id) return retailer;
  }
  return null;
}

String _monthLabel(DateTime month) =>
    '${_monthName(month.month)} ${month.year}';
String _monthName(int month) => const <String>[
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
][month - 1];

String _range(RetailerScorecardWeek week) =>
    '${_date(week.start)}–${_date(week.end)}';
String _date(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')} ${_monthName(date.month)}';
