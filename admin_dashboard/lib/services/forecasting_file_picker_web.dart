// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

class PickedFile {
  const PickedFile(this.bytes, this.name);

  final Uint8List bytes;
  final String name;
}

Future<PickedFile?> pickSpreadsheetFile() async {
  final html.FileUploadInputElement input = html.FileUploadInputElement()
    ..accept = '.xlsx,.xls,.xlsm,.csv,.tsv'
    ..multiple = false;
  input.click();
  await input.onChange.first;
  final List<html.File>? files = input.files;
  if (files == null || files.isEmpty) return null;
  final html.File file = files.first;
  final html.FileReader reader = html.FileReader();
  reader.readAsArrayBuffer(file);
  await reader.onLoad.first;
  final Object? result = reader.result;
  if (result is! List<int>) return null;
  return PickedFile(Uint8List.fromList(result), file.name);
}
