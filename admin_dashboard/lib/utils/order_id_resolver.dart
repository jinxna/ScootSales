class OrderIdResolver {
  const OrderIdResolver._();

  static const List<String> _bridgePrefixes = <String>[
    'order_notification_',
    'notification_logs_',
    'notifications_',
    'order_',
  ];

  static String resolve(Map<String, dynamic> row) {
    final String explicit = _firstText(<Object?>[
      row['orderDocId'],
      row['orderDocumentId'],
      row['firestoreOrderDocId'],
    ]);
    if (explicit.isNotEmpty) return _strip(explicit);

    final String bridgeKey = _readText(row['bridgeKey']);
    if (bridgeKey.isNotEmpty) {
      final int separator = bridgeKey.indexOf(':');
      if (separator > 0 && separator < bridgeKey.length - 1) {
        final String source = bridgeKey.substring(0, separator).toLowerCase();
        if (source == 'orders' || source == 'order_notification') {
          final String tail = bridgeKey.substring(separator + 1).trim();
          if (tail.isNotEmpty) return _strip(tail);
        }
      }
    }

    final String source = _readText(row['sourceCollection']).toLowerCase();
    if (source == 'orders') {
      final String docId = _readText(row['docId']);
      if (docId.isNotEmpty) return _strip(docId);
    }

    final String ref = _firstText(<Object?>[
      row['orderId'],
      row['order_id'],
      row['reference_id'],
      row['referenceId'],
      row['lastOrderId'],
      row['visitId'],
    ]);
    return ref.isEmpty ? '' : _strip(ref);
  }

  static String completionKey(Map<String, dynamic> row) {
    final String resolved = resolve(row);
    if (resolved.isNotEmpty) return resolved;
    final String docId = _readText(row['docId']);
    if (docId.isEmpty) return '';
    return '${_readText(row['sourceCollection']).toLowerCase()}:$docId';
  }

  static String _strip(String value) {
    String result = value.trim();
    for (final String prefix in _bridgePrefixes) {
      if (result.startsWith(prefix)) {
        result = result.substring(prefix.length);
        break;
      }
    }
    return result;
  }

  static String _firstText(Iterable<Object?> values) {
    for (final Object? value in values) {
      final String text = _readText(value);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static String _readText(Object? value) {
    if (value == null) return '';
    final String text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return '';
    return text;
  }
}
