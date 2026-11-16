import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/catalogue_import.dart';

Uint8List _workbookThatUnderstatesItsSize() {
  final Archive archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        'xl/worksheets/sheet1.xml',
        Uint8List(maxExpandedWorkbookBytes + 1024 * 1024),
      ),
    );
  final Uint8List zip = Uint8List.fromList(ZipEncoder().encode(archive));
  final ByteData data = ByteData.sublistView(zip);
  for (int i = 0; i + 4 <= zip.length; i++) {
    final int signature = data.getUint32(i, Endian.little);
    if (signature == 0x04034b50) data.setUint32(i + 22, 100, Endian.little);
    if (signature == 0x02014b50) data.setUint32(i + 24, 100, Endian.little);
  }
  return zip;
}

void main() {
  test('an xlsx that hides its real unpacked size is refused', () {
    expect(
      () => parseImportFile(_workbookThatUnderstatesItsSize(), 'products.xlsx'),
      throwsA(
        isA<FormatException>().having(
          (FormatException error) => error.message,
          'message',
          contains('50 MB'),
        ),
      ),
    );
  });
}
