import 'order_data_utils.dart' show dataNumberOrNull;

const int defaultMaxQtyPerLine = 5;
const int absoluteMaxQtyPerLine = 999;

int maxQtyFor(Map<String, dynamic> data) {
  final double? raw = dataNumberOrNull(
    data['maxOrderQty'] ?? data['max_order_qty'],
  );
  if (raw == null || raw.isNaN || raw < 1 || raw != raw.roundToDouble()) {
    return defaultMaxQtyPerLine;
  }
  return raw > absoluteMaxQtyPerLine ? absoluteMaxQtyPerLine : raw.toInt();
}

String? uomOf(Map<String, dynamic> data) {
  for (final String key in const <String>['uom', 'uomLabel', 'unitOfMeasure']) {
    final Object? value = data[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

const Set<String> _boxUnits = <String>{
  '',
  'box',
  'boxes',
  'ctn',
  'carton',
  'cartons',
};

const Map<String, String> _plurals = <String, String>{
  'box': 'boxes',
  'set': 'sets',
  'pc': 'pcs',
  'piece': 'pieces',
  'carton': 'cartons',
  'pack': 'packs',
  'packet': 'packets',
  'bottle': 'bottles',
  'bag': 'bags',
  'can': 'cans',
  'tin': 'tins',
  'roll': 'rolls',
  'unit': 'units',
  'pair': 'pairs',
};

String quantityLabel(int qty, String? uom) {
  final String unit =
      (uom == null || _boxUnits.contains(uom.trim().toLowerCase()))
      ? 'box'
      : uom.trim();
  final String lower = unit.toLowerCase();
  if (qty == 1) {
    final String? singular = _plurals.entries
        .where((MapEntry<String, String> entry) => entry.value == lower)
        .map((MapEntry<String, String> entry) => entry.key)
        .firstOrNull;
    return '1 ${singular ?? unit}';
  }
  return '$qty ${_plurals[lower] ?? unit}';
}

String totalQuantityLabel(Iterable<(int, String?)> lines) {
  int total = 0;
  final Set<String> units = <String>{};
  for (final (int qty, String? uom) in lines) {
    total += qty;
    units.add(_singular(uom));
  }
  if (units.length == 1) return quantityLabel(total, units.single);
  return total == 1 ? '1 item' : '$total items';
}

String _singular(String? uom) {
  if (uom == null) return 'box';
  final String lower = uom.trim().toLowerCase();
  if (_boxUnits.contains(lower)) return 'box';
  for (final MapEntry<String, String> entry in _plurals.entries) {
    if (entry.value == lower) return entry.key;
  }
  return lower;
}
