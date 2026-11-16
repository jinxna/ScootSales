import 'csv_export.dart';
import 'order_data_utils.dart';

const List<String> kOrderCsvHeader = <String>[
  'Order ID',
  'Date',
  'Retailer',
  'Salesman',
  'Status',
  'Items',
  'Total Qty',
  'Total Value',
];

String _text(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

List<Object?> orderCsvRow(Map<String, dynamic> order) => <Object?>[
  _text(order['orderId'] ?? order['docId']),
  serializeOrderExportDate(orderDateFromRow(order)),
  _text(order['retailerName'] ?? order['retailer_name']),
  resolveSalesmanName(order, fallback: ''),
  _text(order['status'], fallback: 'submitted'),
  orderItemCount(order),
  orderQuantity(order),
  orderRevenue(order).toStringAsFixed(2),
];

String buildOrdersCsv(Iterable<Map<String, dynamic>> orders) =>
    buildCsv(kOrderCsvHeader, orders.map(orderCsvRow).toList(growable: false));
