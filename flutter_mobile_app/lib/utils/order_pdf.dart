import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'quantity_unit.dart';

int _qtyOf(Map<String, dynamic> item) {
  final Object? qty = item['qty'] ?? item['orderQty'] ?? 0;
  return qty is int ? qty : int.tryParse('$qty') ?? 0;
}

class OrderPdf {
  OrderPdf._();

  static Future<void> share({
    required String orderId,
    required int totalProducts,
    required int totalBoxes,
    required DateTime submittedAt,
    required List<Map<String, dynamic>> cartItems,
  }) async {
    final doc = pw.Document();
    final green = PdfColor.fromHex('00A651');
    final darkGreen = PdfColor.fromHex('3C685E');
    final greyCol = PdfColor.fromHex('6B7280');
    final darkCol = PdfColor.fromHex('111827');
    final lightBg = PdfColor.fromHex('F9FAFB');
    final borderCol = PdfColor.fromHex('E5E7EB');

    final hdrStyle = pw.TextStyle(
      color: PdfColors.white,
      fontWeight: pw.FontWeight.bold,
      fontSize: 10,
    );
    final labelStyle = pw.TextStyle(fontSize: 10, color: greyCol);
    final valueStyle = pw.TextStyle(
      fontSize: 10,
      fontWeight: pw.FontWeight.bold,
      color: darkCol,
    );
    final cellStyle = pw.TextStyle(fontSize: 9, color: darkCol);
    final smallGrey = pw.TextStyle(fontSize: 8, color: greyCol);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        build: (ctx) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 12,
            ),
            decoration: pw.BoxDecoration(
              color: green,
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Order Confirmation',
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  orderId,
                  style: pw.TextStyle(color: PdfColors.white, fontSize: 10),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 20),

