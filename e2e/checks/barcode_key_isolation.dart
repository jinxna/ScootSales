import 'dart:io';

import '../../admin_dashboard/lib/utils/barcode_key.dart' as dashboard;
import '../../flutter_mobile_app/lib/utils/barcode_key.dart' as mobile;

void main() {
  final mobileSource = File.fromUri(
    Platform.script.resolve(
      '../../flutter_mobile_app/lib/utils/barcode_key.dart',
    ),
  ).readAsStringSync();
  final dashboardSource = File.fromUri(
    Platform.script.resolve('../../admin_dashboard/lib/utils/barcode_key.dart'),
  ).readAsStringSync();
  if (mobileSource != dashboardSource) {
    throw StateError('Mobile and dashboard barcode utility sources differ');
  }
  stdout.writeln('PASS: barcode utility source parity');

  final failures = <String>[];
  var checks = 0;
  void check(bool condition, String description) {
    checks++;
    if (!condition) failures.add(description);
  }

  final vectors = <Object?, String>{
    null: '',
    ' --. ': '',
    ' KVD-Shelf.1043 ': 'kvdshelf1043',
    '1234567': '1234567',
    '123456789': '123456789',
    '012345678905': '00012345678905',
    '0012345678905': '00012345678905',
    '00012345678905': '00012345678905',
    ' 012-345 678.905 ': '00012345678905',
    '96385074': '00000096385074',
    '10012345000017': '10012345000017',
    '012345678906': '012345678906',
    '0012345678906': '0012345678906',
    '10012345000018': '10012345000018',
    '96385075': '96385075',
    'A012345678905': 'a012345678905',
    123456789012: '00123456789012',
    '03456703': '00034000005673',
    '01234514': '00012100003454',
    '01234523': '00012200003453',
    '09847531': '00098400000751',
    '04567840': '00045670000080',
    '01234558': '00012345000058',
    '01234596': '00012345000096',
    '01200003': '00012000000003',
    '01234559': '01234559',
    '0345670': '0345670',
    '345670': '345670',
    '13456703': '13456703',
  };

  for (final entry in vectors.entries) {
    check(
      mobile.barcodeKey(entry.key) == entry.value,
      'mobile key ${entry.key}: ${mobile.barcodeKey(entry.key)} != ${entry.value}',
    );
    check(
      dashboard.barcodeKey(entry.key) == entry.value,
      'dashboard key ${entry.key}: ${dashboard.barcodeKey(entry.key)} != ${entry.value}',
    );
    check(
      mobile.barcodeKey(entry.value) == entry.value,
      'key must be idempotent: ${entry.key}',
    );
  }

  for (final match in [mobile.barcodesMatch, dashboard.barcodesMatch]) {
    check(match('0012345678905', '012345678905'), 'EAN/UPC equivalence');
    check(match('03456703', '034000005673'), 'UPC-E/UPC-A equivalence');
    check(match('KVD-Shelf.1043', 'kvd shelf 1043'), 'legacy normalization');
    check(!match(null, '--'), 'empty keys never match');
    check(!match('012345678906', '0012345678906'), 'bad checksums stay raw');
    check(
      !match('10012345000017', '00012345678905'),
      'different GTINs stay distinct',
    );
  }
  for (final query in [
    mobile.barcodeMatchesQuery,
    dashboard.barcodeMatchesQuery,
  ]) {
    check(query('03456703', '4567'), 'search retains compressed substring');
    check(query('03456703', '034000005673'), 'search accepts equivalent GTIN');
    check(query('012345678905', '6789'), 'search retains partial digits');
    check(query('KVD-Shelf.1043', 'SHELF'), 'legacy substring search');
    check(!query('012345678905', '--'), 'empty search never matches');
    check(!query('123', '0000'), 'padding cannot create substring matches');
  }
  if (failures.isNotEmpty) {
    throw StateError(
      '${failures.length}/$checks failures:\n${failures.join('\n')}',
    );
  }
  stdout.writeln(
    'PASS: $checks barcode normalization and search checks across both apps',
  );
}
