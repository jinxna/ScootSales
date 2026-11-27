import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/data_number.dart';
import '../utils/order_status.dart';
import '../utils/quantity_unit.dart';
import 'project_local_store.dart';

class LastOrderLine {
  const LastOrderLine({
    required this.productId,
    required this.name,
    required this.quantity,
    required this.uom,
  });

  final String productId;
  final String name;
  final int quantity;
  final String? uom;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'productId': productId,
    'name': name,
    'quantity': quantity,
    if (uom != null) 'uom': uom,
  };

  static LastOrderLine? fromMap(Map<Object?, Object?> data) {
    final String name = '${data['name'] ?? data['productName'] ?? ''}'.trim();
    final int quantity =
        (dataNumberOrNull(
                  data['quantity'] ?? data['qty'] ?? data['orderQty'],
                ) ??
                0)
            .round();
    if (name.isEmpty || quantity < 1) return null;
    return LastOrderLine(
      productId: '${data['productId'] ?? ''}'.trim(),
      name: name,
      quantity: quantity,
      uom: uomOf(Map<String, dynamic>.from(data)),
    );
  }
}

class LastOrder {
  const LastOrder({
    required this.orderId,
    required this.retailerId,
    required this.orderedAt,
    required this.lines,
    required this.totalRm,
    this.retailerName = '',
    this.status = '',
  });

  final String orderId;
  final String retailerId;
  final String retailerName;
  final String status;
  final DateTime orderedAt;
  final List<LastOrderLine> lines;
  final double totalRm;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'orderId': orderId,
    'retailerId': retailerId,
    'orderedAt': orderedAt.toIso8601String(),
    'lines': lines
        .map((LastOrderLine line) => line.toMap())
        .toList(growable: false),
    'totalRm': totalRm,
    'retailerName': retailerName,
    'status': status,
  };

  static LastOrder? fromOrder(String orderId, Map<String, dynamic> data) {
    final String retailerId = '${data['retailerId'] ?? ''}'.trim();
    final DateTime? orderedAt = _when(
      data['orderedAt'] ?? data['submittedAt'] ?? data['createdAt'],
    );
    if (retailerId.isEmpty || orderedAt == null) return null;
    final Object? rawLines = data['lines'] ?? data['items'];
    return LastOrder(
      orderId: '${data['orderId'] ?? orderId}'.trim(),
      retailerId: retailerId,
      orderedAt: orderedAt,
      lines: rawLines is List
          ? rawLines
                .whereType<Map>()
                .map(LastOrderLine.fromMap)
                .whereType<LastOrderLine>()
                .toList(growable: false)
          : const <LastOrderLine>[],
      totalRm: dataNumberOrNull(data['totalRm'] ?? data['totalPrice']) ?? 0,
      retailerName: '${data['retailerName'] ?? data['outlet'] ?? ''}'.trim(),
      status: resolveMobileOrderStatus(data),
    );
  }

  static DateTime? _when(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse('${value ?? ''}');
  }
}

class LastOrdersRead {
  const LastOrdersRead({required this.byRetailer, required this.voidOrderIds});

  final Map<String, LastOrder> byRetailer;
  final Set<String> voidOrderIds;
}

LastOrdersRead lastOrdersFromNewestFirst(
  Iterable<MapEntry<String, Map<String, dynamic>>> ordersNewestFirst,
) {
  final Map<String, LastOrder> byRetailer = <String, LastOrder>{};
  final Set<String> voidOrderIds = <String>{};
  for (final MapEntry<String, Map<String, dynamic>> entry
      in ordersNewestFirst) {
    final String status = resolveMobileOrderStatus(entry.value);
    if (status == 'Cancelled' || status == 'Rejected') {
      voidOrderIds
        ..add(entry.key)
        ..add('${entry.value['orderId'] ?? entry.key}'.trim());
      continue;
    }
    final LastOrder? order = LastOrder.fromOrder(entry.key, entry.value);
    if (order == null) continue;
    final LastOrder? known = byRetailer[order.retailerId];
    if (known == null || order.orderedAt.isAfter(known.orderedAt)) {
      byRetailer[order.retailerId] = order;
    }
  }
  return LastOrdersRead(byRetailer: byRetailer, voidOrderIds: voidOrderIds);
}

