import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../models/user_profile.dart';
import '../services/shop_panel_service.dart';
import '../utils/money_format.dart';
import '../utils/retailer_readiness.dart';
import 'weekly_bar_chart.dart';

Future<void> showShopPanel(
  BuildContext context, {
  required UserProfile currentUser,
  required String retailerId,
  required String retailerName,
  String? focusProductId,
  ShopPanelService? service,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close the shop panel',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder:
        (
          BuildContext dialogContext,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          final double width = MediaQuery.sizeOf(dialogContext).width;
          return Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: ScootColors.of(dialogContext).card,
              elevation: 8,
              child: SizedBox(
                width: width < 520 ? width : 480,
                height: double.infinity,
                child: SafeArea(
                  child: ShopPanel(
                    currentUser: currentUser,
                    retailerId: retailerId,
                    retailerName: retailerName,
                    focusProductId: focusProductId,
                    service: service,
                    onClose: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ),
            ),
          );
        },
  );
}

class ShopPanel extends StatefulWidget {
  const ShopPanel({
    super.key,
    required this.currentUser,
    required this.retailerId,
    required this.retailerName,
    required this.onClose,
    this.focusProductId,
    this.service,
  });

  final UserProfile currentUser;
  final String retailerId;
  final String retailerName;
  final String? focusProductId;
  final VoidCallback onClose;
  final ShopPanelService? service;

  @override
  State<ShopPanel> createState() => _ShopPanelState();
}

class _ShopPanelState extends State<ShopPanel> {
  late Future<ShopPanelData> _future = _load();
  String? _productId;

  Future<ShopPanelData> _load() => (widget.service ?? ShopPanelService()).load(
    widget.currentUser,
    widget.retailerId,
    widget.retailerName,
  );

  void _retry() => setState(() => _future = _load());

