String buildCsv(List<String> header, List<List<Object?>> rows) {
  final StringBuffer buffer = StringBuffer();
  buffer.write(_encodeRow(header));
  for (final List<Object?> row in rows) {
    buffer.write('\r\n');
    buffer.write(_encodeRow(row));
  }
  return buffer.toString();
}

String _encodeRow(List<Object?> fields) {
  return fields.map(csvCell).join(',');
}

String csvCell(Object? value) {
  if (value == null) return '';
  String field = value.toString();
  if (value is! String) return _quoteIfNeeded(field);

  final int? firstSignificant = _firstSpreadsheetSignificantCodeUnit(field);
  if (firstSignificant == 0x3D ||
      firstSignificant == 0x2B ||
      firstSignificant == 0x2D ||
      firstSignificant == 0x40) {
    field = "'$field";
  }

  return _quoteIfNeeded(field);
}

String _quoteIfNeeded(String field) {
  final bool mustQuote =
      field.contains(',') ||
      field.contains('"') ||
      field.contains('\n') ||
      field.contains('\r');
  return mustQuote ? '"${field.replaceAll('"', '""')}"' : field;
}

int? _firstSpreadsheetSignificantCodeUnit(String field) {
  for (int i = 0; i < field.length; i++) {
    final int codeUnit = field.codeUnitAt(i);
    if (!_isSpreadsheetPadding(codeUnit)) return codeUnit;
  }
  return null;
}

bool _isSpreadsheetPadding(int codeUnit) {
  return codeUnit <= 0x20 || codeUnit == 0x7F || codeUnit == 0xFEFF;
}
