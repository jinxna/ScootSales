import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scoot_design/scoot_design.dart';

import '../utils/order_pdf.dart';
import '../utils/order_reference.dart';
import '../utils/quantity_unit.dart';
import '../widgets/long_name_text.dart';
import '../widgets/phone_card.dart';
import 'order_history_screen.dart';
import 'overview_screen.dart' show AppBottomNav;

int _qtyOf(Map<String, dynamic> item) {
  final Object? qty = item['qty'] ?? item['orderQty'] ?? 0;
  return qty is int ? qty : int.tryParse('$qty') ?? 0;
}

double orderConfirmationTotal(List<Map<String, dynamic>> items) {
  double total = 0;
  for (final Map<String, dynamic> item in items) {
    final double? price = (item['price'] as num?)?.toDouble();
    if (price != null) total += price * _qtyOf(item);
  }
  return total;
}

class OrderConfirmationScreen extends StatelessWidget {
  final String orderId;
  final String salesmanId;
  final int totalProducts;
  final int totalBoxes;
  final DateTime submittedAt;
  final List<Map<String, dynamic>> cartItems;
  final String? salesmanName;
  final String? retailerName;
  final String? locationMode;
  final String? locationReason;
  final String? returnToVisitLabel;
  final VoidCallback? onReturnToVisit;

  const OrderConfirmationScreen({
    super.key,
    required this.orderId,
    required this.salesmanId,
    required this.totalProducts,
    required this.totalBoxes,
    required this.submittedAt,
    this.cartItems = const [],
    this.salesmanName,
    this.retailerName,
    this.locationMode,
    this.locationReason,
    required void Function() onGoBackHome,
    required void Function() onCreateNewOrder,
    required void Function() onGoToScheduler,
    this.returnToVisitLabel,
    this.onReturnToVisit,
  });

  String get _shop {
    final String named = (retailerName ?? '').trim();
    if (named.isNotEmpty) return named;
    if (cartItems.isEmpty) return '';
    return (cartItems.first['retailerName'] as String? ?? '').trim();
  }

