import 'package:cloud_firestore/cloud_firestore.dart';

import 'app_logger.dart';
import 'firestore_query_utils.dart';
import 'order_data_utils.dart';
import 'quantity_unit.dart';

int orderLineQuantity(Map<String, dynamic> item) =>
    (dataNumberOrNull(item['qty']) ?? dataNumberOrNull(item['orderedQty']) ?? 0)
        .toInt();

Future<List<String>> readOrderLimitWarnings(
  List<Map<String, dynamic>> items, {
  FirebaseFirestore? firestore,
}) async {
  try {
    final FirebaseFirestore db = firestore ?? FirebaseFirestore.instance;
    final Set<String> productIds = <String>{
      for (final Map<String, dynamic> it in items)
        if (dataText(it['productId']).isNotEmpty && orderLineQuantity(it) > 0)
          dataText(it['productId']),
    };
    final Map<String, Map<String, dynamic>> products =
        <String, Map<String, dynamic>>{};
    final List<QuerySnapshot<Map<String, dynamic>>> reads = await Future.wait(
      chunkFirestoreWhereIn(productIds).map(
        (List<String> chunk) => db
            .collection('products')
            .where(FieldPath.documentId, whereIn: chunk)
            .get(),
      ),
    );
    for (final QuerySnapshot<Map<String, dynamic>> read in reads) {
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in read.docs) {
        products[doc.id] = doc.data();
      }
    }
    final List<String?> lines = items
        .map((Map<String, dynamic> it) {
          final String productId = dataText(it['productId']);
          final int qty = orderLineQuantity(it);
          if (productId.isEmpty || qty <= 0) return null;
          final Map<String, dynamic>? product = products[productId];
          if (product == null) return null;
          final int limit = maxQtyFor(product);
          if (qty <= limit) return null;
          final String name = dataText(
            it['productName'] ?? it['name'],
            fallback: productId,
          );
          return '$name: ${quantityLabel(qty, uomOf(it) ?? uomOf(product))} '
              "ordered; this product's limit is $limit.";
        })
        .toList(growable: false);
    return lines.whereType<String>().toList(growable: false);
  } catch (error) {
    AppLogger.error('order_details_limit_read', error: error);
    return const <String>[
      'Product order limits could not be checked. Check the quantities before approving.',
    ];
  }
}
