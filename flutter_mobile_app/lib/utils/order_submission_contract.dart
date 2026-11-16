import 'dart:convert';

import 'quantity_unit.dart';

class CommercialOrderLine {
  const CommercialOrderLine({
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.unitPriceCents,
  });

  final String productId;
  final String productName;
  final int quantity;
  final int unitPriceCents;

  double get unitPrice => unitPriceCents / 100;
  int get lineTotalCents => quantity * unitPriceCents;
}

class OrderSubmissionContract {
  OrderSubmissionContract._();

  static const int schemaVersion = 1;
  static const int maxLineItems = 25;
  static const int maxShelfBatchesPerItem = 20;
  static const int maxUnitPriceCents = 999999999;
  static const double maxTotalPrice = 10000000;
  static final RegExp _productIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,200}$');
  static final RegExp _encodedNamePattern = RegExp(r'^[A-Za-z0-9_-]{1,800}$');

  static String? validateItems(List<Map<String, dynamic>> items) {
    if (items.isEmpty) {
      return 'Please keep at least one item before submitting.';
    }
    if (items.length > maxLineItems) {
      return 'An order can contain at most $maxLineItems products.';
    }

    var total = 0.0;
    for (final item in items) {
      final name = item['name'];
      final productName = item['productName'];
      final price = item['price'];
      final qty = item['qty'];
      final batches = item['shelfBatches'];
      final remarks = item['remarks'];
      if (name is! String ||
          name.trim().isEmpty ||
          name.length > 200 ||
          productName != name) {
        return 'Every order item needs a valid product name.';
      }
      final int? priceCents = _priceCents(price);
      if (priceCents == null) {
        return '$name has an invalid unit price. Check the product catalogue.';
      }
      final int maxQty = maxQtyFor(item);
      if (qty is! int || qty < 1 || qty > maxQty) {
        return '$name must be between 1 and '
            '${quantityLabel(maxQty, uomOf(item))}.';
      }
      if (item['productId'] is! String ||
          !_productIdPattern.hasMatch(item['productId'] as String) ||
          !_optionalBoundedText(item['barcode'], 100) ||
          !_requiredBoundedText(item['packingSize'], 100) ||
          !_requiredBoundedText(item['expiry'], 50) ||
          !_requiredBoundedText(item['department'], 100) ||
          item['departmentName'] != item['department'] ||
          remarks is! String ||
          remarks.length > 200) {
        return '$name contains invalid product details.';
      }
      if (batches is! List || batches.length > maxShelfBatchesPerItem) {
        return '$name has too many shelf batches.';
      }
      for (final batch in batches) {
        if (batch is! Map ||
            batch['qty'] is! int ||
            (batch['qty'] as int) < 1 ||
            batch['expiry'] is! String ||
            (batch['expiry'] as String).length > 50) {
          return '$name contains an invalid shelf batch.';
        }
      }
      total += priceCents / 100 * qty;
    }
    if (total <= 0 || total > maxTotalPrice) {
      return 'The order total is outside the allowed range.';
    }
    return null;
  }

  static List<String> commercialLines(List<Map<String, dynamic>> items) {
    final String? error = validateItems(items);
    if (error != null) throw FormatException(error);
    return items
        .map((Map<String, dynamic> item) {
          final String encodedName = base64Url
              .encode(utf8.encode(item['name'] as String))
              .replaceAll('=', '');
          if (!_encodedNamePattern.hasMatch(encodedName)) {
            throw const FormatException(
              'A product name is too long to submit.',
            );
          }
          return '${item['productId']}~$encodedName~${item['qty']}~${_priceCents(item['price'])}';
        })
        .toList(growable: false);
  }

  static List<CommercialOrderLine>? readCommercialLines(
    Map<String, dynamic> order,
  ) {
    if (order['commercialSchemaVersion'] != schemaVersion) return null;
    final Object? rawLines = order['commercialLines'];
    if (rawLines is! List ||
        rawLines.isEmpty ||
        rawLines.length > maxLineItems) {
      return null;
    }
    final List<CommercialOrderLine> result = <CommercialOrderLine>[];
    for (final Object? raw in rawLines) {
      if (raw is! String) return null;
      final List<String> parts = raw.split('~');
      if (parts.length != 4 ||
          !_productIdPattern.hasMatch(parts[0]) ||
          !_encodedNamePattern.hasMatch(parts[1])) {
        return null;
      }
      final int? quantity = int.tryParse(parts[2]);
      final int? unitPriceCents = int.tryParse(parts[3]);
      if (quantity == null ||
          quantity < 1 ||
          quantity > absoluteMaxQtyPerLine ||
          unitPriceCents == null ||
          unitPriceCents < 1 ||
          unitPriceCents > maxUnitPriceCents) {
        return null;
      }
      try {
        final String paddedName = parts[1].padRight(
          parts[1].length + (4 - parts[1].length % 4) % 4,
          '=',
        );
        final String name = utf8.decode(base64Url.decode(paddedName));
        if (name.trim().isEmpty || name.length > 200) return null;
        result.add(
          CommercialOrderLine(
            productId: parts[0],
            productName: name,
            quantity: quantity,
            unitPriceCents: unitPriceCents,
          ),
        );
      } on FormatException {
        return null;
      }
    }
    return result;
  }

  static int? _priceCents(Object? value) {
    if (value is! num || !value.isFinite || value <= 0) return null;
    final double scaled = value.toDouble() * 100;
    final int rounded = scaled.round();
    if ((scaled - rounded).abs() > 0.000001 ||
        rounded < 1 ||
        rounded > maxUnitPriceCents) {
      return null;
    }
    return rounded;
  }

  static bool _optionalBoundedText(Object? value, int maxLength) {
    return value == null || value is String && value.length <= maxLength;
  }

  static bool _requiredBoundedText(Object? value, int maxLength) {
    return value is String && value.length <= maxLength;
  }
}