class LastOrderService {
  LastOrderService({FirebaseFirestore? firestore, ProjectLocalStore? store})
    : _db = firestore ?? FirebaseFirestore.instance,
      _store = store ?? ProjectLocalStore();

  static const String storeName = 'last_orders';
  static const Duration _readTimeout = Duration(seconds: 10);
  static const Duration _reuseFor = Duration(minutes: 2);
  static const int _newestOrders = 200;

  static final Map<String, (DateTime, Future<Map<String, LastOrder>>)> _reads =
      <String, (DateTime, Future<Map<String, LastOrder>>)>{};

  final FirebaseFirestore _db;
  final ProjectLocalStore _store;

  Stream<LastOrder?> watch({
    required String uid,
    required String retailerId,
  }) async* {
    final String owner = uid.trim();
    final String shop = retailerId.trim();
    if (owner.isEmpty || shop.isEmpty) return;
    final LastOrder? saved = (await _saved(owner))[shop];
    if (saved != null) yield saved;
    final Map<String, LastOrder> current;
    try {
      current = await _current(owner);
    } on FirebaseException {
      return;
    } on TimeoutException {
      return;
    }
    final LastOrder? fresh = current[shop];
    if (fresh != null || saved != null) yield fresh;
  }

  Future<LastOrder?> lastOrderFor({
    required String uid,
    required String retailerId,
  }) => watch(
    uid: uid,
    retailerId: retailerId,
  ).fold<LastOrder?>(null, (LastOrder? _, LastOrder? next) => next);

  Future<Map<String, LastOrder>> lastOrders(
    String uid, {
    bool online = true,
  }) async {
    final String owner = uid.trim();
    if (owner.isEmpty) return const <String, LastOrder>{};
    if (!online) return _saved(owner);
    try {
      return await _current(owner);
    } on FirebaseException {
      return _saved(owner);
    } on TimeoutException {
      return _saved(owner);
    }
  }

  Future<Map<String, LastOrder>> _current(String uid) {
    final String key = '${_store.projectId}|$uid';
    final (DateTime, Future<Map<String, LastOrder>>)? known = _reads[key];
    final DateTime now = DateTime.now();
    if (known != null && now.difference(known.$1) < _reuseFor) {
      return known.$2;
    }
    final Future<Map<String, LastOrder>> read = _readAndSave(uid);
    _reads[key] = (now, read);
    unawaited(
      read.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_reads[key]?.$2, read)) _reads.remove(key);
        },
      ),
    );
    return read;
  }

  Future<Map<String, LastOrder>> _readAndSave(String uid) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _db
        .collection('orders')
        .where('salesmanUid', isEqualTo: uid)
        .orderBy('submittedAt', descending: true)
        .limit(_newestOrders)
        .get()
        .timeout(_readTimeout);
    final LastOrdersRead read = lastOrdersFromNewestFirst(
      snapshot.docs.map(
        (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
            MapEntry<String, Map<String, dynamic>>(doc.id, doc.data()),
      ),
    );
    final Map<String, LastOrder> merged = <String, LastOrder>{
      for (final MapEntry<String, LastOrder> entry in (await _saved(
        uid,
      )).entries)
        if (!read.voidOrderIds.contains(entry.value.orderId))
          entry.key: entry.value,
      ...read.byRetailer,
    };
    await _store.write(
      uid,
      storeName,
      jsonEncode(<String, dynamic>{
        for (final MapEntry<String, LastOrder> entry in merged.entries)
          entry.key: entry.value.toMap(),
      }),
    );
    return merged;
  }

  Future<Map<String, LastOrder>> _saved(String uid) async {
    final String? encoded = await _store.read(uid, storeName);
    if (encoded == null || encoded.isEmpty) return const <String, LastOrder>{};
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! Map) return const <String, LastOrder>{};
    final Map<String, LastOrder> saved = <String, LastOrder>{};
    for (final MapEntry<Object?, Object?> entry in decoded.entries) {
      final Object? row = entry.value;
      if (entry.key is! String || row is! Map) continue;
      final LastOrder? order = LastOrder.fromOrder(
        '',
        Map<String, dynamic>.from(row),
      );
      if (order != null) saved[entry.key as String] = order;
    }
    return saved;
  }
}
