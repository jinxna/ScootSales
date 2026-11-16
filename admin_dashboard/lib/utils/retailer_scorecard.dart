import 'package:cloud_firestore/cloud_firestore.dart';

import 'order_data_utils.dart';
import 'quantity_unit.dart';

class RetailerScorecardWeek {
  const RetailerScorecardWeek({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

class RetailerScorecardLine {
  RetailerScorecardLine({
    required this.productKey,
    required this.productId,
    required this.productName,
    required this.unit,
    required this.weekQuantities,
    required this.contributingOrderIds,
  });

  final String productKey;
  final String productId;
  final String productName;
  final String unit;
  final List<int> weekQuantities;
  final List<String> contributingOrderIds;
  int get total => weekQuantities.fold<int>(0, (int a, int b) => a + b);
}

class RetailerScorecardOrder {
  const RetailerScorecardOrder({
    required this.id,
    required this.date,
    required this.status,
    required this.lineCount,
  });

  final String id;
  final DateTime? date;
  final String status;
  final int lineCount;
}

class RetailerScorecardReport {
  const RetailerScorecardReport({
    required this.weeks,
    required this.lines,
    required this.orders,
    required this.missingDateCount,
    required this.invalidQuantityCount,
    required this.malformedCanonicalOrderCount,
    required this.excludedDemoProductLineCount,
    required this.unavailableUnitCount,
  });

  final List<RetailerScorecardWeek> weeks;
  final List<RetailerScorecardLine> lines;
  final List<RetailerScorecardOrder> orders;
  final int missingDateCount;
  final int invalidQuantityCount;
  final int malformedCanonicalOrderCount;
  final int excludedDemoProductLineCount;
  final int unavailableUnitCount;
}

bool isDemoRetailerScorecardOrder(Map<String, dynamic> order) {
  if (isDemoRow(order)) return true;
  return isDemoRetailerRecord(<String, dynamic>{
    'isDemo': order['isDemo'],
    'is_demo': order['is_demo'],
    'demo': order['demo'],
    'environment': order['environment'],
    'source': order['source'],
    'dataSource': order['dataSource'],
    'data_source': order['data_source'],
    'retailerName': pickFirst(order, const <String>[
      'retailerName',
      'retailer_name',
      'outlet',
    ]),
    'retailerId': pickFirst(order, const <String>['retailerId', 'retailer_id']),
    'code': pickFirst(order, const <String>['retailerCode', 'retailer_code']),
  });
}

bool isExcludedRetailerScorecardOrder(Map<String, dynamic> order) {
  if (isRejectedOrder(order)) return true;
  final String status = orderStatus(order).trim().toLowerCase();
  if (status == 'draft' || status == 'deleted') return true;
  for (final String key in const <String>['isDeleted', 'deleted']) {
    if (dataText(order[key]).toLowerCase() == 'true') return true;
  }
  return order['deletedAt'] != null;
}

String _canonicalUnit(String unit) {
  final String key = unit.trim().toLowerCase();
  const Set<String> boxes = <String>{
    'ctn',
    'ctns',
    'carton',
    'cartons',
    'box',
    'boxes',
    'bx',
  };
  if (boxes.contains(key)) return 'boxes';
  return key;
}

List<String> unassignedRetailerScorecardOrderIds(
  Iterable<Map<String, dynamic>> orders,
) {
  final List<String> result = <String>[];
  for (final Map<String, dynamic> order in orders) {
    if (isDemoRetailerScorecardOrder(order) ||
        isExcludedRetailerScorecardOrder(order)) {
      continue;
    }
    final String retailerId = dataText(
      pickFirst(order, const <String>[
        'retailerId',
        'retailer_id',
        'retailerCode',
        'retailer_code',
      ]),
    );
    if (retailerId.isEmpty) result.add(_orderId(order));
  }
  result.sort();
  return List<String>.unmodifiable(result);
}

List<RetailerScorecardWeek> retailerScorecardWeeks(DateTime month) {
  final DateTime first = DateTime.utc(month.year, month.month, 1);
  final DateTime last = DateTime.utc(month.year, month.month + 1, 0);
  const int provisionalDaysPerWeek = 7;
  return <RetailerScorecardWeek>[
    for (int week = 0; week < 3; week++)
      RetailerScorecardWeek(
        start: DateTime.utc(
          first.year,
          first.month,
          first.day + week * provisionalDaysPerWeek,
        ),
        end: DateTime.utc(
          first.year,
          first.month,
          first.day + (week + 1) * provisionalDaysPerWeek - 1,
        ),
      ),
    RetailerScorecardWeek(
      start: DateTime.utc(first.year, first.month, 22),
      end: last,
    ),
  ];
}

RetailerScorecardReport buildRetailerScorecard({
  required List<Map<String, dynamic>> orders,
  required List<Map<String, dynamic>> products,
  required String retailerId,
  required DateTime month,
}) {
  final List<RetailerScorecardWeek> weeks = retailerScorecardWeeks(month);
  final Map<String, Map<String, dynamic>> productById =
      <String, Map<String, dynamic>>{};
  final Set<String> ambiguousProductIds = <String>{};
  final Set<String> demoProductIds = <String>{};
  final Set<String> demoProductNames = <String>{};
  for (final Map<String, dynamic> product in products) {
    final List<String> productIds = <String>{
      dataText(product['docId']),
      dataText(
        pickFirst(product, const <String>[
          'productId',
          'product_id',
          'itemCode',
          'productCode',
          'sku',
        ]),
      ),
    }.where((String id) => id.isNotEmpty).toList(growable: false);
    if (isDemoRow(product)) {
      demoProductIds.addAll(productIds);
      final String name = dataText(
        pickFirst(product, const <String>[
          'itemName',
          'productName',
          'product_name',
          'displayName',
          'name',
        ]),
      ).toLowerCase();
      if (name.isNotEmpty) demoProductNames.add(name);
      continue;
    }
    for (final String key in productIds) {
      if (ambiguousProductIds.contains(key)) continue;
      final Map<String, dynamic>? existing = productById[key];
      if (existing == null) {
        productById[key] = product;
      } else if (dataText(existing['docId']) != dataText(product['docId'])) {
        productById.remove(key);
        ambiguousProductIds.add(key);
      }
    }
  }

  final Map<String, _LineBuilder> lines = <String, _LineBuilder>{};
  final List<RetailerScorecardOrder> selectedOrders =
      <RetailerScorecardOrder>[];
  int missingDates = 0;
  int invalidQuantities = 0;
  int malformedCanonicalOrders = 0;
  int excludedDemoProductLines = 0;
  int unavailableUnits = 0;
  final int monthStart = DateTime.utc(
    month.year,
    month.month,
  ).millisecondsSinceEpoch;
  final int nextMonthStart = DateTime.utc(
    month.year,
    month.month + 1,
  ).millisecondsSinceEpoch;

  for (final Map<String, dynamic> order in orders) {
    if (isDemoRetailerScorecardOrder(order)) continue;
    final String orderRetailerId = dataText(
      pickFirst(order, const <String>[
        'retailerId',
        'retailer_id',
        'retailerCode',
        'retailer_code',
      ]),
    );
    if (orderRetailerId != retailerId) continue;

    if (isExcludedRetailerScorecardOrder(order)) continue;

    final DateTime? date = _malaysiaOrderDate(order);
    if (date == null) {
      missingDates++;
      selectedOrders.add(
        RetailerScorecardOrder(
          id: _orderId(order),
          date: null,
          status: _displayStatus(order),
          lineCount: 0,
        ),
      );
      continue;
    }
    final DateTime monthDate = DateTime.utc(date.year, date.month, date.day);
    final int dateMillis = monthDate.millisecondsSinceEpoch;
    if (dateMillis < monthStart || dateMillis >= nextMonthStart) continue;

    final int weekIndex = weeks.indexWhere(
      (RetailerScorecardWeek week) =>
          !monthDate.isBefore(week.start) && !monthDate.isAfter(week.end),
    );
    if (weekIndex < 0) continue;

    final List<CanonicalCommercialLine>? canonical = canonicalCommercialLines(
      order,
    );
    final List<Map<String, dynamic>> rawItems;
    if (canonical != null) {
      if (canonical.isEmpty) {
        malformedCanonicalOrders++;
        selectedOrders.add(
          RetailerScorecardOrder(
            id: _orderId(order),
            date: date,
            status: _displayStatus(order),
            lineCount: 0,
          ),
        );
        continue;
      }
      rawItems = canonical
          .map(
            (CanonicalCommercialLine line) => <String, dynamic>{
              'productId': line.productId,
              'productName': line.productName,
              'qty': line.quantity,
            },
          )
          .toList(growable: false);
    } else {
      final Object? legacyRawItems = pickFirst(order, const <String>[
        'items',
        'orderItems',
        'order_items',
        'cartItems',
      ]);
      if (legacyRawItems is List) {
        invalidQuantities += legacyRawItems
            .where((Object? item) => item is! Map)
            .length;
        if (legacyRawItems.isEmpty) invalidQuantities++;
      } else {
        invalidQuantities++;
      }
      rawItems = authoritativeOrderItems(order);
    }

    int validLineCount = 0;
    for (final Map<String, dynamic> item in rawItems) {
      final String productId = dataText(
        pickFirst(item, const <String>[
          'productId',
          'product_id',
          'itemCode',
          'productCode',
          'sku',
          'id',
        ]),
      );
      final String itemName = dataText(
        pickFirst(item, const <String>[
          'productName',
          'product_name',
          'itemName',
          'name',
          'displayName',
        ]),
      );
      if (demoProductIds.contains(productId) ||
          (productId.isEmpty &&
              demoProductNames.contains(itemName.toLowerCase()))) {
        excludedDemoProductLines++;
        continue;
      }
      final Object? quantityRaw = pickFirst(item, const <String>[
        'qty',
        'quantity',
        'orderedQty',
        'ordered_qty',
        'boxes',
      ]);
      final num? quantityNumber = quantityRaw is num
          ? quantityRaw
          : num.tryParse(dataText(quantityRaw));
      if (quantityNumber == null ||
          !quantityNumber.isFinite ||
          quantityNumber <= 0 ||
          quantityNumber > absoluteMaxQtyPerLine ||
          quantityNumber != quantityNumber.roundToDouble()) {
        invalidQuantities++;
        continue;
      }
      final int quantity = quantityNumber.toInt();
      final Map<String, dynamic>? product = productById[productId];
      final String productName = itemName.isNotEmpty
          ? itemName
          : dataText(
              pickFirst(product ?? const <String, dynamic>{}, const <String>[
                'itemName',
                'productName',
                'product_name',
                'displayName',
                'name',
              ]),
              fallback: productId.isEmpty ? 'Unidentified product' : productId,
            );
      final String unit = canonical == null
          ? dataText(
              pickFirst(item, const <String>[
                'uom',
                'uomLabel',
                'unitOfMeasure',
                'unit_of_measure',
              ]),
              fallback: dataText(
                pickFirst(product ?? const <String, dynamic>{}, const <String>[
                  'uom',
                  'uomLabel',
                  'unitOfMeasure',
                  'unit_of_measure',
                ]),
              ),
            )
          : 'boxes';
      if (unit.isEmpty) unavailableUnits++;
      final String normalizedUnit = _canonicalUnit(unit);
      final String identity = productId.isEmpty
          ? 'name:${productName.toLowerCase()}'
          : 'id:$productId';
      final String productKey =
          '$identity|${normalizedUnit.isEmpty ? 'unknown' : normalizedUnit}';
      final _LineBuilder builder = lines.putIfAbsent(
        productKey,
        () => _LineBuilder(
          productKey: productKey,
          identity: identity,
          productId: productId,
          productName: productName,
          unit: normalizedUnit == 'boxes' ? 'boxes' : unit,
          weekQuantities: List<int>.filled(weeks.length, 0),
        ),
      );
      builder.weekQuantities[weekIndex] += quantity;
      builder.contributingOrderIds.add(_orderId(order));
      validLineCount++;
    }
    selectedOrders.add(
      RetailerScorecardOrder(
        id: _orderId(order),
        date: date,
        status: _displayStatus(order),
        lineCount: validLineCount,
      ),
    );
  }

  final Map<String, List<_LineBuilder>> byIdentity =
      <String, List<_LineBuilder>>{};
  for (final _LineBuilder line in lines.values) {
    byIdentity.putIfAbsent(line.identity, () => <_LineBuilder>[]).add(line);
  }
  for (final List<_LineBuilder> group in byIdentity.values) {
    final List<_LineBuilder> known = group
        .where((_LineBuilder l) => l.unit.isNotEmpty)
        .toList();
    final List<_LineBuilder> unknown = group
        .where((_LineBuilder l) => l.unit.isEmpty)
        .toList();
    if (known.length != 1 || unknown.isEmpty) continue;
    for (final _LineBuilder u in unknown) {
      for (int i = 0; i < u.weekQuantities.length; i++) {
        known.single.weekQuantities[i] += u.weekQuantities[i];
      }
      known.single.contributingOrderIds.addAll(u.contributingOrderIds);
      lines.remove(u.productKey);
    }
  }

  final List<RetailerScorecardLine> builtLines =
      lines.values
          .map(
            (_LineBuilder line) => RetailerScorecardLine(
              productKey: line.productKey,
              productId: line.productId,
              productName: line.productName,
              unit: line.unit,
              weekQuantities: List<int>.unmodifiable(line.weekQuantities),
              contributingOrderIds: List<String>.unmodifiable(
                line.contributingOrderIds.toList()..sort(),
              ),
            ),
          )
          .toList(growable: false)
        ..sort(
          (RetailerScorecardLine a, RetailerScorecardLine b) => a.productName
              .toLowerCase()
              .compareTo(b.productName.toLowerCase()),
        );
  selectedOrders.sort((RetailerScorecardOrder a, RetailerScorecardOrder b) {
    if (a.date == null) return 1;
    if (b.date == null) return -1;
    return b.date!.compareTo(a.date!);
  });
  return RetailerScorecardReport(
    weeks: weeks,
    lines: List<RetailerScorecardLine>.unmodifiable(builtLines),
    orders: List<RetailerScorecardOrder>.unmodifiable(selectedOrders),
    missingDateCount: missingDates,
    invalidQuantityCount: invalidQuantities,
    malformedCanonicalOrderCount: malformedCanonicalOrders,
    excludedDemoProductLineCount: excludedDemoProductLines,
    unavailableUnitCount: unavailableUnits,
  );
}

DateTime? _malaysiaOrderDate(Map<String, dynamic> order) {
  const List<String> dateKeys = <String>[
    'submittedAt',
    'submitted_at',
    'orderDate',
    'order_date',
    'createdAt',
    'created_at',
    'timestamp',
  ];
  Object? raw;
  DateTime? parsed;
  for (final String key in dateKeys) {
    final Object? candidate = order[key];
    final DateTime? candidateDate = parseFlexibleDate(candidate);
    if (candidateDate == null) continue;
    raw = candidate;
    parsed = candidateDate;
    break;
  }
  if (parsed == null) return null;
  if (raw is Timestamp || raw is DateTime || raw is num) {
    return parsed.toUtc().add(const Duration(hours: 8));
  }
  final String text = dataText(raw);
  if (RegExp(r'^[+-]?\d{9,}(?:\.\d+)?$').hasMatch(text)) {
    return parsed.toUtc().add(const Duration(hours: 8));
  }
  final bool hasZone = RegExp(
    r'(?:Z|[+-]\d{2}:?\d{2})$',
    caseSensitive: false,
  ).hasMatch(text);
  if (!hasZone) {
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }
  return parsed.toUtc().add(const Duration(hours: 8));
}

String _orderId(Map<String, dynamic> order) => dataText(
  pickFirst(order, const <String>['docId', 'orderId', 'order_id', 'id']),
  fallback: 'ID unavailable',
);

String _displayStatus(Map<String, dynamic> order) {
  final String status = orderStatus(order).trim();
  if (status.isEmpty) return 'unknown (missing status)';
  const Set<String> known = <String>{
    'submitted',
    'held_for_review',
    'pending',
    'approved',
    'accepted',
    'in_progress',
    'completed',
    'rejected',
    'cancelled',
    'canceled',
    'void',
  };
  return known.contains(status.toLowerCase())
      ? status.toLowerCase()
      : 'unknown ($status)';
}

class _LineBuilder {
  _LineBuilder({
    required this.productKey,
    required this.identity,
    required this.productId,
    required this.productName,
    required this.unit,
    required this.weekQuantities,
  });

  final String productKey;
  final String identity;
  final String productId;
  final String productName;
  final String unit;
  final List<int> weekQuantities;
  final Set<String> contributingOrderIds = <String>{};
}
