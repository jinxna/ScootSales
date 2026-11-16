import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'catalogue_product_availability.dart';
import 'quantity_unit.dart';

class CanonicalCommercialLine {
  const CanonicalCommercialLine({
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

final RegExp _canonicalProductId = RegExp(r'^[A-Za-z0-9_-]{1,200}$');
final RegExp _canonicalEncodedName = RegExp(r'^[A-Za-z0-9_-]{1,800}$');

List<CanonicalCommercialLine>? canonicalCommercialLines(
  Map<String, dynamic> order,
) {
  if (order['commercialSchemaVersion'] != 1) return null;
  final Object? rawLines = order['commercialLines'];
  if (rawLines is! List || rawLines.isEmpty || rawLines.length > 25) {
    return const <CanonicalCommercialLine>[];
  }
  final List<CanonicalCommercialLine> result = <CanonicalCommercialLine>[];
  for (final Object? raw in rawLines) {
    if (raw is! String) return const <CanonicalCommercialLine>[];
    final List<String> parts = raw.split('~');
    if (parts.length != 4 ||
        !_canonicalProductId.hasMatch(parts[0]) ||
        !_canonicalEncodedName.hasMatch(parts[1])) {
      return const <CanonicalCommercialLine>[];
    }
    final int? quantity = int.tryParse(parts[2]);
    final int? cents = int.tryParse(parts[3]);
    if (quantity == null ||
        quantity < 1 ||
        quantity > absoluteMaxQtyPerLine ||
        cents == null ||
        cents < 1 ||
        cents > 999999999) {
      return const <CanonicalCommercialLine>[];
    }
    try {
      final String padded = parts[1].padRight(
        parts[1].length + (4 - parts[1].length % 4) % 4,
        '=',
      );
      final String name = utf8.decode(base64Url.decode(padded));
      if (name.trim().isEmpty || name.length > 200) {
        return const <CanonicalCommercialLine>[];
      }
      result.add(
        CanonicalCommercialLine(
          productId: parts[0],
          productName: name,
          quantity: quantity,
          unitPriceCents: cents,
        ),
      );
    } on FormatException {
      return const <CanonicalCommercialLine>[];
    }
  }
  return result;
}

bool orderCommercialFactsAgree(Map<String, dynamic> order) {
  final List<CanonicalCommercialLine>? lines = canonicalCommercialLines(order);
  if (lines == null) return true;
  final Object? rawItems = order['items'];
  if (lines.isEmpty || rawItems is! List || rawItems.length != lines.length) {
    return false;
  }
  int totalCents = 0;
  for (int i = 0; i < lines.length; i++) {
    final Object? item = rawItems[i];
    if (item is! Map) return false;
    final Object? price = item['price'];
    final Object? qty = item['qty'];
    if (item['productId'] != lines[i].productId ||
        qty is! num ||
        qty.toInt() != lines[i].quantity ||
        price is! num ||
        (price * 100).round() != lines[i].unitPriceCents) {
      return false;
    }
    totalCents += lines[i].lineTotalCents;
  }
  final Object? total = order['totalPrice'];
  return total is num && ((total * 100).round() - totalCents).abs() <= 1;
}

List<Map<String, dynamic>> authoritativeOrderItems(Map<String, dynamic> order) {
  final List<CanonicalCommercialLine>? canonical = canonicalCommercialLines(
    order,
  );
  final Object? rawItems = pickFirst(order, const <String>[
    'items',
    'orderItems',
    'order_items',
    'cartItems',
  ]);
  final List<Map<String, dynamic>> legacy = rawItems is List
      ? rawItems
            .whereType<Map>()
            .map((Map<dynamic, dynamic> row) => Map<String, dynamic>.from(row))
            .toList(growable: false)
      : const <Map<String, dynamic>>[];
  if (canonical == null) return legacy;
  return List<Map<String, dynamic>>.generate(canonical.length, (int index) {
    final CanonicalCommercialLine line = canonical[index];
    return <String, dynamic>{
      if (index < legacy.length) ...legacy[index],
      'productId': line.productId,
      'name': line.productName,
      'productName': line.productName,
      'qty': line.quantity,
      'price': line.unitPrice,
    };
  }, growable: false);
}

bool itemHasPrice(Map<String, dynamic> item) =>
    dataNumberOrNull(item['price']) != null ||
    dataNumberOrNull(item['unitPrice']) != null;

bool orderLacksLinePrices(Map<String, dynamic> order) {
  final List<Map<String, dynamic>> items = authoritativeOrderItems(order);
  return items.isNotEmpty && !items.any(itemHasPrice);
}

Object? pickFirst(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    if (!row.containsKey(key)) continue;
    final Object? value = row[key];
    if (value == null) continue;
    if (value is num ||
        value is bool ||
        value is DateTime ||
        value is Timestamp) {
      return value;
    }
    final String text = value.toString().trim();
    if (text.isNotEmpty && text.toLowerCase() != 'null') return value;
  }
  return null;
}

String dataText(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

double dataNumber(Object? value) => dataNumberOrNull(value) ?? 0;

double? dataNumberOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(
    value.toString().replaceAll('RM', '').replaceAll(',', '').trim(),
  );
}

final RegExp _malaysianDatePattern = RegExp(
  r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})'
  r'(?:[ T]+(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?)?$',
);
final RegExp _numericEpochPattern = RegExp(r'^[+-]?\d{9,}(?:\.\d+)?$');
const int _millisecondsEpochThreshold = 10000000000;

