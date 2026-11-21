import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../utils/money_format.dart';
import '../../../utils/order_data_utils.dart';

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

String purchaseOrderDate(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';

DateTime? purchaseOrderIssuedAt(Map<String, dynamic> po) {
  final Object? value = po['issuedAt'];
  return value is Timestamp ? value.toDate().toLocal() : null;
}

class PurchaseOrdersView extends StatefulWidget {
  const PurchaseOrdersView({
    super.key,
    required this.phase,
    required this.onRetry,
    required this.weekLabel,
    required this.canGoNext,
    required this.onPreviousWeek,
    required this.onNextWeek,
    required this.onThisWeek,
    required this.weekPos,
    required this.weekLegacy,
    required this.hasAnyActivity,
    required this.isAdmin,
    required this.issuing,
    required this.changing,
    required this.onIssue,
    required this.onChangeStatus,
    required this.loadOrderLines,
    this.salespersonNames = const <String, String>{},
    this.onJumpToLatest,
    this.onOpenOrders,
    this.pageSize = ScootPaging.pageSize,
  });

  final ScootLoadPhase phase;
  final VoidCallback onRetry;
  final String weekLabel;
  final bool canGoNext;
  final VoidCallback onPreviousWeek;
  final VoidCallback onNextWeek;
  final VoidCallback onThisWeek;
  final List<Map<String, dynamic>> weekPos;
  final List<Map<String, dynamic>> weekLegacy;
  final bool hasAnyActivity;
  final bool isAdmin;
  final Set<String> issuing;
  final Set<String> changing;
  final ValueChanged<String> onIssue;
  final void Function(Map<String, dynamic> po, String target) onChangeStatus;
  final Future<List<Map<String, dynamic>>> Function(String orderDocumentId)
  loadOrderLines;
  final Map<String, String> salespersonNames;
  final VoidCallback? onJumpToLatest;
  final VoidCallback? onOpenOrders;
  final int pageSize;

  @override
  State<PurchaseOrdersView> createState() => _PurchaseOrdersViewState();
}

class _PurchaseOrdersViewState extends State<PurchaseOrdersView> {
  final Set<String> _expanded = <String>{};
  final Map<String, Future<List<Map<String, dynamic>>>> _orderLines =
      <String, Future<List<Map<String, dynamic>>>>{};
  int _pagesLoaded = 1;

  @override
  void didUpdateWidget(PurchaseOrdersView old) {
    super.didUpdateWidget(old);
    if (old.weekLabel != widget.weekLabel) _pagesLoaded = 1;
  }

  String _salesperson(Map<String, dynamic> po) {
    final String byOrder =
        widget.salespersonNames[dataText(po['orderId'])] ?? '';
    if (byOrder.isNotEmpty) return byOrder;
    return dataText(
      po['salesmanName'],
      fallback: dataText(po['salesmanCode'], fallback: '-'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(ScootSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ScootPageHeader(
            title: 'Purchase Orders',
            fact: 'Issued when an order is approved. One week at a time.',
            actions: <Widget>[_weekSwitch(context)],
          ),
          if (!widget.isAdmin) ...<Widget>[
            const SizedBox(height: 12),
            ScootNotice.readOnly(
              message:
                  'View only. Admins mark purchase orders fulfilled or cancelled.',
            ),
          ],
          const SizedBox(height: ScootSpace.md),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _weekSwitch(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: 'Previous week',
              onPressed: widget.onPreviousWeek,
              icon: const Icon(ScootIcons.back),
            ),
            Flexible(
              child: Text(widget.weekLabel, style: ScootType.bodyStrong),
            ),
            IconButton(
              tooltip: 'Next week',
              onPressed: widget.canGoNext ? widget.onNextWeek : null,
              icon: const Icon(ScootIcons.chevronRight),
            ),
          ],
        ),
        OutlinedButton(
          onPressed: widget.onThisWeek,
          child: const Text('This week'),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, Widget child) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: child,
    );
  }

  Widget _body(BuildContext context) {
    switch (widget.phase) {
      case ScootLoadPhase.loading:
        return _card(
          context,
          SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(ScootSpace.lg),
            child: ScootLoadingState(
              onRetry: widget.onRetry,
              semanticLabel: 'Loading purchase orders',
              skeleton: Column(
                children: <Widget>[
                  for (int i = 0; i < 6; i++)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: ScootSkeleton(height: 40),
                    ),
                ],
              ),
            ),
          ),
        );
      case ScootLoadPhase.error:
        return _card(
          context,
          Center(
            child: ScootErrorState(
              title: 'Load failed',
              message:
                  'Purchase orders could not be loaded. Check your connection.',
              onRetry: widget.onRetry,
            ),
          ),
        );
      case ScootLoadPhase.ready:
        break;
    }
    final bool empty = widget.weekPos.isEmpty && widget.weekLegacy.isEmpty;
    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        if (widget.weekLegacy.isNotEmpty) ...<Widget>[
          _missingNotice(context),
          const SizedBox(height: 12),
        ],
        if (widget.weekPos.isNotEmpty) ...<Widget>[
          _stats(context),
          const SizedBox(height: 12),
        ],
        if (empty) _card(context, _emptyState()) else _table(context),
      ],
    );
  }

  Widget _emptyState() {
    return ScootEmptyState(
      title: 'No purchase orders in ${widget.weekLabel}.',
      message: widget.isAdmin
          ? 'Approve an order in All Orders and its purchase order appears here.'
          : 'A purchase order appears here when a supervisor or admin approves an order.',
      action: Wrap(
        spacing: 10,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: <Widget>[
          if (widget.onOpenOrders != null)
            OutlinedButton(
              onPressed: widget.onOpenOrders,
              child: Text(
                widget.isAdmin ? 'Open All Orders' : 'Open Branch Orders',
              ),
            ),
          if (widget.hasAnyActivity && widget.onJumpToLatest != null)
            FilledButton(
              onPressed: widget.onJumpToLatest,
              child: const Text('Go to latest week with orders'),
            ),
        ],
      ),
    );
  }

  Widget _missingNotice(BuildContext context) {
    final int count = widget.weekLegacy.length;
    final ScootToneColors t = ScootColors.of(context).warning;
    return Container(
      key: const ValueKey<String>('po-missing-notice'),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: t.noteBackground,
        border: Border.all(color: t.border),
        borderRadius: ScootRadius.noteAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(ScootIcons.warning, size: 18, color: t.noteText),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$count approved order${count == 1 ? ' has' : 's have'} no purchase order.',
                  style: ScootType.bodyStrong.copyWith(color: t.noteText),
                ),
              ),
            ],
          ),
          for (final Map<String, dynamic> order in widget.weekLegacy)
            _missingRow(order, t),
        ],
      ),
    );
  }

  Widget _missingRow(Map<String, dynamic> order, ScootToneColors t) {
    final String docId = dataText(order['docId']);
    final bool busy = widget.issuing.contains(docId);
    return Padding(
      padding: const EdgeInsets.only(left: 28, top: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ScootLongText(
              '${dataText(order['orderId'], fallback: docId)} · '
              '${dataText(order['retailerName'], fallback: '-')} · '
              '${formatRm(orderRevenue(order))}. It was approved before automatic issue.',
              style: ScootType.small.copyWith(color: t.noteText),
            ),
          ),
          if (widget.isAdmin)
            OutlinedButton(
              onPressed: busy ? null : () => widget.onIssue(docId),
              child: Text(busy ? 'Issuing' : 'Issue PO'),
            ),
        ],
      ),
    );
  }

  Widget _stats(BuildContext context) {
    int count(String status) => widget.weekPos
        .where(
          (Map<String, dynamic> po) =>
              dataText(po['status'], fallback: 'issued').toLowerCase() ==
              status,
        )
        .length;
    final double value = widget.weekPos.fold<double>(
      0,
      (double sum, Map<String, dynamic> po) =>
          sum + dataNumber(po['totalPrice']),
    );
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        _stat(context, 'Issued', '${count('issued')}'),
        _stat(context, 'Value', formatRm(value)),
        _stat(context, 'Fulfilled', '${count('fulfilled')}'),
        _stat(context, 'Cancelled', '${count('cancelled')}'),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: ScootType.small.copyWith(color: c.muted)),
          Text(
            value,
            style: ScootType.h2.copyWith(
              color: c.ink,
              fontFeatures: ScootType.tabular,
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(BuildContext context) {
    return _card(
      context,
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) =>
            _tableAt(context, box),
      ),
    );
  }

  Widget _tableAt(BuildContext context, BoxConstraints box) {
    final ScootColors c = ScootColors.of(context);
    final bool phone = box.maxWidth < _tableMinWidth;
    final Map<String, List<Map<String, dynamic>>> byRetailer =
        <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> po in widget.weekPos) {
      final String name = dataText(
        po['retailerName'],
        fallback: dataText(po['retailerId'], fallback: 'Unknown retailer'),
      );
      byRetailer.putIfAbsent(name, () => <Map<String, dynamic>>[]).add(po);
    }
    final List<String> retailers = byRetailer.keys.toList()..sort();
    final int limit = widget.pageSize * _pagesLoaded;
    int shown = 0;
    final List<Widget> rows = <Widget>[];
    for (final String retailer in retailers) {
      if (shown >= limit) break;
      final List<Map<String, dynamic>> pos = byRetailer[retailer]!;
      final double total = pos.fold<double>(
        0,
        (double sum, Map<String, dynamic> po) =>
            sum + dataNumber(po['totalPrice']),
      );
      rows.add(
        Container(
          color: c.tableHead,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: ScootLongText(
                  retailer,
                  maxLines: 1,
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
              ),
              Text(
                '${pos.length} PO · ${formatRm(total)}',
                style: ScootType.small.copyWith(color: c.muted),
              ),
            ],
          ),
        ),
      );
      for (final Map<String, dynamic> po in pos) {
        if (shown >= limit) break;
        shown++;
        rows.add(_poRow(context, po, phone));
      }
    }
    final bool more = shown < widget.weekPos.length;
    final Widget table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!phone) _headerRow(c),
        ...rows,
        Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.hair)),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '$shown of ${widget.weekPos.length} purchase orders · ${widget.pageSize} per page',
                  style: ScootType.small.copyWith(color: c.muted),
                ),
              ),
              if (more)
                OutlinedButton(
                  key: const ValueKey<String>('po-load-more'),
                  onPressed: () => setState(() => _pagesLoaded++),
                  child: Text('Load ${widget.pageSize} more'),
                ),
            ],
          ),
        ),
      ],
    );
    return table;
  }

  static const double _tableMinWidth = 980;

  static const List<int> _flex = <int>[28, 18, 18, 13, 12, 12, 36];

  static const List<String> _labels = <String>[
    'Purchase order',
    'Order',
    'Salesperson',
    'Issued',
    'Value',
    'Status',
    'Actions',
  ];

  Widget _headerRow(ScootColors c) {
    return Container(
      height: ScootSize.tableHeader,
      decoration: BoxDecoration(
        color: c.tableHead,
        border: Border(bottom: BorderSide(color: c.hair)),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < _labels.length; i++)
            Expanded(
              flex: _flex[i],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Align(
                  alignment: i == 4
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Text(
                    _labels[i],
                    style: ScootType.tableHead.copyWith(color: c.tableHeadText),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(int index, Widget child, {bool right = false}) => Expanded(
    flex: _flex[index],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: child,
      ),
    ),
  );

  Widget _phoneFields(
    ScootColors c,
    List<Widget> values,
    List<Widget> actions,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.hair)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < values.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 104,
                    child: Text(
                      _labels[i],
                      style: ScootType.tableHead.copyWith(
                        color: c.tableHeadText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: values[i],
                    ),
                  ),
                ],
              ),
            ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ),
        ],
      ),
    );
  }

  Widget _poRow(BuildContext context, Map<String, dynamic> po, bool phone) {
    final ScootColors c = ScootColors.of(context);
    final String docId = dataText(po['docId']);
    final String status = dataText(po['status'], fallback: 'issued');
    final bool open = _expanded.contains(docId);
    final bool busy = widget.changing.contains(docId);
    final DateTime? issuedAt = purchaseOrderIssuedAt(po);
    final String number = dataText(po['poNumber'], fallback: docId);
    final List<Widget> values = <Widget>[
      Row(
        children: <Widget>[
          Icon(
            open ? ScootIcons.expandLess : ScootIcons.expandMore,
            size: 18,
            color: c.muted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ScootLongText(
              number,
              maxLines: 1,
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
          ),
        ],
      ),
      ScootLongText(
        dataText(po['orderId']),
        maxLines: 1,
        style: ScootType.body.copyWith(color: c.text2),
      ),
      ScootLongText(
        _salesperson(po),
        maxLines: 1,
        style: ScootType.body.copyWith(color: c.ink),
      ),
      Text(
        issuedAt == null ? '-' : purchaseOrderDate(issuedAt),
        style: ScootType.body.copyWith(color: c.text2),
      ),
      Text(
        formatRm(dataNumber(po['totalPrice'])),
        style: ScootType.bodyStrong.copyWith(
          color: c.ink,
          fontFeatures: ScootType.tabular,
        ),
      ),
      _statusBadge(status),
    ];
    final List<Widget> actions = <Widget>[
      if (widget.isAdmin && status.toLowerCase() == 'issued') ...<Widget>[
        FilledButton(
          onPressed: busy ? null : () => widget.onChangeStatus(po, 'fulfilled'),
          child: const Text('Mark fulfilled'),
        ),
        IconButton(
          tooltip: 'Cancel PO',
          onPressed: busy ? null : () => widget.onChangeStatus(po, 'cancelled'),
          icon: const Icon(ScootIcons.close),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          expanded: open,
          label: 'Purchase order $number',
          child: InkWell(
            onTap: () => setState(() {
              if (!_expanded.add(docId)) _expanded.remove(docId);
            }),
            hoverColor: c.hair,
            child: phone
                ? _phoneFields(c, values, actions)
                : Container(
                    height: ScootSize.tableRow,
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.hair)),
                    ),
                    child: Row(
                      children: <Widget>[
                        for (int i = 0; i < values.length; i++)
                          _cell(i, values[i], right: i == 4),
                        _cell(
                          6,
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              for (
                                int i = 0;
                                i < actions.length;
                                i++
                              ) ...<Widget>[
                                if (i > 0) const SizedBox(width: 8),
                                actions[i],
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        if (open) _poLines(context, po, docId),
      ],
    );
  }

  Widget _poLines(BuildContext context, Map<String, dynamic> po, String docId) {
    final Object? stored = po['lines'];
    if (stored is List) {
      return _lines(context, <Map<String, dynamic>>[
        for (final Object? raw in stored)
          if (raw is Map) Map<String, dynamic>.from(raw),
      ]);
    }
    final Future<List<Map<String, dynamic>>> load = _orderLines.putIfAbsent(
      docId,
      () => widget.loadOrderLines(docId),
    );
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: load,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            if (snapshot.error is PurchaseOrderSourceGone) {
              return _linesGone(context);
            }
            if (snapshot.hasError) return _linesFailed(context, docId);
            if (!snapshot.hasData) return _linesLoading(context);
            return _lines(context, snapshot.data!);
          },
    );
  }

  Widget _linesBox(BuildContext context, Widget child) => Container(
    color: ScootColors.of(context).page,
    padding: const EdgeInsets.fromLTRB(46, 8, 14, 12),
    child: child,
  );

  Widget _linesLoading(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return _linesBox(
      context,
      Row(
        children: <Widget>[
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Loading the order lines.',
            style: ScootType.small.copyWith(color: c.muted),
          ),
        ],
      ),
    );
  }

  Widget _linesGone(BuildContext context) => _linesBox(
    context,
    Text(
      'The order was deleted, so its lines are not available.',
      style: ScootType.small.copyWith(color: ScootColors.of(context).muted),
    ),
  );

  Widget _linesFailed(BuildContext context, String docId) {
    final ScootColors c = ScootColors.of(context);
    return _linesBox(
      context,
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'The order lines could not be loaded.',
              style: ScootType.small.copyWith(color: c.ink),
            ),
          ),
          OutlinedButton(
            onPressed: () => setState(() {
              _orderLines.remove(docId);
            }),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _lines(BuildContext context, List<Map<String, dynamic>> lines) {
    final ScootColors c = ScootColors.of(context);
    return _linesBox(
      context,
      lines.isEmpty
          ? Text(
              'This purchase order has no line items.',
              style: ScootType.small.copyWith(color: c.muted),
            )
          : Column(
              children: <Widget>[
                for (final Map<String, dynamic> line in lines)
                  _lineRow(c, line),
              ],
            ),
    );
  }

  Widget _lineRow(ScootColors c, Map<String, dynamic> line) {
    final int qty = itemQuantity(line);
    final double price = dataNumber(
      pickFirst(line, const <String>['price', 'unitPrice', 'unit_price']),
    );
    final String name = dataText(
      pickFirst(line, const <String>['productName', 'name', 'itemName']),
      fallback: '-',
    );
    final String pack = dataText(line['packingSize']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ScootLongText(
              pack.isEmpty ? name : '$name ($pack)',
              maxLines: 1,
              style: ScootType.small.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$qty × ${formatRm(price)}',
            style: ScootType.small.copyWith(color: c.muted),
          ),
          SizedBox(
            width: 110,
            child: Text(
              formatRm(qty * price),
              textAlign: TextAlign.end,
              style: ScootType.smallStrong.copyWith(
                color: c.ink,
                fontFeatures: ScootType.tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String status) {
    switch (status.toLowerCase()) {
      case 'fulfilled':
        return const ScootBadge(
          label: 'Fulfilled',
          tone: ScootTone.success,
          icon: ScootIcons.check,
        );
      case 'cancelled':
        return const ScootBadge(
          label: 'Cancelled',
          tone: ScootTone.danger,
          icon: ScootIcons.close,
        );
      default:
        return const ScootBadge(
          label: 'Issued',
          tone: ScootTone.info,
          icon: ScootIcons.document,
        );
    }
  }
}
