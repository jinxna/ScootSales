import '../../utils/csv_export.dart';
import 'catalogue_column.dart';

String catalogueCsv<T>(List<T> rows, List<CatalogueColumn<T>> columns) {
  return buildCsv(
    columns.map((CatalogueColumn<T> c) => c.label).toList(),
    rows
        .map<List<Object?>>(
          (T row) =>
              columns.map((CatalogueColumn<T> c) => c.csvValue(row)).toList(),
        )
        .toList(),
  );
}