          pw.Text(
            'Order Summary',
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: darkCol,
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Table(
            border: pw.TableBorder.all(color: borderCol, width: 0.6),
            columnWidths: {
              0: const pw.FlexColumnWidth(2),
              1: const pw.FlexColumnWidth(4),
            },
            children: [
              _pdfRow('Order ID', orderId, labelStyle, valueStyle),
              _pdfRow(
                'Total Items',
                '$totalProducts products · ${cartItems.isEmpty ? quantityLabel(totalBoxes, null) : totalQuantityLabel(cartItems.map((item) => (_qtyOf(item), uomOf(item))))}',
                labelStyle,
                valueStyle,
              ),
              _pdfRow(
                'Submitted At',
                formatDate(submittedAt),
                labelStyle,
                valueStyle,
              ),
            ],
          ),
          pw.SizedBox(height: 20),

          pw.Text(
            'Products',
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: darkCol,
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Table(
            border: pw.TableBorder.all(color: borderCol, width: 0.6),
            columnWidths: {
              0: const pw.FlexColumnWidth(0.5),
              1: const pw.FlexColumnWidth(3.5),
              2: const pw.FlexColumnWidth(2),
              3: const pw.FlexColumnWidth(2.5),
            },
            children: [
              pw.TableRow(
                decoration: pw.BoxDecoration(color: darkGreen),
                children: [
                  _pdfCell('#', hdrStyle),
                  _pdfCell('Product', hdrStyle),
                  _pdfCell('Order Qty / Expiry', hdrStyle),
                  _pdfCell('Stock on Shelf', hdrStyle),
                ],
              ),
              if (cartItems.isEmpty)
                pw.TableRow(
                  children: [
                    _pdfCell('-', cellStyle),
                    _pdfCell('No items', cellStyle),
                    _pdfCell('-', cellStyle),
                    _pdfCell('-', cellStyle),
                  ],
                )
              else
                ...() {
                  final nonZeroItems = cartItems.where((item) {
                    final qty = item['qty'] ?? item['orderQty'] ?? 0;
                    return (qty is int ? qty : int.tryParse('$qty') ?? 0) > 0;
                  }).toList();

                  final Map<String, List<Map<String, dynamic>>> grouped = {};
                  for (final item in nonZeroItems) {
                    final dept =
                        (item['department'] as String?)?.trim().isNotEmpty ==
                            true
                        ? item['department'] as String
                        : 'Others';
                    grouped.putIfAbsent(dept, () => []).add(item);
                  }

                  final rows = <pw.TableRow>[];
                  int globalIdx = 0;

                  grouped.forEach((dept, deptItems) {
                    rows.add(
                      pw.TableRow(
                        decoration: pw.BoxDecoration(
                          color: PdfColor.fromHex('3C685E'),
                        ),
                        children: [
                          pw.Padding(
                            padding: const pw.EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            child: pw.SizedBox(),
                          ),
                          pw.Padding(
                            padding: const pw.EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            child: pw.Text(
                              dept,
                              style: pw.TextStyle(
                                fontSize: 9,
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColors.white,
                              ),
                            ),
                          ),
                          pw.Padding(
                            padding: const pw.EdgeInsets.all(0),
                            child: pw.SizedBox(),
                          ),
                          pw.Padding(
                            padding: const pw.EdgeInsets.all(0),
                            child: pw.SizedBox(),
                          ),
                        ],
                      ),
                    );

                    for (int i = 0; i < deptItems.length; i++) {
                      globalIdx++;
                      final item = deptItems[i];
                      final bg = globalIdx.isOdd ? lightBg : PdfColors.white;
                      final expiry =
                          (item['expiry'] as String?)?.isNotEmpty == true
                          ? item['expiry'] as String
                          : '-';
                      final int qty = _qtyOf(item);
                      final batches = (item['shelfBatches'] as List<dynamic>? ?? [])
                          .map(
                            (b) =>
                                '${quantityLabel((b['qty'] as num?)?.toInt() ?? 0, uomOf(item))}'
                                '${(b['expiry'] as String?)?.isNotEmpty == true ? " (${b['expiry']})" : ""}',
                          )
                          .join('\n');
                      final remarks =
                          (item['remarks'] as String?)?.trim() ?? '';

                      rows.add(
                        pw.TableRow(
                          decoration: pw.BoxDecoration(color: bg),
                          children: [
                            _pdfCell('$globalIdx', cellStyle),
                            pw.Padding(
                              padding: const pw.EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: pw.Column(
                                crossAxisAlignment: pw.CrossAxisAlignment.start,
                                children: [
                                  pw.Text(
                                    '${item['name'] ?? ''}',
                                    style: pw.TextStyle(
                                      fontSize: 9,
                                      fontWeight: pw.FontWeight.bold,
                                      color: darkCol,
                                    ),
                                  ),
                                  if ((item['packingSize'] as String?)
                                          ?.isNotEmpty ==
                                      true)
                                    pw.Text(
                                      '${item['packingSize']}',
                                      style: smallGrey,
                                    ),
                                  if (remarks.isNotEmpty)
                                    pw.Padding(
                                      padding: const pw.EdgeInsets.only(top: 3),
                                      child: pw.Text(
                                        'Remarks: $remarks',
                                        style: pw.TextStyle(
                                          fontSize: 8,
                                          color: greyCol,
                                          fontStyle: pw.FontStyle.italic,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            pw.Padding(
                              padding: const pw.EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: pw.Column(
                                crossAxisAlignment: pw.CrossAxisAlignment.start,
                                children: [
                                  pw.Text(
                                    quantityLabel(qty, uomOf(item)),
                                    style: pw.TextStyle(
                                      fontSize: 9,
                                      fontWeight: pw.FontWeight.bold,
                                      color: darkCol,
                                    ),
                                  ),
                                  pw.Text(expiry, style: smallGrey),
                                ],
                              ),
                            ),
                            _pdfCell(
                              batches.isEmpty ? '-' : batches,
                              cellStyle,
                            ),
                          ],
                        ),
                      );
                    }
                  });

                  return rows;
                }(),
            ],
          ),

          pw.SizedBox(height: 16),
          pw.Divider(color: borderCol, thickness: 0.6),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              'Generated on ${formatDate(DateTime.now())}',
              style: pw.TextStyle(fontSize: 8, color: greyCol),
            ),
          ),
        ],
      ),
    );

    await Printing.layoutPdf(
      onLayout: (_) async => doc.save(),
      name: 'order_$orderId.pdf',
    );
  }

  static pw.TableRow _pdfRow(
    String label,
    String value,
    pw.TextStyle labelStyle,
    pw.TextStyle valueStyle,
  ) {
    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: pw.Text(label, style: labelStyle),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: pw.Text(value, style: valueStyle),
        ),
      ],
    );
  }

  static pw.Widget _pdfCell(String text, pw.TextStyle style) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: pw.Text(text, style: style),
  );

  static String formatDate(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final ap = dt.hour >= 12 ? 'PM' : 'AM';
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year},  $h:$mm:$ss $ap';
  }
}