DateTime? parseFlexibleDate(Object? value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  try {
    final dynamic timestampLike = value;
    final Object? date = timestampLike.toDate();
    if (date is DateTime) return date;
  } catch (_) {}
  if (value is num) {
    return _parseEpoch(value);
  }
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return null;

  final num? numericTimestamp = num.tryParse(text);
  if (numericTimestamp != null && _numericEpochPattern.hasMatch(text)) {
    return _parseEpoch(numericTimestamp);
  }

  final DateTime? isoDate = DateTime.tryParse(text);
  if (isoDate != null) return isoDate;

  final DateTime? malaysianDate = _parseMalaysianDate(text);
  if (malaysianDate != null) return malaysianDate;

  return null;
}

DateTime? _parseEpoch(num value) {
  final double raw = value.toDouble();
  if (!raw.isFinite) return null;

  try {
    final int whole = raw.toInt();
    final int milliseconds = whole.abs() >= _millisecondsEpochThreshold
        ? whole
        : whole * 1000;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  } on RangeError {
    return null;
  } on ArgumentError {
    return null;
  }
}

DateTime? _parseMalaysianDate(String text) {
  final Match? match = _malaysianDatePattern.firstMatch(text);
  if (match == null) return null;

  final int day = int.parse(match.group(1)!);
  final int month = int.parse(match.group(2)!);
  final int year = int.parse(match.group(3)!);
  final int hour = int.tryParse(match.group(4) ?? '0') ?? 0;
  final int minute = int.tryParse(match.group(5) ?? '0') ?? 0;
  final int second = int.tryParse(match.group(6) ?? '0') ?? 0;
  final String fraction = match.group(7) ?? '';
  final int microsecond = fraction.isEmpty
      ? 0
      : int.parse(fraction.padRight(6, '0'));

  if (hour > 23 || minute > 59 || second > 59) return null;

  final DateTime parsed = DateTime(
    year,
    month,
    day,
    hour,
    minute,
    second,
    microsecond ~/ 1000,
    microsecond % 1000,
  );
  if (parsed.year != year ||
      parsed.month != month ||
      parsed.day != day ||
      parsed.hour != hour ||
      parsed.minute != minute ||
      parsed.second != second ||
      parsed.millisecond * 1000 + parsed.microsecond != microsecond) {
    return null;
  }
  return parsed;
}

