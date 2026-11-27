import 'package:flutter/material.dart';

import 'quantity_unit.dart';

int _readInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

Map<String, dynamic> hydrateCartDraftItemForRuntime(
  Map<String, dynamic> data, {
  required String retailerId,
  required String retailerName,
  String? visitId,
}) {
  final rawBatches = data['shelfBatches'] as List<dynamic>? ?? const [];
  final shelfBatches = rawBatches.whereType<Map>().map((raw) {
    final batch = Map<String, dynamic>.from(raw);
    final qty = _readInt(batch['qty']);
    return <String, dynamic>{
      'qty': qty,
      'expiry': batch['expiry']?.toString() ?? '',
      'controller': TextEditingController(text: qty.toString()),
      'focusNode': FocusNode(),
    };
  }).toList();

  if (shelfBatches.isEmpty) {
    shelfBatches.add({
      'qty': 0,
      'expiry': '',
      'controller': TextEditingController(text: '0'),
      'focusNode': FocusNode(),
    });
  }

  final stock = _readInt(
    data['stock'],
    fallback: shelfBatches.fold<int>(
      0,
      (total, batch) => total + _readInt(batch['qty']),
    ),
  );

  return <String, dynamic>{
    'retailerName': data['retailerName']?.toString() ?? retailerName,
    'retailerId': data['retailerId']?.toString() ?? retailerId,
    'visitId': data['visitId']?.toString() ?? visitId,
    'productId': data['productId']?.toString() ?? '',
    'name': data['name']?.toString() ?? '',
    'packingSize': data['packingSize']?.toString() ?? '',
    'barcode': data['barcode']?.toString() ?? '',
    'price': (data['price'] as num?)?.toDouble() ?? 0.0,
    if (data['priceSource'] is String) 'priceSource': data['priceSource'],
    'department': data['department']?.toString() ?? 'Other',
    if (uomOf(data) != null) 'uom': uomOf(data),
    'maxOrderQty': maxQtyFor(data),
    'qty': _readInt(data['qty'], fallback: 1),
    'stock': stock,
    'expiry': data['expiry']?.toString() ?? '',
    'remarks': data['remarks']?.toString() ?? '',
    if (data['suggestedReorderQty'] is int)
      'suggestedReorderQty': data['suggestedReorderQty'],
    'shelfBatches': shelfBatches,
    'stockController': TextEditingController(text: stock.toString()),
  };
}
