import 'package:cloud_firestore/cloud_firestore.dart';

Map<String, Object> cataloguePriceFields(double value) => <String, Object>{
  'unitPrice': value,
  'price': value,
  'priceGuide': value,
};

const List<String> _priceReadKeys = <String>[
  'unitPrice',
  'price',
  'priceGuide',
  'sellingPrice',
  'selling_price',
  'unit_price',
];

double cataloguePriceOf(Map<String, dynamic> product) {
  for (final String key in _priceReadKeys) {
    final Object? raw = product[key];
    final num? parsed = raw is num
        ? raw
        : num.tryParse(
            '${raw ?? ''}'.replaceAll('RM', '').replaceAll(',', '').trim(),
          );
    if (parsed != null) return parsed.toDouble();
  }
  return 0;
}

bool priceChanged(num? before, num? after) {
  if (before == null && after == null) return false;
  if (before == null || after == null) return true;
  return (before * 100).round() != (after * 100).round();
}

Map<String, dynamic> priceStampFor({required bool changed}) => changed
    ? <String, dynamic>{'priceUpdatedAt': FieldValue.serverTimestamp()}
    : <String, dynamic>{};

bool retailerOverridePricesChanged(
  Object? existingOverrides,
  Map<String, num?> newPrices,
) {
  final Map<dynamic, dynamic> existing = existingOverrides is Map
      ? existingOverrides
      : const <dynamic, dynamic>{};
  for (final MapEntry<String, num?> entry in newPrices.entries) {
    final Object? override = existing[entry.key];
    final Object? old = override is Map ? override['unitPrice'] : null;
    if (priceChanged(old is num ? old : null, entry.value)) return true;
  }
  return false;
}