String serializeOrderExportDate(Object? value) {
  final DateTime? date = parseFlexibleDate(value);
  if (date == null) return '';
  final DateTime local = date.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

DateTime? orderDateFromRow(Map<String, dynamic> row) {
  return parseFlexibleDate(
    pickFirst(row, const <String>[
      'submittedAt',
      'submitted_at',
      'orderDate',
      'order_date',
      'createdAt',
      'created_at',
      'timestamp',
    ]),
  );
}

DateTime? visitDateFromRow(Map<String, dynamic> row) {
  return parseFlexibleDate(
    pickFirst(row, const <String>[
      'arrivalTime',
      'arrival_time',
      'visitDate',
      'visit_date',
      'departureTime',
      'departure_time',
      'createdAt',
      'created_at',
      'timestamp',
    ]),
  );
}

String orderStatus(Map<String, dynamic> row) {
  final Object? explicitRejected = pickFirst(row, const <String>[
    'isRejected',
    'rejected',
  ]);
  if (explicitRejected is bool && explicitRejected) return 'rejected';

  return dataText(
    pickFirst(row, const <String>[
      'status',
      'syncStatus',
      'submissionStatus',
      'approvalStatus',
      'state',
    ]),
  ).toLowerCase();
}

bool isRejectedOrder(Map<String, dynamic> row) {
  final String status = orderStatus(row);
  if (status.isEmpty) return false;
  return status == 'rejected' ||
      status == 'reject' ||
      status == 'cancelled' ||
      status == 'canceled' ||
      status == 'void';
}

bool orderCountsAsSale(Map<String, dynamic> row) {
  if (isRejectedOrder(row)) return false;
  final String status = orderStatus(row);
  return status != 'draft' && status != 'deleted';
}

bool orderCountsAsVisit(Map<String, dynamic> row) {
  return orderCountsAsSale(row) && orderStatus(row) != 'held_for_review';
}

List<Map<String, dynamic>> operationalReportOrders(
  Iterable<Map<String, dynamic>> rows,
) {
  return rows
      .where((Map<String, dynamic> row) => !isRejectedOrder(row))
      .toList(growable: false);
}

bool isSubmittedOrApprovedOrder(Map<String, dynamic> row) {
  if (isRejectedOrder(row)) return false;
  final String status = orderStatus(row);
  if (status.isEmpty) return true;
  return status == 'submitted' ||
      status == 'approved' ||
      status == 'synced' ||
      status == 'sync_success' ||
      status == 'completed' ||
      status == 'pending' ||
      status == 'pending_approval';
}

bool isPendingApprovalOrder(Map<String, dynamic> row) {
  if (isRejectedOrder(row)) return false;
  final String status = orderStatus(row);
  return status == 'submitted' ||
      status == 'held_for_review' ||
      status == 'pending' ||
      status == 'pending_approval';
}

double orderRevenue(Map<String, dynamic> row) {
  final List<CanonicalCommercialLine>? canonical = canonicalCommercialLines(
    row,
  );
  if (canonical != null) {
    return canonical.fold<int>(
          0,
          (int total, CanonicalCommercialLine line) =>
              total + line.lineTotalCents,
        ) /
        100;
  }
  return dataNumber(
    pickFirst(row, const <String>[
      'totalPrice',
      'total_price',
      'grandTotal',
      'grand_total',
      'totalAmount',
      'total_amount',
      'total',
      'amount',
      'orderTotal',
      'netTotal',
    ]),
  );
}

int orderQuantity(Map<String, dynamic> row) {
  final List<CanonicalCommercialLine>? canonical = canonicalCommercialLines(
    row,
  );
  if (canonical != null) {
    return canonical.fold<int>(
      0,
      (int total, CanonicalCommercialLine line) => total + line.quantity,
    );
  }
  final int direct = dataNumber(
    pickFirst(row, const <String>[
      'totalBoxes',
      'total_boxes',
      'totalQty',
      'total_qty',
      'totalQuantity',
      'total_quantity',
      'boxCount',
    ]),
  ).round();
  if (direct > 0) return direct;

  int total = 0;
  final Object? rawItems = pickFirst(row, const <String>[
    'items',
    'orderItems',
    'order_items',
  ]);
  if (rawItems is List) {
    for (final Object? raw in rawItems) {
      if (raw is Map) {
        total += itemQuantity(Map<String, dynamic>.from(raw));
      }
    }
  }
  return total;
}

int itemQuantity(Map<String, dynamic> item) {
  return dataNumber(
    pickFirst(item, const <String>[
      'qty',
      'quantity',
      'orderedQty',
      'ordered_qty',
      'boxes',
    ]),
  ).round();
}

String? orderCompletenessIssue(Map<String, dynamic> row) {
  final String retailerId = dataText(
    pickFirst(row, const <String>[
      'retailerId',
      'retailer_id',
      'retailerCode',
      'retailer_code',
      'storeId',
      'store_id',
    ]),
  );
  if (retailerId.isEmpty) {
    return 'The retailer is missing.';
  }

  final Object? rawItems = row['items'];
  if (rawItems is! List || rawItems.isEmpty) {
    return 'No order items were recorded.';
  }
  if (rawItems.length > 25) {
    return 'The order contains too many items.';
  }
  final List<CanonicalCommercialLine>? canonical = canonicalCommercialLines(
    row,
  );
  if (canonical != null && canonical.length != rawItems.length) {
    return 'The order line items are incomplete.';
  }
  if (canonical == null) {
    for (final Object? rawItem in rawItems) {
      if (rawItem is! Map) {
        return 'One or more order items are malformed.';
      }
      final Map<String, dynamic> item = Map<String, dynamic>.from(rawItem);
      final String product = dataText(
        pickFirst(item, const <String>[
          'productId',
          'productCode',
          'sku',
          'productName',
          'name',
          'itemName',
        ]),
      );
      if (product.isEmpty) {
        return 'One or more order items are missing a product.';
      }
      if (itemQuantity(item) < 1) {
        return 'One or more order items have no positive quantity.';
      }
    }
  }

  final double storedQuantity = dataNumber(row['totalBoxes']);
  if (!storedQuantity.isFinite || storedQuantity < 1) {
    return 'The stored order quantity is missing or zero.';
  }
  final double storedTotal = dataNumber(row['totalPrice']);
  if (!storedTotal.isFinite || storedTotal <= 0) {
    return 'The stored order total is missing or zero.';
  }

  final int quantity = orderQuantity(row);
  if (quantity < 1) {
    return 'The order has no positive item quantity.';
  }
  final double total = orderRevenue(row);
  if (!total.isFinite || total <= 0) {
    return 'The order total is missing or zero.';
  }

  return null;
}

bool isCompleteOrder(Map<String, dynamic> row) =>
    orderCompletenessIssue(row) == null;

int orderItemCount(Map<String, dynamic> row) {
  final List<CanonicalCommercialLine>? canonical = canonicalCommercialLines(
    row,
  );
  if (canonical != null) return canonical.length;
  final Object? rawItems = pickFirst(row, const <String>[
    'items',
    'orderItems',
    'order_items',
  ]);
  return rawItems is List ? rawItems.length : 0;
}

bool isDemoRow(Map<String, dynamic> row) {
  if (_hasDemoFlag(row)) return true;
  for (final String field in const <String>[
    'environment',
    'source',
    'dataSource',
    'data_source',
  ]) {
    if (_hasDemoContextMarker(row[field])) return true;
  }
  return false;
}

bool isDemoProductRecord(Map<String, dynamic> product) {
  if (isDemoRow(product)) return true;
  for (final Object? raw in <Object?>[
    product['docId'],
    product['productId'],
    product['itemCode'],
    product['productCode'],
    product['sku'],
  ]) {
    if (_hasDemoIdentityMarker(raw)) return true;
  }
  return false;
}

bool isDemoRetailerRecord(Map<String, dynamic> retailer) {
  if (_hasDemoFlag(retailer)) return true;
  for (final String field in const <String>[
    'environment',
    'source',
    'dataSource',
    'data_source',
  ]) {
    if (_hasDemoContextMarker(retailer[field])) return true;
  }
  for (final Object? raw in <Object?>[
    retailer['docId'] ?? retailer['retailerId'] ?? retailer['id'],
    retailer['code'] ?? retailer['retailerCode'],
  ]) {
    if (_hasDemoIdentityMarker(raw)) return true;
  }
  return false;
}

bool _hasDemoContextMarker(Object? raw) {
  final String context = dataText(raw).toLowerCase();
  if (context.isEmpty) return false;
  final List<String> tokens = context
      .split(RegExp(r'[^a-z0-9]+'))
      .where((String token) => token.isNotEmpty)
      .toList(growable: false);
  return tokens.any(
        (String token) => token == 'demo' || token == 'seed' || token == 'test',
      ) ||
      context.contains('ai1_demo');
}

bool _hasDemoIdentityMarker(Object? raw) {
  final String value = dataText(raw).toLowerCase().trim();
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

bool _hasDemoFlag(Map<String, dynamic> row) {
  return const <String>[
    'isDemo',
    'is_demo',
    'demo',
  ].any((String key) => dataText(row[key]).toLowerCase() == 'true');
}

bool isOperationalRetailerRecord(Map<String, dynamic> retailer) {
  if (isDemoRetailerRecord(retailer)) return false;
  final String status = dataText(
    retailer['status'] ?? retailer['retailerStatus'],
  ).toLowerCase();
  return status != 'retired' && retailer['retiredAt'] == null;
}

List<Map<String, dynamic>> operationalRetailerRows(
  Iterable<Map<String, dynamic>> rows,
) => rows.where(isOperationalRetailerRecord).toList(growable: false);

Stream<List<Map<String, dynamic>>> operationalRetailerStream(
  Stream<List<Map<String, dynamic>>> rows,
) => rows.map(operationalRetailerRows);

List<Map<String, dynamic>> scoreSheetEligibleProducts(
  Iterable<Map<String, dynamic>> products,
) => products
    .where(
      (Map<String, dynamic> p) =>
          !isDemoProductRecord(p) && isCatalogueProductVisible(p),
    )
    .toList(growable: false);

Map<String, Map<String, dynamic>> buildUserIndex(
  List<Map<String, dynamic>> users,
) {
  final Map<String, Map<String, dynamic>> index =
      <String, Map<String, dynamic>>{};
  final Set<String> ambiguous = <String>{};
  for (final Map<String, dynamic> user in users) {
    for (final Object? alias in <Object?>[
      user['docId'],
      user['uid'],
      user['id'],
      user['employeeCode'],
      user['employee_code'],
      user['staffId'],
      user['staff_id'],
      user['salesmanCode'],
      user['salesman_code'],
    ]) {
      final String key = dataText(alias).trim().toLowerCase();
      if (key.isEmpty || ambiguous.contains(key)) continue;
      final Map<String, dynamic>? existing = index[key];
      if (existing == null) {
        index[key] = user;
      } else if (!identical(existing, user)) {
        index.remove(key);
        ambiguous.add(key);
      }
    }
  }
  return index;
}

String resolveSalesmanName(
  Map<String, dynamic> order, {
  Map<String, Map<String, dynamic>>? usersByKey,
  String fallback = 'Unknown',
}) {
  final String direct = dataText(
    pickFirst(order, const <String>[
      'salesmanName',
      'salesman_name',
      'createdByName',
      'created_by_name',
    ]),
  );
  if (direct.isNotEmpty) return direct;

  final List<String> refs = <String>[
    dataText(order['salesmanUid']),
    dataText(order['salesman_uid']),
    dataText(order['salesmanId']),
    dataText(order['salesman_id']),
    dataText(order['salesmanCode']),
    dataText(order['salesman_code']),
    dataText(order['staffId']),
    dataText(order['staff_id']),
    dataText(order['createdByUid']),
    dataText(order['createdBy']),
  ].where((String s) => s.isNotEmpty).toList(growable: false);

  if (usersByKey != null) {
    for (final String ref in refs) {
      final Map<String, dynamic>? user = usersByKey[ref.trim().toLowerCase()];
      if (user == null) continue;
      final String name = dataText(
        pickFirst(user, const <String>[
          'name',
          'displayName',
          'fullName',
          'full_name',
        ]),
      );
      if (name.isNotEmpty) return name;
      final String email = dataText(user['email']);
      if (email.isNotEmpty) return email;
    }
  }

  if (refs.isNotEmpty) return refs.first;
  return fallback;
}

bool trackingFixBelongsToOrder(
  Map<String, dynamic> order,
  Map<String, dynamic> tracking,
) {
  final String orderOwner = dataText(
    order['salesmanUid'] ?? order['salesman_uid'],
  );
  if (orderOwner.isEmpty) return true;
  return dataText(tracking['salesmanUid']) == orderOwner;
}

String reportSalesmanKey(Map<String, dynamic> row) => dataText(
  row['salesmanName'] ??
      row['salesman_name'] ??
      row['salesmanId'] ??
      row['salesman_id'],
);

DateTime? _signedAtUtc(Object? text) {
  final Match? match = RegExp(
    r'^(\d{2})/(\d{2})/(\d{4})\s+(\d{2}):(\d{2}):(\d{2})$',
  ).firstMatch('${text ?? ''}'.trim());
  if (match == null) return null;
  int part(int index) => int.parse(match.group(index)!);
  return DateTime.utc(
    part(3),
    part(2),
    part(1),
    part(4),
    part(5),
    part(6),
  ).subtract(const Duration(hours: 8));
}

String? lateArrivalNotice(
  Map<String, dynamic> order, {
  Duration threshold = const Duration(minutes: 30),
}) {
  final Object? raw = order['signatureTimestamps'];
  final DateTime? submitted = parseFlexibleDate(order['submittedAt']);
  if (raw is! Map || submitted == null) return null;
  DateTime? latestSigned;
  for (final Object? value in raw.values) {
    final DateTime? signed = _signedAtUtc(value);
    if (signed != null &&
        (latestSigned == null || signed.isAfter(latestSigned))) {
      latestSigned = signed;
    }
  }
  if (latestSigned == null) return null;
  final Duration gap = submitted.toUtc().difference(latestSigned);
  if (gap < threshold) return null;
  final String span = gap.inHours >= 48
      ? '${gap.inDays} days'
      : gap.inHours >= 1
      ? '${gap.inHours} ${gap.inHours == 1 ? 'hour' : 'hours'}'
      : '${gap.inMinutes} minutes';
  return 'Sent $span after signing. The order was signed on the phone and '
      'reached the server later, so it is not a new order.';
}

const Duration possibleDuplicateWindow = Duration(minutes: 30);

String? _duplicateKey(Map<String, dynamic> order) {
  String retailer = dataText(
    pickFirst(order, const <String>['retailerId', 'retailer_id']),
  );
  if (retailer.isEmpty) {
    retailer = dataText(
      order['retailerName'] ?? order['retailer_name'],
    ).trim().toLowerCase();
  }
  if (retailer.isEmpty) return null;
  final List<String> items = <String>[
    for (final Map<String, dynamic> item in authoritativeOrderItems(order))
      '${dataText(pickFirst(item, const <String>['productId', 'productCode', 'sku', 'productName', 'name'])).trim().toLowerCase()}'
          ':${itemQuantity(item)}',
  ]..sort();
  if (items.isEmpty) return null;
  return '$retailer|${items.join(',')}';
}

Set<String> possibleDuplicateOrders(Iterable<Map<String, dynamic>> orders) {
  final Map<String, List<(DateTime, String)>> byKey =
      <String, List<(DateTime, String)>>{};
  for (final Map<String, dynamic> order in orders) {
    if (isRejectedOrder(order)) continue;
    final String id = dataText(order['docId'] ?? order['orderId']);
    final DateTime? at = orderDateFromRow(order);
    final String? key = _duplicateKey(order);
    if (id.isEmpty || at == null || key == null) continue;
    byKey.putIfAbsent(key, () => <(DateTime, String)>[]).add((at.toUtc(), id));
  }
  final Set<String> flagged = <String>{};
  for (final List<(DateTime, String)> group in byKey.values) {
    group.sort(
      ((DateTime, String) a, (DateTime, String) b) => a.$1.compareTo(b.$1),
    );
    for (int i = 1; i < group.length; i++) {
      if (group[i].$1.difference(group[i - 1].$1) <= possibleDuplicateWindow) {
        flagged
          ..add(group[i - 1].$2)
          ..add(group[i].$2);
      }
    }
  }
  return flagged;
}

String orderStatusLabel(String status) {
  final String text = status.trim().replaceAll('_', ' ');
  if (text.isEmpty) return text;
  return '${text[0].toUpperCase()}${text.substring(1)}';
}

String shortOrderReference(String orderId) {
  final String id = orderId.trim();
  if (id.length <= 14) return id;
  return 'ORD-${id.substring(id.length - 8).toUpperCase()}';
}

Set<String> repeatedShortOrderReferences(Iterable<String> orderIds) {
  final Set<String> seen = <String>{};
  final Set<String> repeated = <String>{};
  for (final String orderId in orderIds) {
    final String reference = shortOrderReference(orderId);
    if (!seen.add(reference)) repeated.add(reference);
  }
  return repeated;
}