  @override
  Widget build(BuildContext context) {
    final bool hasVisit = returnToVisitLabel != null;
    void openOrders() => Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const OrderHistoryScreen()),
    );
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: 'Order sent',
        actions: <Widget>[
          ScootPhoneAction(
            icon: ScootIcons.download,
            label: 'Export PDF',
            onPressed: () => OrderPdf.share(
              orderId: orderId,
              totalProducts: totalProducts,
              totalBoxes: totalBoxes,
              submittedAt: submittedAt,
              cartItems: cartItems,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(ScootSpace.phoneGutter),
        children: <Widget>[
          _Hero(
            total: orderConfirmationTotal(cartItems),
            shop: _shop,
            hasPrices: cartItems.any((item) => item['price'] is num),
          ),
          const SizedBox(height: 12),
          PhoneCard(
            child: Column(
              children: <Widget>[
                PhoneRow(
                  label: 'Reference',
                  valueWidget: _Reference(orderId: orderId),
                ),
                const PhoneDivider(),
                PhoneRow(
                  label: 'Items',
                  value:
                      '$totalProducts product${totalProducts == 1 ? '' : 's'}'
                      ' · ${_totalQuantity()}',
                ),
                const PhoneDivider(),
                PhoneRow(
                  label: 'Sent',
                  value: OrderPdf.formatDate(submittedAt),
                ),
                if (locationMode != null) ...<Widget>[
                  const PhoneDivider(),
                  PhoneRow(
                    label: 'Location',
                    value: switch (locationMode) {
                      'location_verified' => 'GPS verified at the shop',
                      'device_captured' => 'Location recorded',
                      _ =>
                        'No location. ${locationReason ?? 'Your manager sees it as not verified.'}',
                    },
                    tone:
                        locationMode == 'location_verified' ||
                            locationMode == 'device_captured'
                        ? null
                        : ScootTone.warning,
                  ),
                ],
              ],
            ),
          ),
          const PhoneSectionTitle('Products'),
          PhoneCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: cartItems.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'No products. This order is a special request only.',
                      style: ScootType.small.copyWith(
                        color: ScootColors.of(context).text2,
                      ),
                    ),
                  )
                : Column(children: _productRows(context)),
          ),
        ],
      ),
      primaryAction: ScootPrimaryActionBar(
        label: hasVisit ? returnToVisitLabel! : 'View orders',
        icon: hasVisit ? ScootIcons.route : ScootIcons.orders,
        onPressed: hasVisit
            ? () {
                Navigator.of(context).pop();
                onReturnToVisit?.call();
              }
            : openOrders,
        secondaryLabel: hasVisit ? 'View orders' : null,
        onSecondary: hasVisit ? openOrders : null,
      ),
      bottomNav: const AppBottomNav(currentIndex: 2),
    );
  }

  String _totalQuantity() => cartItems.isEmpty
      ? quantityLabel(totalBoxes, null)
      : totalQuantityLabel(
          cartItems.map((item) => (_qtyOf(item), uomOf(item))),
        );

  List<Widget> _productRows(BuildContext context) {
    final List<Map<String, dynamic>> lines = cartItems
        .where((item) => _qtyOf(item) > 0)
        .toList();
    final Map<String, List<Map<String, dynamic>>> grouped =
        <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> item in lines) {
      final String dept = (item['department'] as String?)?.trim() ?? '';
      grouped.putIfAbsent(dept.isEmpty ? 'Others' : dept, () => []).add(item);
    }
    final ScootColors c = ScootColors.of(context);
    final List<Widget> rows = <Widget>[];
    grouped.forEach((String dept, List<Map<String, dynamic>> items) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              dept.toUpperCase(),
              style: ScootType.caption.copyWith(
                color: c.muted,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ),
      );
      for (int i = 0; i < items.length; i++) {
        if (i > 0) rows.add(const PhoneDivider());
        rows.add(_ProductRow(item: items[i]));
      }
    });
    return rows;
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.total,
    required this.shop,
    required this.hasPrices,
  });

  final double total;
  final String shop;
  final bool hasPrices;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const ScootBadge.waiting(),
          const SizedBox(height: 12),
          if (hasPrices)
            Text(
              'RM ${total.toStringAsFixed(2)}',
              style: ScootType.kpi.copyWith(color: c.ink),
            ),
          if (shop.isNotEmpty)
            LongNameText(
              shop,
              style: ScootType.bodyStrong.copyWith(color: c.text2),
            ),
          const SizedBox(height: 4),
          Text(
            'Your manager will approve it next.',
            style: ScootType.small.copyWith(color: c.text2),
          ),
        ],
      ),
    );
  }
}

class _Reference extends StatelessWidget {
  const _Reference({required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        Flexible(
          child: Semantics(
            label: '$orderId has been submitted',
            excludeSemantics: true,
            child: Text(
              shortOrderReference(orderId),
              overflow: TextOverflow.ellipsis,
              style: ScootType.mono.copyWith(color: c.ink),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy reference',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.content_copy, size: 18, color: c.text2),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: orderId));
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Reference copied.')));
          },
        ),
      ],
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final String name = item['name'] as String? ?? '';
    final String packingSize = item['packingSize'] as String? ?? '';
    final String expiry = (item['expiry'] as String?)?.trim() ?? '';
    final String remarks = (item['remarks'] as String?)?.trim() ?? '';
    final double? price = (item['price'] as num?)?.toDouble();
    final int qty = _qtyOf(item);
    final List<String> details = <String>[
      if (packingSize.isNotEmpty) packingSize,
      if (expiry.isNotEmpty) 'Expiry $expiry',
      if (price != null) 'RM ${(price * qty).toStringAsFixed(2)}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LongNameText(
                  name,
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
                if (details.isNotEmpty)
                  Text(
                    details.join(' · '),
                    style: ScootType.small.copyWith(color: c.text2),
                  ),
                if (remarks.isNotEmpty)
                  Text(
                    remarks,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.small.copyWith(
                      color: c.muted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            quantityLabel(qty, uomOf(item)),
            style: ScootType.bodyStrong.copyWith(color: c.ink),
          ),
        ],
      ),
    );
  }
}
