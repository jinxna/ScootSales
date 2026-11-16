String barcodeKey(Object? raw) {
  final String key = _rawBarcodeKey(raw);
  if (!RegExp(r'^[0-9]+$').hasMatch(key)) return key;
  if (key.length == 8 && key.startsWith('0')) {
    final String expanded = _expandUpce(key);
    if (_hasValidCheckDigit(expanded)) return expanded.padLeft(14, '0');
  }
  if (const <int>{8, 12, 13, 14}.contains(key.length) &&
      _hasValidCheckDigit(key)) {
    return key.padLeft(14, '0');
  }
  return key;
}

String _rawBarcodeKey(Object? raw) => (raw?.toString() ?? '')
    .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
    .toLowerCase();

bool _hasValidCheckDigit(String digits) {
  int sum = 0;
  int weight = 1;
  for (int index = digits.length - 1; index >= 0; index--) {
    sum += (digits.codeUnitAt(index) - 48) * weight;
    weight = weight == 1 ? 3 : 1;
  }
  return sum % 10 == 0;
}

String _expandUpce(String digits) {
  final String payload = digits.substring(1, 7);
  final String last = payload[5];
  final String body;
  if (last == '0' || last == '1' || last == '2') {
    body = '${payload.substring(0, 2)}${last}0000${payload.substring(2, 5)}';
  } else if (last == '3') {
    body = '${payload.substring(0, 3)}00000${payload.substring(3, 5)}';
  } else if (last == '4') {
    body = '${payload.substring(0, 4)}00000${payload[4]}';
  } else {
    body = '${payload.substring(0, 5)}0000$last';
  }
  return '0$body${digits[7]}';
}

bool barcodesMatch(Object? stored, Object? scanned) {
  final String scannedKey = barcodeKey(scanned);
  return scannedKey.isNotEmpty && barcodeKey(stored) == scannedKey;
}

bool barcodeMatchesQuery(Object? stored, Object? query) {
  final String queryKey = _rawBarcodeKey(query);
  return queryKey.isNotEmpty &&
      (_rawBarcodeKey(stored).contains(queryKey) ||
          barcodesMatch(stored, query));
}
