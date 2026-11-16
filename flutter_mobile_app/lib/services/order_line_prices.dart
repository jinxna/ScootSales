import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../utils/data_number.dart';
import 'project_local_store.dart';

const String retailerSheetPriceSource = 'retailer_sheet';
const String masterCataloguePriceSource = 'master_catalogue';

class EffectiveLinePrice {
  const EffectiveLinePrice(this.unitPrice, this.source);

  final double? unitPrice;
  final String source;

  bool get isValid => unitPrice != null && unitPriceCents(unitPrice!) > 0;
}

int unitPriceCents(num price) => (price * 100).round();

double? _positivePrice(Object? raw) {
  final double? value = dataNumberOrNull(raw);
  if (value == null || !value.isFinite || unitPriceCents(value) < 1) {
    return null;
  }
  return value;
}

EffectiveLinePrice effectiveLinePrice({
  required String productId,
  required Map<String, dynamic> product,
  required Map<String, dynamic>? retailerSheet,
}) {
  final Object? overrides = retailerSheet?['productOverrides'];
  final Object? override = overrides is Map ? overrides[productId] : null;
  if (override is Map) {
    for (final String field in const <String>['unitPrice', 'price']) {
      if (override.containsKey(field) && override[field] != null) {
        return EffectiveLinePrice(
          _positivePrice(override[field]),
          retailerSheetPriceSource,
        );
      }
    }
  }
  for (final String field in const <String>['unitPrice', 'price']) {
    if (product.containsKey(field) && product[field] != null) {
      return EffectiveLinePrice(
        _positivePrice(product[field]),
        masterCataloguePriceSource,
      );
    }
  }
  return const EffectiveLinePrice(null, masterCataloguePriceSource);
}

class RetailerSheetUnavailable implements Exception {
  const RetailerSheetUnavailable();

  @override
  String toString() =>
      'This retailer\'s score sheet is not available on this device. Connect once to prepare it.';
}

class CurrentLinePrices {
  CurrentLinePrices._();

  static const String _absentSheetValue = 'absent';

  static String _absentSheetName(String retailerId) =>
      'retailer_sheet_absent_v1.${ProjectLocalStore.encode(retailerId)}';

  static Future<void> rememberSheet(
    String retailerId,
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty || retailerId.trim().isEmpty) return;
    try {
      final ProjectLocalStore store = ProjectLocalStore();
      final String name = _absentSheetName(retailerId);
      final String? marker = await store.read(uid, name);
      if (snapshot.exists) {
        if (marker != null) await store.remove(uid, name);
      } else if (!snapshot.metadata.isFromCache &&
          marker != _absentSheetValue) {
        await store.write(uid, name, _absentSheetValue);
      }
    } catch (_) {}
  }

  static Future<bool> confirmedNoSheet(String retailerId) async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty || retailerId.trim().isEmpty) return false;
    try {
      return await ProjectLocalStore().read(
            uid,
            _absentSheetName(retailerId),
          ) ==
          _absentSheetValue;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> retailerSheet(
    String retailerId, {
    Source source = Source.serverAndCache,
  }) async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot;
    try {
      snapshot = await FirebaseFirestore.instance
          .collection('retailer_score_sheet_settings')
          .doc(retailerId)
          .get(GetOptions(source: source));
    } on FirebaseException catch (error) {
      if (error.code != 'unavailable') rethrow;
      if (await confirmedNoSheet(retailerId)) return null;
      throw const RetailerSheetUnavailable();
    }
    if (!snapshot.exists &&
        snapshot.metadata.isFromCache &&
        !await confirmedNoSheet(retailerId)) {
      throw const RetailerSheetUnavailable();
    }
    await rememberSheet(retailerId, snapshot);
    return snapshot.data();
  }

  static Future<Map<String, EffectiveLinePrice>> load({
    required String retailerId,
    required Iterable<String> productIds,
    Source source = Source.serverAndCache,
    Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>? productReads,
  }) async {
    final CollectionReference<Map<String, dynamic>> products = FirebaseFirestore
        .instance
        .collection('products');
    final List<String> ids = productIds
        .where((String id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final Future<Map<String, dynamic>?> sheetRead = retailerSheet(
      retailerId,
      source: source,
    );
    sheetRead.ignore();
    final Future<List<DocumentSnapshot<Map<String, dynamic>>>> foundRead =
        Future.wait(
          ids.map(
            (String id) =>
                productReads?[id] ??
                products.doc(id).get(GetOptions(source: source)),
          ),
        );
    foundRead.ignore();
    final Map<String, dynamic>? sheet = await sheetRead;
    final List<DocumentSnapshot<Map<String, dynamic>>> found = await foundRead;
    return <String, EffectiveLinePrice>{
      for (final DocumentSnapshot<Map<String, dynamic>> product in found)
        if (product.exists)
          product.id: effectiveLinePrice(
            productId: product.id,
            product: product.data()!,
            retailerSheet: sheet,
          ),
    };
  }
}
