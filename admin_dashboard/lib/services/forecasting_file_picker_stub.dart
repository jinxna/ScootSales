import 'dart:typed_data';

class PickedFile {
  const PickedFile(this.bytes, this.name);

  final Uint8List bytes;
  final String name;
}

Future<PickedFile?> pickSpreadsheetFile() async => null;
