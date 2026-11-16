import '../edition.dart';

class ReplenishmentPrefill {
  ReplenishmentPrefill._();

  static final Map<String, int> _pending = <String, int>{};

  static String _key(String retailerId, String productId) =>
      '${retailerId.trim()}::${productId.trim()}';

  static void stash({
    required String retailerId,
    required String productId,
    required int suggestedQty,
  }) {
    final String retailer = retailerId.trim();
    final String product = productId.trim();
    if (kBasicEdition) return;
    if (retailer.isEmpty || product.isEmpty || suggestedQty < 1) return;
    _pending[_key(retailer, product)] = suggestedQty;
  }

  static int? take({required String retailerId, required String productId}) {
    return _pending.remove(_key(retailerId, productId));
  }

  static void clear() => _pending.clear();
}