  ShopWeeklySeries? _selected(ShopPanelData data) {
    final String? wanted = _productId ?? widget.focusProductId;
    for (final ShopWeeklySeries series in data.series) {
      if (series.productId == wanted) return data.seriesToShow(series);
    }
    final ShopWeeklySeries? evidenceOnly = data.stoppedEvidence[wanted];
    if (evidenceOnly != null) return evidenceOnly;
    for (final ShopWeeklySeries series in data.series) {
      if (data.stoppedEvidence.containsKey(series.productId)) {
        return data.seriesToShow(series);
      }
    }
    return data.series.isEmpty ? null : data.series.first;
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return FutureBuilder<ShopPanelData>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<ShopPanelData> snapshot) {
        final ShopPanelData? data = snapshot.data;
        final String title = data?.retailerName ?? widget.retailerName;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: ScootType.h2.copyWith(color: c.ink),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close the shop panel',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.line),
            Expanded(
              child: snapshot.connectionState != ConnectionState.done
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: _PanelLoading(),
                    )
                  : snapshot.hasError || data == null
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: ScootErrorState(onRetry: _retry),
                    )
                  : _body(context, data),
            ),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, ShopPanelData data) {
    final ScootColors c = ScootColors.of(context);
    final ShopWeeklySeries? series = _selected(data);
    final bool alertsFailed = data.failed.contains('insights');
    final bool stopped =
        !alertsFailed &&
        series != null &&
        data.stoppedEvidence.containsKey(series.productId);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        if (alertsFailed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _errorLine('Could not read the alerts for this shop.'),
          ),
        if (stopped)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'No ${series.productName} ordered'
              '${stoppedWeeksPhrase(data.stoppedEvidence[series.productId])}',
              key: const ValueKey<String>('shop-panel-stopped'),
              style: ScootType.h2.copyWith(
                color: c.tone(ScootTone.danger).foreground,
              ),
            ),
          ),
        if (data.failed.contains('weekly orders'))
          _errorLine('The weekly orders could not be read.')
        else if (series == null)
          Text(
            'No weekly orders are stored for this shop yet.',
            style: ScootType.body.copyWith(color: c.muted),
          )
        else ...<Widget>[
          if (_choices(data, series).length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DropdownButton<String>(
                isExpanded: true,
                value: series.productId,
                items: <DropdownMenuItem<String>>[
                  for (final ShopWeeklySeries s in _choices(data, series))
                    DropdownMenuItem<String>(
                      value: s.productId,
                      child: Text(s.productName, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (String? value) =>
                    setState(() => _productId = value),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: WeeklyBarChart(
              key: ValueKey<String>('shop-chart-${series.productId}'),
              title:
                  '${series.productName}, cartons per week, ${data.retailerName}',
              weeks: series.weeks,
            ),
          ),
        ],
        const SizedBox(height: 16),
        _row(
          'Last visit',
          data.failed.contains('visits')
              ? null
              : data.lastVisit == null
              ? 'No visit recorded'
              : weeklyChartDayLabel(data.lastVisit!),
          failed: data.failed.contains('visits'),
        ),
        _row(
          'Last order',
          data.failed.contains('orders')
              ? null
              : data.tooManyOrders
              ? 'Not shown here: this shop has 500 or more orders. Only 500 are read.'
              : data.lastOrderAmount == null
              ? 'No order yet'
              : '${formatRm(data.lastOrderAmount!)}, '
                    '${shopPanelDateLabel(data.lastOrderAt!)}',
          failed: data.failed.contains('orders'),
        ),
        _row(
          'Open follow-up',
          data.failed.contains('follow-ups')
              ? null
              : data.followUp == null
              ? 'None'
              : '${data.followUp!.note.isEmpty ? data.followUp!.reasonLabel : data.followUp!.note}. Due ${shopPanelDateKeyLabel(data.followUp!.followUpDate)}',
          failed: data.failed.contains('follow-ups'),
        ),
        _row(
          'Salesperson',
          data.failed.contains('people') || data.failed.contains('shops')
              ? null
              : data.salesperson.isEmpty
              ? 'Not assigned'
              : data.salesperson,
          failed: data.failed.contains('people') || data.failed.contains('shops'),
        ),
        _row(
          'Pin',
          data.failed.contains('shops')
              ? null
              : data.pin == null
              ? 'Unknown'
              : data.pin == CoordinateStatus.verified
              ? 'Verified'
              : 'Not verified',
          failed: data.failed.contains('shops'),
        ),
      ],
    );
  }

  List<ShopWeeklySeries> _choices(
    ShopPanelData data,
    ShopWeeklySeries selected,
  ) => <ShopWeeklySeries>[
    if (!data.series.any(
      (ShopWeeklySeries s) => s.productId == selected.productId,
    ))
      selected,
    ...data.series,
  ];

  Widget _errorLine(String text) {
    final ScootColors c = ScootColors.of(context);
    return Row(
      children: <Widget>[
        Icon(Icons.error_outline, size: 16, color: c.tone(ScootTone.danger).foreground),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: ScootType.body.copyWith(
              color: c.tone(ScootTone.danger).foreground,
            ),
          ),
        ),
        TextButton(onPressed: _retry, child: const Text('Try again')),
      ],
    );
  }

  Widget _row(String label, String? value, {bool failed = false}) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(label, style: ScootType.body.copyWith(color: c.muted)),
          ),
          Expanded(
            child: Text(
              failed ? 'Not available right now' : (value ?? ''),
              style: ScootType.body.copyWith(color: failed ? c.muted : c.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelLoading extends StatelessWidget {
  const _PanelLoading();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      excludeSemantics: true,
      child: const Column(
        children: <Widget>[
          ScootSkeleton(width: double.infinity, height: 140, radius: 8),
          SizedBox(height: 12),
          ScootSkeletonLines(widthFactors: <double>[0.7, 0.5, 0.6]),
        ],
      ),
    );
  }
}
