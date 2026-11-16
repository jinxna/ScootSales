// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

bool downloadCsv({required String filename, required String csv}) {
  final html.Blob blob = html.Blob(<Object>[csv], 'text/csv;charset=utf-8');
  final String url = html.Url.createObjectUrlFromBlob(blob);
  final html.AnchorElement anchor = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return true;
}
