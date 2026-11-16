library;

class ReplenishmentComparisonRow {
  const ReplenishmentComparisonRow({
    required this.productId,
    required this.suggestedQty,
    required this.confidence,
    required this.confidenceLabel,
    required this.rationale,
    this.lastOrderedQty,
  });

  final String productId;
  final int suggestedQty;
  final double confidence;
  final String confidenceLabel;
  final String rationale;

  final int? lastOrderedQty;

  int? get delta =>
      lastOrderedQty == null ? null : suggestedQty - lastOrderedQty!;
}

String _text(Object? value) => value == null ? '' : value.toString().trim();

double _number(Object? value) {
  if (value == null || value is bool) return 0.0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0.0;
}

String _firstText(Map<String, dynamic> row, List<String> fields) {
  for (final String field in fields) {
    final String value = _text(row[field]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

double _firstNumber(Map<String, dynamic> row, List<String> fields) {
  for (final String field in fields) {
    if (row.containsKey(field) && row[field] != null) {
      final double value = _number(row[field]);
      if (value != 0) return value;
    }
  }
  return 0.0;
}

DateTime? _asDate(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  try {
    final dynamic dynamicValue = value;
    return dynamicValue.toDate() as DateTime;
  } catch (_) {}
  return DateTime.tryParse(value.toString());
}

Map<String, int> _lastOrderedQtyByProduct(
  String retailerId,
  Iterable<Map<String, dynamic>> orders,
) {
  final Map<String, int> lastQty = <String, int>{};
  final Map<String, DateTime> lastDate = <String, DateTime>{};
  for (final Map<String, dynamic> order in orders) {
    final String orderRetailerId = _firstText(order, const <String>[
      'retailerId',
      'retailer_id',
      'retailerCode',
    ]);
    if (orderRetailerId != retailerId) continue;
    final String status = _text(order['status']).toLowerCase();
    if (const <String>{
      'cancelled',
      'canceled',
      'rejected',
      'draft',
      'deleted',
      'held_for_review',
    }.contains(status)) {
      continue;
    }
    final DateTime? orderDate = _asDate(
      order['submittedAt'] ?? order['orderDate'] ?? order['createdAt'],
    );
    if (orderDate == null) continue;
    final Object? items = order['items'];
    if (items is! List) continue;
    final Map<String, double> perProduct = <String, double>{};
    for (final Object? rawItem in items) {
      if (rawItem is! Map) continue;
      final Map<String, dynamic> item = rawItem.cast<String, dynamic>();
      final String productId = _firstText(item, const <String>[
        'productId',
        'itemId',
        'productCode',
        'sku',
      ]);
      if (productId.isEmpty) continue;
      final double qty = _firstNumber(item, const <String>[
        'qty',
        'quantity',
        'orderQty',
        'boxes',
      ]);
      if (qty <= 0) continue;
      perProduct[productId] = (perProduct[productId] ?? 0.0) + qty;
    }
    perProduct.forEach((String productId, double qty) {
      final DateTime? existing = lastDate[productId];
      if (existing == null || !orderDate.isBefore(existing)) {
        lastDate[productId] = orderDate;
        lastQty[productId] = qty.round();
      }
    });
  }
  return lastQty;
}

List<ReplenishmentComparisonRow> deriveReplenishmentComparison({
  required String retailerId,
  required Iterable<Map<String, dynamic>> suggestions,
  required Iterable<Map<String, dynamic>> orders,
}) {
  final String safeRetailerId = retailerId.trim();
  final Map<String, int> lastOrdered = _lastOrderedQtyByProduct(
    safeRetailerId,
    orders,
  );

  final List<ReplenishmentComparisonRow> rows = <ReplenishmentComparisonRow>[];
  for (final Map<String, dynamic> suggestion in suggestions) {
    final String suggestionRetailerId = _firstText(suggestion, const <String>[
      'retailerId',
      'retailer_id',
    ]);
    if (suggestionRetailerId != safeRetailerId) continue;
    final String productId = _firstText(suggestion, const <String>[
      'productId',
      'product_id',
    ]);
    if (productId.isEmpty) continue;
    final double confidence = _firstNumber(suggestion, const <String>[
      'confidence',
    ]);
    rows.add(
      ReplenishmentComparisonRow(
        productId: productId,
        suggestedQty: _firstNumber(suggestion, const <String>[
          'suggestedQty',
          'suggested_qty',
        ]).round(),
        confidence: confidence,
        confidenceLabel: _text(suggestion['confidenceLabel']).isEmpty
            ? 'low'
            : _text(suggestion['confidenceLabel']),
        rationale: _text(suggestion['rationale']),
        lastOrderedQty: lastOrdered[productId],
      ),
    );
  }
  rows.sort(
    (ReplenishmentComparisonRow a, ReplenishmentComparisonRow b) =>
        a.productId.compareTo(b.productId),
  );
  return rows;
}
