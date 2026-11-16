import 'dart:collection';

class CollectionRows extends ListBase<Map<String, dynamic>> {
  CollectionRows(
    Iterable<Map<String, dynamic>> rows, {
    required this.isComplete,
    this.coveredSince,
    this.locationCoverage,
  }) : _rows = List<Map<String, dynamic>>.unmodifiable(rows);

  final List<Map<String, dynamic>> _rows;
  final bool isComplete;
  final DateTime? coveredSince;
  final CollectionRows? locationCoverage;

  @override
  int get length => _rows.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only rows');
  @override
  Map<String, dynamic> operator [](int index) => _rows[index];
  @override
  void operator []=(int index, Map<String, dynamic> value) =>
      throw UnsupportedError('Read-only rows');
}

bool collectionRowsComplete(List<Map<String, dynamic>>? rows) =>
    rows is CollectionRows && rows.isComplete;

DateTime? collectionRowsCoverage(List<Map<String, dynamic>>? rows) =>
    rows is CollectionRows ? rows.coveredSince : null;

bool collectionRowsCover(List<Map<String, dynamic>>? rows, DateTime since) {
  if (rows is! CollectionRows) return false;
  if (rows.isComplete) return true;
  final DateTime? coveredSince = rows.coveredSince;
  return coveredSince != null && !coveredSince.isAfter(since);
}

CollectionRows? collectionRowsLocationCoverage(
  List<Map<String, dynamic>>? rows,
) => rows is CollectionRows ? rows.locationCoverage : null;

bool locationRowsCover(List<Map<String, dynamic>>? rows, DateTime since) =>
    collectionRowsCover(collectionRowsLocationCoverage(rows), since);

final DateTime coversAllRows = DateTime.utc(1);

DateTime? combinedCoverage(Iterable<List<Map<String, dynamic>>?> parts) {
  DateTime latest = coversAllRows;
  for (final List<Map<String, dynamic>>? part in parts) {
    if (part is! CollectionRows) return null;
    if (part.isComplete) continue;
    final DateTime? since = part.coveredSince;
    if (since == null) return null;
    if (since.isAfter(latest)) latest = since;
  }
  return latest;
}

DateTime? laterCoverage(DateTime? a, DateTime? b) {
  if (a == null || b == null) return null;
  return a.isAfter(b) ? a : b;
}
