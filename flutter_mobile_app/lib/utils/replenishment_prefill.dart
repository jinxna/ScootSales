import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';

import '../edition.dart';
import '../services/cart_draft_cache.dart';
import '../services/project_local_store.dart';

enum ReorderChoiceResult { setInDraft, waitsForAdd, notKept }

class ReorderChoice {
  const ReorderChoice(this.result, this.quantity);

  final ReorderChoiceResult result;
  final int quantity;
}

class ReplenishmentPrefill {
  ReplenishmentPrefill._();

  static const String _storeName = 'reorder_prefill';
  static const Duration _keptFor = Duration(hours: 24);

  static final Map<String, (int, DateTime)> _pending =
      <String, (int, DateTime)>{};
  static String? _loadedFor;

  static String _key(String retailerId, String productId) =>
      '${retailerId.trim()}::${productId.trim()}';

  static Future<ReorderChoice> choose({
    required String retailerId,
    required String productId,
    required int suggestedQty,
  }) async {
    final String retailer = retailerId.trim();
    final String product = productId.trim();
    final String uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (kBasicEdition ||
        uid.isEmpty ||
        retailer.isEmpty ||
        product.isEmpty ||
        suggestedQty < 1) {
      return const ReorderChoice(ReorderChoiceResult.notKept, 0);
    }
    final int? setInDraft = CartDraftCache.setSuggestedQty(
      salesmanUid: uid,
      retailerId: retailer,
      productId: product,
      suggestedQty: suggestedQty,
    );
    if (setInDraft != null) {
      return ReorderChoice(ReorderChoiceResult.setInDraft, setInDraft);
    }
    await _load(uid);
    _pending[_key(retailer, product)] = (suggestedQty, DateTime.now());
    await _save(uid);
    return ReorderChoice(ReorderChoiceResult.waitsForAdd, suggestedQty);
  }

  static Future<int?> take({
    required String retailerId,
    required String productId,
  }) async {
    final String uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (kBasicEdition || uid.isEmpty) return null;
    await _load(uid);
    final (int, DateTime)? choice = _pending.remove(
      _key(retailerId, productId),
    );
    if (choice == null) return null;
    await _save(uid);
    return DateTime.now().difference(choice.$2) <= _keptFor ? choice.$1 : null;
  }

  static void clear() {
    _pending.clear();
    _loadedFor = null;
  }

  static Future<void> _load(String uid) async {
    final ProjectLocalStore store = ProjectLocalStore();
    final String owner = store.prefix(uid);
    if (_loadedFor == owner) return;
    final String? encoded = await store.read(uid, _storeName);
    final Object? decoded = encoded == null || encoded.isEmpty
        ? null
        : jsonDecode(encoded);
    final Map<String, (int, DateTime)> saved = <String, (int, DateTime)>{};
    if (decoded is Map) {
      for (final MapEntry<Object?, Object?> entry in decoded.entries) {
        final Object? row = entry.value;
        if (entry.key is! String || row is! Map) continue;
        final Object? quantity = row['qty'];
        final DateTime? at = DateTime.tryParse('${row['at'] ?? ''}');
        if (quantity is int && quantity >= 1 && at != null) {
          saved[entry.key as String] = (quantity, at);
        }
      }
    }
    _pending
      ..clear()
      ..addAll(saved);
    _loadedFor = owner;
  }

  static Future<void> _save(String uid) {
    return ProjectLocalStore().write(
      uid,
      _storeName,
      jsonEncode(<String, dynamic>{
        for (final MapEntry<String, (int, DateTime)> entry in _pending.entries)
          entry.key: <String, dynamic>{
            'qty': entry.value.$1,
            'at': entry.value.$2.toIso8601String(),
          },
      }),
    );
  }
}
