bool isDemoRecord(
  Map<String, dynamic> record, {
  bool includeNameMarkers = true,
}) {
  if (_isTrue(record['isDemo']) ||
      _isTrue(record['is_demo']) ||
      _isTrue(record['demo'])) {
    return true;
  }

  for (final Object? raw in <Object?>[
    record['environment'],
    record['source'],
    record['dataSource'],
    record['data_source'],
  ]) {
    final String environment = _text(raw).toLowerCase();
    final Set<String> environmentTokens = environment
        .split(RegExp(r'[^a-z0-9]+'))
        .where((String token) => token.isNotEmpty)
        .toSet();
    if (environmentTokens.intersection(<String>{
          'demo',
          'seed',
          'test',
        }).isNotEmpty ||
        environment.contains('ai1_demo')) {
      return true;
    }
  }

  final Iterable<Object?> identityValues = <Object?>[
    record['docId'],
    record['retailerId'],
    record['productId'],
    record['itemCode'],
    record['planId'],
    record['id'],
    record['code'],
    record['retailerCode'],
    record['sku'],
    record['optimisationMethod'],
    if (includeNameMarkers)
      record['retailerName'] ??
          record['productName'] ??
          record['itemName'] ??
          record['name'],
  ];
  for (final Object? raw in identityValues) {
    if (_hasDemoIdentityMarker(raw)) return true;
  }
  return false;
}

bool _hasDemoIdentityMarker(Object? raw) {
  final String value = _text(raw).toLowerCase();
  if (value.isEmpty) return false;
  for (final String prefix in const <String>['ai-1', 'ai1', 'ai_1', 'demo']) {
    if (value == prefix) return true;
    if (value.startsWith(prefix) && value.length > prefix.length) {
      final String boundary = value[prefix.length];
      if (const <String>{
        '-',
        '_',
        ':',
        ' ',
        '\t',
        '\n',
        '\r',
      }.contains(boundary)) {
        return true;
      }
    }
  }
  return false;
}

bool isDemoRetailerRecord(Map<String, dynamic> retailer) =>
    isDemoRecord(retailer);

bool isOperationalRetailerRecord(Map<String, dynamic> retailer) {
  if (isDemoRetailerRecord(retailer)) return false;
  final String status = _text(
    retailer['status'] ?? retailer['retailerStatus'],
  ).toLowerCase();
  return status != 'retired' && retailer['retiredAt'] == null;
}

bool _isTrue(Object? value) =>
    value == true || _text(value).toLowerCase() == 'true';

String _text(Object? value) {
  final String text = '${value ?? ''}'.trim();
  return text.toLowerCase() == 'null' ? '' : text;
}
