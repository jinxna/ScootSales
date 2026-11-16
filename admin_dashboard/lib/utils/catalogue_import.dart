import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel_community/excel_community.dart';

import 'barcode_key.dart';
import 'catalogue_product_availability.dart';
import 'price_stamp.dart';
import 'quantity_unit.dart';

const int maxImportFileBytes = 10 * 1024 * 1024;
const int maxExpandedWorkbookBytes = 50 * 1024 * 1024;
const int maxWorkbookEntries = 2000;
const int maxAtomicImportWrites = 450;

const int maxCatalogueProductIdLength = 100;
const int maxCatalogueHierarchyIdLength = 200;
const int maxCatalogueGroupNameLength = 100;
const int maxCatalogueProductTextLength = 200;
const int maxCatalogueSupportingTextLength = 100;
const int maxCatalogueUomLength = 32;
const int maxCatalogueBrandNameLength = 100;
const int maxCatalogueSortOrder = 1000000;

const double maxCatalogueUnitPrice = 1000000.0;
const String cataloguePriceRangeLabel = 'RM 0 to RM 1,000,000';

class CatalogueImportRow {
  const CatalogueImportRow({
    required this.product,
    required this.updateProduct,
    required this.errors,
    required this.warnings,
    required this.sourceRow,
    this.legacyProductId = '',
    this.requestedProductId = '',
  });

  final Map<String, dynamic> product;
  final Map<String, dynamic> updateProduct;
  final List<String> errors;
  final List<String> warnings;
  final int sourceRow;
  final String legacyProductId;
  final String requestedProductId;

  String get productId => '${product['productId'] ?? ''}'.trim();

  bool? requestedVisible({required bool exists}) {
    if (!exists) return product['isVisible'] == true;
    if (!updateProduct.containsKey('isVisible')) return null;
    return updateProduct['isVisible'] == true;
  }

  Map<String, dynamic> writeFields({
    required bool exists,
    Map<String, dynamic>? existingProduct,
  }) {
    final Map<String, dynamic> fields = <String, dynamic>{
      ...(exists ? updateProduct : product),
    }..removeWhere((String key, _) => key == 'isVisible' || key == 'status');
    final Map<String, dynamic> stored = exists
        ? (existingProduct ?? const <String, dynamic>{})
        : cataloguePriceFields(0);
    fields.addAll(
      priceStampFor(
        changed: const <String>['unitPrice', 'price', 'priceGuide'].any(
          (String key) =>
              fields.containsKey(key) &&
              (!stored.containsKey(key) || stored[key] != fields[key]),
        ),
      ),
    );
    if (!exists) {
      fields['isVisible'] = false;
      fields['status'] = 'hidden';
    }
    return fields;
  }
}

class CatalogueImportPlan {
  const CatalogueImportPlan({
    required this.rows,
    required this.departments,
    required this.categories,
  });

  final List<CatalogueImportRow> rows;
  final Map<String, Map<String, dynamic>> departments;
  final Map<String, Map<String, dynamic>> categories;

  int get plannedWrites =>
      rows.length + departments.length + categories.length + 1;
}

List<CatalogueImportRow> withCatalogueBarcodeWarnings(
  List<CatalogueImportRow> rows, {
  required Map<String, Map<String, dynamic>> existingProducts,
}) {
  final Map<String, Map<String, dynamic>> effectiveProducts = {
    ...existingProducts,
    for (final CatalogueImportRow row in rows)
      if (row.productId.isNotEmpty)
        row.productId: existingProducts.containsKey(row.productId)
            ? <String, dynamic>{
                ...existingProducts[row.productId]!,
                ...row.updateProduct,
              }
            : row.product,
  };
  final Map<String, Set<String>> productIdsByKey = <String, Set<String>>{};
  final Map<String, String> keysByProductId = <String, String>{};
  for (final entry in effectiveProducts.entries) {
    if (!isCatalogueProductVisible(entry.value)) continue;
    final String itemBarcode = '${entry.value['itemBarcode'] ?? ''}'.trim();
    final String key = barcodeKey(
      itemBarcode.isNotEmpty ? itemBarcode : entry.value['barcode'],
    );
    if (key.isEmpty) continue;
    keysByProductId[entry.key] = key;
    productIdsByKey.putIfAbsent(key, () => <String>{}).add(entry.key);
  }
  return rows
      .map((CatalogueImportRow row) {
        final String? key = keysByProductId[row.productId];
        if (key == null || productIdsByKey[key]!.length < 2) return row;
        final List<String> otherIds =
            productIdsByKey[key]!
                .where((String id) => id != row.productId)
                .toList()
              ..sort();
        final String warning =
            'Duplicate active barcode "$key" also belongs to product ID(s): ${otherIds.join(', ')}';
        return CatalogueImportRow(
          product: row.product,
          updateProduct: row.updateProduct,
          errors: row.errors,
          warnings: <String>{...row.warnings, warning}.toList(growable: false),
          sourceRow: row.sourceRow,
          legacyProductId: row.legacyProductId,
          requestedProductId: row.requestedProductId,
        );
      })
      .toList(growable: false);
}

List<Map<String, dynamic>> parseImportFile(
  Uint8List bytes,
  String fileName, {
  bool catalogueOnly = false,
}) {
  if (bytes.isEmpty) throw const FormatException('The selected file is empty.');
  if (bytes.length > maxImportFileBytes) {
    throw const FormatException(
      'The selected file is larger than 10 MB. Split it before importing.',
    );
  }

  final String extension = _extension(fileName);
  return switch (extension) {
    'csv' => _parseDelimited(
      bytes,
      preferredDelimiter: ',',
      catalogueOnly: catalogueOnly,
    ),
    'tsv' => _parseDelimited(
      bytes,
      preferredDelimiter: '\t',
      catalogueOnly: catalogueOnly,
    ),
    'xlsx' => _parseXlsx(bytes, catalogueOnly: catalogueOnly),
    'xls' => throw const FormatException(
      'Legacy .xls files are not supported. Save the workbook as .xlsx, CSV, or TSV first.',
    ),
    'xlsm' => throw const FormatException(
      'Macro-enabled .xlsm files are not accepted. Save a clean copy as .xlsx, CSV, or TSV first.',
    ),
    _ => throw const FormatException('Choose a .xlsx, .csv, or .tsv file.'),
  };
}

CatalogueImportPlan buildCatalogueImportPlan(
  List<Map<String, dynamic>> sourceRows,
) {
  final List<CatalogueImportRow> rows = <CatalogueImportRow>[];
  String departmentContext = '';
  String categoryContext = '';
  String subCategoryContext = '';
  String sourceSheetContext = '';

  for (int index = 0; index < sourceRows.length; index++) {
    final Map<String, dynamic> source = sourceRows[index];
    final _RowReader reader = _RowReader(source);
    final String sourceSheet = '${source['_sourceSheet'] ?? ''}'.trim();
    if (sourceSheetContext.isNotEmpty &&
        sourceSheet.isNotEmpty &&
        sourceSheet != sourceSheetContext) {
      departmentContext = '';
      categoryContext = '';
      subCategoryContext = '';
    }
    if (sourceSheet.isNotEmpty) sourceSheetContext = sourceSheet;
    final String explicitDepartment = reader.text(_departmentAliases);
    final String explicitCategory = reader.text(_categoryAliases);
    final String explicitSubCategory = reader.text(_subCategoryAliases);
    if (explicitDepartment.isNotEmpty &&
        explicitDepartment != departmentContext) {
      categoryContext = '';
      subCategoryContext = '';
    }
    if (explicitDepartment.isNotEmpty) departmentContext = explicitDepartment;
    if (explicitCategory.isNotEmpty && explicitCategory != categoryContext) {
      subCategoryContext = '';
    }
    if (explicitCategory.isNotEmpty) categoryContext = explicitCategory;
    if (explicitSubCategory.isNotEmpty) {
      subCategoryContext = explicitSubCategory;
    }

    final String productName = reader.text(_productNameAliases);
    final String suppliedId = reader.text(_productIdAliases);
    final String barcode = reader
        .text(_barcodeAliases)
        .replaceAll(RegExp(r'\s+'), '');
    final bool isHeadingOnly =
        productName.isEmpty &&
        suppliedId.isEmpty &&
        barcode.isEmpty &&
        (explicitDepartment.isNotEmpty ||
            explicitCategory.isNotEmpty ||
            explicitSubCategory.isNotEmpty);
    if (isHeadingOnly) continue;

    final List<String> errors = <String>[];
    final List<String> warnings = <String>[];
    if (productName.isEmpty) errors.add('Missing product/item name');

    String departmentName = explicitDepartment.isNotEmpty
        ? explicitDepartment
        : departmentContext;
    String categoryName = explicitCategory.isNotEmpty
        ? explicitCategory
        : categoryContext;
    final String subCategoryName = explicitSubCategory.isNotEmpty
        ? explicitSubCategory
        : subCategoryContext;
    if (departmentName.isEmpty) {
      departmentName = 'GENERAL';
      warnings.add('No department supplied; grouped under GENERAL');
    }
    if (categoryName.isEmpty) {
      categoryName = 'UNCATEGORISED';
      warnings.add('No category supplied; grouped under UNCATEGORISED');
    }

    final String itemCode = reader.text(_itemCodeAliases);
    final String brandName = reader
        .text(_brandAliases)
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    final String packingSize = reader.text(_packingAliases);
    _addTextLengthError(
      errors,
      label: 'Product/item name',
      value: productName,
      maxLength: maxCatalogueProductTextLength,
    );
    _addTextLengthError(
      errors,
      label: 'Department name',
      value: departmentName,
      maxLength: maxCatalogueGroupNameLength,
    );
    _addTextLengthError(
      errors,
      label: 'Category name',
      value: categoryName,
      maxLength: maxCatalogueGroupNameLength,
    );
    _addTextLengthError(
      errors,
      label: 'Subcategory name',
      value: subCategoryName,
      maxLength: maxCatalogueGroupNameLength,
    );
    _addTextLengthError(
      errors,
      label: 'Item code',
      value: itemCode,
      maxLength: maxCatalogueSupportingTextLength,
    );
    _addTextLengthError(
      errors,
      label: 'Brand name',
      value: brandName,
      maxLength: maxCatalogueBrandNameLength,
    );
    _addTextLengthError(
      errors,
      label: 'Barcode',
      value: barcode,
      maxLength: maxCatalogueSupportingTextLength,
    );
    _addTextLengthError(
      errors,
      label: 'Packing size',
      value: packingSize,
      maxLength: maxCatalogueSupportingTextLength,
    );
    final String generatedIdSource = <String>[
      departmentName,
      categoryName,
      if (brandName.isNotEmpty) brandName,
      itemCode.isNotEmpty
          ? itemCode
          : barcode.isNotEmpty
          ? barcode
          : productName,
      if (itemCode.isEmpty && barcode.isEmpty && packingSize.isNotEmpty)
        packingSize,
    ].join('\u0000');
    final String productId = cleanImportId(
      suppliedId.isNotEmpty ? suppliedId : generatedIdSource,
    );
    if (productId.isEmpty) {
      errors.add('A stable product ID could not be generated');
    }
    _addTextLengthError(
      errors,
      label: 'Product ID',
      value: productId,
      maxLength: maxCatalogueProductIdLength,
    );
    if (suppliedId.isEmpty && productId.isNotEmpty) {
      warnings.add('Product ID generated from row content');
    }

    final String priceText = reader.text(_priceAliases);
    final double? parsedPrice = parseCataloguePrice(priceText);
    if (priceText.isNotEmpty && parsedPrice == null) {
      errors.add(
        'Price is not a valid number in the allowed range ($cataloguePriceRangeLabel)',
      );
    } else if (parsedPrice == null) {
      warnings.add('No price supplied; defaulted to 0');
    }

    final String departmentId = cleanImportId(departmentName);
    final String categoryId = cleanImportId(
      '$departmentName\u0000$categoryName',
    );
    _addTextLengthError(
      errors,
      label: 'Department ID',
      value: departmentId,
      maxLength: maxCatalogueProductIdLength,
    );
    _addTextLengthError(
      errors,
      label: 'Category ID',
      value: categoryId,
      maxLength: maxCatalogueHierarchyIdLength,
    );
    final bool isVisible = _readVisible(reader);
    final String sortOrderText = reader.text(_sortOrderAliases);
    final int? parsedSortOrder = parseCatalogueSortOrder(sortOrderText);
    if (sortOrderText.isNotEmpty && parsedSortOrder == null) {
      errors.add(
        'Sort order must be a whole number from 0 to $maxCatalogueSortOrder',
      );
    }
    final int sortOrder = parsedSortOrder ?? index;
    final String maxOrderQtyText = reader.text(_maxOrderQtyAliases);
    final int? maxOrderQty = parseCatalogueMaxOrderQty(maxOrderQtyText);
    if (maxOrderQtyText.isNotEmpty && maxOrderQty == null) {
      errors.add(catalogueMaxOrderQtyError);
    }
    final String uom = reader.text(_uomAliases).isEmpty
        ? 'ctn'
        : reader.text(_uomAliases);
    final String displayName = packingSize.isEmpty || productName.contains('(')
        ? productName
        : '$productName ($packingSize)';
    _addTextLengthError(
      errors,
      label: 'Product display name',
      value: displayName,
      maxLength: maxCatalogueProductTextLength,
    );
    _addTextLengthError(
      errors,
      label: 'Unit of measure',
      value: uom,
      maxLength: maxCatalogueUomLength,
    );

    final bool hasHierarchyDepartment =
        explicitDepartment.isNotEmpty ||
        (departmentContext.isNotEmpty && departmentName != 'GENERAL');
    final bool hasHierarchyCategory =
        explicitCategory.isNotEmpty ||
        (categoryContext.isNotEmpty && categoryName != 'UNCATEGORISED');
    final bool hasVisibility =
        reader.text(_visibleAliases).isNotEmpty ||
        reader.text(_statusAliases).isNotEmpty;
    final Map<String, dynamic> updateProduct = <String, dynamic>{
      'productId': productId,
      'itemName': displayName,
      'productName': displayName,
      'productFlavor': productName,
      'flavor': productName,
      if (hasHierarchyDepartment) ...<String, dynamic>{
        'departmentId': departmentId,
        'departmentName': departmentName,
      },
      if (hasHierarchyCategory) ...<String, dynamic>{
        'categoryId': categoryId,
        'mainCategoryName': categoryName,
        'categoryName': categoryName,
      },
      if (subCategoryName.isNotEmpty) 'subCategoryName': subCategoryName,
      if (itemCode.isNotEmpty) ...<String, dynamic>{
        'itemCode': itemCode,
        'productCode': itemCode,
        'sku': itemCode,
      },
      if (brandName.isNotEmpty) 'brandName': brandName,
      if (barcode.isNotEmpty) ...<String, dynamic>{
        'barcode': barcode,
        'itemBarcode': barcode,
      },
      if (packingSize.isNotEmpty) 'packingSize': packingSize,
      if (parsedPrice != null) ...cataloguePriceFields(parsedPrice),
      if (reader.text(_uomAliases).isNotEmpty) ...<String, dynamic>{
        'uom': uom,
        'uomLabel': uom,
        'unitOfMeasure': uom,
      },
      if (reader.text(_sortOrderAliases).isNotEmpty) 'sortOrder': sortOrder,
      if (maxOrderQty != null) 'maxOrderQty': maxOrderQty,
      if (hasVisibility) ...<String, dynamic>{
        'isVisible': isVisible,
        'status': isVisible ? 'active' : 'hidden',
      },
    };

    rows.add(
      CatalogueImportRow(
        sourceRow: index + 2,
        errors: errors,
        warnings: warnings,
        updateProduct: updateProduct,
        product: <String, dynamic>{
          'productId': productId,
          'departmentId': departmentId,
          'departmentName': departmentName,
          'categoryId': categoryId,
          'mainCategoryName': categoryName,
          'categoryName': categoryName,
          if (subCategoryName.isNotEmpty) 'subCategoryName': subCategoryName,
          'itemName': displayName,
          'productName': displayName,
          'productFlavor': productName,
          'flavor': productName,
          'itemCode': itemCode,
          'productCode': itemCode,
          'sku': itemCode,
          if (brandName.isNotEmpty) 'brandName': brandName,
          'barcode': barcode,
          'itemBarcode': barcode,
          'packingSize': packingSize,
          ...cataloguePriceFields(parsedPrice ?? 0.0),
          'uom': uom,
          'uomLabel': uom,
          'unitOfMeasure': uom,
          'sortOrder': sortOrder,
          if (maxOrderQty != null) 'maxOrderQty': maxOrderQty,
          'isVisible': isVisible,
          'status': isVisible ? 'active' : 'hidden',
          'mobileDisplayMode': 'textOnly',
        },
        legacyProductId: suppliedId.isEmpty && brandName.isNotEmpty
            ? cleanImportId(
                <String>[
                  departmentName,
                  categoryName,
                  itemCode.isNotEmpty
                      ? itemCode
                      : barcode.isNotEmpty
                      ? barcode
                      : productName,
                ].join('\u0000'),
              )
            : '',
      ),
    );
  }

  if (rows.isEmpty) {
    throw const FormatException(
      'No product rows were found. Check the header row and sheet contents.',
    );
  }

  final Map<String, int> idCounts = <String, int>{};
  for (final CatalogueImportRow row in rows) {
    idCounts.update(row.productId, (int count) => count + 1, ifAbsent: () => 1);
  }
  final Map<String, Set<String>> departmentNamesById = <String, Set<String>>{};
  final Map<String, Set<String>> categoryNamesById = <String, Set<String>>{};
  for (final CatalogueImportRow row in rows) {
    departmentNamesById
        .putIfAbsent('${row.product['departmentId']}', () => <String>{})
        .add('${row.product['departmentName']}');
    categoryNamesById
        .putIfAbsent('${row.product['categoryId']}', () => <String>{})
        .add('${row.product['mainCategoryName']}');
  }
  final Set<String> conflictingDepartmentIds = departmentNamesById.entries
      .where((MapEntry<String, Set<String>> entry) => entry.value.length > 1)
      .map((MapEntry<String, Set<String>> entry) => entry.key)
      .toSet();
  final Set<String> conflictingCategoryIds = categoryNamesById.entries
      .where((MapEntry<String, Set<String>> entry) => entry.value.length > 1)
      .map((MapEntry<String, Set<String>> entry) => entry.key)
      .toSet();

  final List<CatalogueImportRow> checkedRows = rows
      .map((CatalogueImportRow row) {
        final List<String> hierarchyErrors = <String>[
          if (conflictingDepartmentIds.contains(
            '${row.product['departmentId']}',
          ))
            'Conflicting department labels normalize to the same department ID',
          if (conflictingCategoryIds.contains('${row.product['categoryId']}'))
            'Conflicting category labels normalize to the same category ID',
        ];
        if ((idCounts[row.productId] ?? 0) < 2 && hierarchyErrors.isEmpty) {
          return row;
        }
        return CatalogueImportRow(
          product: row.product,
          updateProduct: row.updateProduct,
          sourceRow: row.sourceRow,
          warnings: row.warnings,
          legacyProductId: row.legacyProductId,
          errors: <String>[
            ...row.errors,
            if ((idCounts[row.productId] ?? 0) >= 2)
              'Duplicate product ID in this file',
            ...hierarchyErrors,
          ],
        );
      })
      .toList(growable: false);

  final Map<String, Map<String, dynamic>> departments =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> categories =
      <String, Map<String, dynamic>>{};
  for (final CatalogueImportRow row in checkedRows) {
    final Map<String, dynamic> product = row.product;
    final String departmentId = '${product['departmentId']}';
    final String departmentName = '${product['departmentName']}';
    final String categoryId = '${product['categoryId']}';
    final String categoryName = '${product['mainCategoryName']}';
    departments.putIfAbsent(
      departmentId,
      () => <String, dynamic>{
        'departmentId': departmentId,
        'departmentName': departmentName,
        'name': departmentName,
        'status': 'active',
        'isActive': true,
      },
    );
    categories.putIfAbsent(
      categoryId,
      () => <String, dynamic>{
        'categoryId': categoryId,
        'mainCategoryId': categoryId,
        'departmentId': departmentId,
        'departmentName': departmentName,
        'mainCategoryName': categoryName,
        'categoryName': categoryName,
        'name': categoryName,
        'status': 'active',
        'isActive': true,
      },
    );
  }

  final CatalogueImportPlan plan = CatalogueImportPlan(
    rows: checkedRows,
    departments: departments,
    categories: categories,
  );
  if (plan.plannedWrites > maxAtomicImportWrites) {
    throw FormatException(
      'This import needs ${plan.plannedWrites} linked writes. Split it so each preview needs no more than $maxAtomicImportWrites writes.',
    );
  }
  return plan;
}

String cleanImportId(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return '';

  final String asciiId = trimmed
      .toLowerCase()
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  final bool hasNonAscii = trimmed.runes.any((int rune) => rune > 0x7f);
  if (asciiId.isNotEmpty && !hasNonAscii) return asciiId;
  final String suffix = 'unicode_${_stableAsciiHash(trimmed)}';
  return asciiId.isEmpty ? suffix : '${asciiId}_$suffix';
}

double? parseCataloguePrice(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;

  final String cleaned = trimmed
      .replaceAll(RegExp(r'RM', caseSensitive: false), '')
      .replaceAll(RegExp(r'[$€£¥,\s]'), '');
  final double? parsed = double.tryParse(cleaned);
  if (parsed == null || !isCataloguePriceValid(parsed)) return null;
  return parsed == 0 ? 0.0 : parsed;
}

bool isCataloguePriceValid(double value) {
  return value.isFinite && value >= 0 && value <= maxCatalogueUnitPrice;
}

String _stableAsciiHash(String value) {
  int first = 0x811c9dc5;
  int second = 0x9e3779b9;
  for (final int byte in utf8.encode(value)) {
    first = _stableHashStep(first, byte);
    second = _stableHashStep(second, byte ^ 0x5a);
  }
  return '${first.toRadixString(16).padLeft(8, '0')}${second.toRadixString(16).padLeft(8, '0')}';
}

int _stableHashStep(int hash, int byte) {
  const int fnvPrime = 0x01000193;
  final int mixed = hash ^ byte;
  final int lowProduct = (mixed & 0xffff) * fnvPrime;
  final int highProduct = (((mixed >> 16) & 0xffff) * fnvPrime) & 0xffff;
  return (lowProduct + (highProduct << 16)) & 0xffffffff;
}

List<Map<String, dynamic>> _parseDelimited(
  Uint8List bytes, {
  required String preferredDelimiter,
  required bool catalogueOnly,
}) {
  String text = utf8.decode(bytes, allowMalformed: false);
  if (text.startsWith('\ufeff')) text = text.substring(1);
  final String delimiter = _detectDelimiter(text, preferredDelimiter);
  final List<List<String>> rows = _delimitedRows(text, delimiter);
  return _rowsToMaps(rows, sourceName: 'file', catalogueOnly: catalogueOnly);
}

List<Map<String, dynamic>> _parseXlsx(
  Uint8List bytes, {
  required bool catalogueOnly,
}) {
  _validateWorkbookArchive(bytes);
  final Excel workbook;
  try {
    workbook = Excel.decodeBytes(bytes);
  } catch (_) {
    throw const FormatException(
      'The .xlsx file could not be read. Save a fresh .xlsx copy and try again.',
    );
  }

  final List<Map<String, dynamic>> records = <Map<String, dynamic>>[];
  for (final MapEntry<String, Sheet> entry in workbook.tables.entries) {
    final List<List<Data?>> rows = entry.value.rows;
    if (rows.isEmpty) continue;
    final List<List<String>> values = <List<String>>[];
    bool containsFormula = false;
    for (final List<Data?> row in rows) {
      final List<String> converted = <String>[];
      for (final Data? cell in row) {
        final CellValue? value = cell?.value;
        if (value is FormulaCellValue) {
          containsFormula = true;
          converted.add('');
          continue;
        }
        converted.add(value?.toString().trim() ?? '');
      }
      values.add(converted);
    }
    if (catalogueOnly && values.indexWhere(_isCatalogueHeader) < 0) {
      continue;
    }
    if (containsFormula) {
      throw FormatException(
        'Sheet "${entry.key}" contains formulas. Replace formulas with values before importing.',
      );
    }
    records.addAll(
      _rowsToMaps(values, sourceName: entry.key, catalogueOnly: catalogueOnly),
    );
  }
  return records;
}

void _validateWorkbookArchive(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const FormatException(
      'The .xlsx file is not a valid workbook archive.',
    );
  }
  if (archive.length > maxWorkbookEntries) {
    throw const FormatException(
      'The workbook contains too many internal files to import safely.',
    );
  }
  int expandedBytes = 0;
  for (final ArchiveFile file in archive) {
    final String path = file.name.replaceAll('\\', '/');
    if (path.startsWith('/') || path.split('/').contains('..')) {
      throw const FormatException(
        'The workbook contains an unsafe internal path.',
      );
    }
    if (!file.isFile) continue;
    final _CappedOutput unpacked = _CappedOutput(
      maxExpandedWorkbookBytes - expandedBytes,
    );
    file.decompress(unpacked);
    expandedBytes += unpacked.length;
    file.clear();
  }
}

const FormatException _workbookTooLarge = FormatException(
  'The workbook expands beyond the 50 MB safety limit. Split it before importing.',
);

class _CappedOutput extends OutputMemoryStream {
  _CappedOutput(this.limit);

  final int limit;

  void _reserve(int count) {
    if (length + count > limit) throw _workbookTooLarge;
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    super.writeBackReference(distance, count);
  }
}

List<Map<String, dynamic>> _rowsToMaps(
  List<List<String>> rows, {
  required String sourceName,
  bool catalogueOnly = false,
}) {
  final int headerIndex = catalogueOnly
      ? rows.indexWhere(_isCatalogueHeader)
      : rows.indexWhere(
          (List<String> row) =>
              row.any((String value) => value.trim().isNotEmpty),
        );
  if (headerIndex < 0) return <Map<String, dynamic>>[];
  final List<String> headers = rows[headerIndex]
      .map((String value) => value.trim())
      .toList(growable: false);
  final Set<String> seenHeaders = <String>{};
  for (final String header in headers.where(
    (String value) => value.isNotEmpty,
  )) {
    final String normalized = _normaliseHeader(header);
    if (!seenHeaders.add(normalized)) {
      throw FormatException(
        'The $sourceName sheet has duplicate header "$header". Rename one column.',
      );
    }
  }
  return rows
      .skip(headerIndex + 1)
      .where(
        (List<String> row) =>
            row.any((String value) => value.trim().isNotEmpty),
      )
      .map(
        (List<String> values) => <String, dynamic>{
          for (int index = 0; index < headers.length; index++)
            if (headers[index].isNotEmpty)
              headers[index]: index < values.length ? values[index].trim() : '',
          '_sourceSheet': sourceName,
        },
      )
      .toList(growable: false);
}

bool _isCatalogueHeader(List<String> row) {
  final Set<String> headers = row
      .map(_normaliseHeader)
      .where((String header) => header.isNotEmpty)
      .toSet();
  return headers.any(_productNameAliases.contains) ||
      headers.any(_productIdAliases.contains);
}

List<List<String>> _delimitedRows(String text, String delimiter) {
  final List<List<String>> rows = <List<String>>[];
  List<String> row = <String>[];
  final StringBuffer cell = StringBuffer();
  bool quoted = false;
  for (int index = 0; index < text.length; index++) {
    final String char = text[index];
    if (char == '"') {
      if (quoted && index + 1 < text.length && text[index + 1] == '"') {
        cell.write('"');
        index++;
      } else {
        quoted = !quoted;
      }
    } else if (char == delimiter && !quoted) {
      row.add(cell.toString().trim());
      cell.clear();
    } else if ((char == '\n' || char == '\r') && !quoted) {
      if (char == '\r' && index + 1 < text.length && text[index + 1] == '\n') {
        index++;
      }
      row.add(cell.toString().trim());
      cell.clear();
      rows.add(row);
      row = <String>[];
    } else {
      cell.write(char);
    }
  }
  if (quoted) {
    throw const FormatException('The file contains an unclosed quoted cell.');
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString().trim());
    rows.add(row);
  }
  return rows;
}

String _detectDelimiter(String text, String preferred) {
  final String firstLine = text
      .split(RegExp(r'\r?\n'))
      .firstWhere((String line) => line.trim().isNotEmpty, orElse: () => '');
  final Map<String, int> counts = <String, int>{
    ',': _countOutsideQuotes(firstLine, ','),
    '\t': _countOutsideQuotes(firstLine, '\t'),
    ';': _countOutsideQuotes(firstLine, ';'),
  };
  String best = preferred;
  for (final MapEntry<String, int> entry in counts.entries) {
    if (entry.value > (counts[best] ?? 0)) best = entry.key;
  }
  return best;
}

int _countOutsideQuotes(String text, String delimiter) {
  bool quoted = false;
  int count = 0;
  for (int index = 0; index < text.length; index++) {
    if (text[index] == '"') quoted = !quoted;
    if (!quoted && text[index] == delimiter) count++;
  }
  return count;
}

String _extension(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
}

String _normaliseHeader(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

int? parseCatalogueSortOrder(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final int? parsed = int.tryParse(trimmed);
  if (parsed == null || parsed < 0 || parsed > maxCatalogueSortOrder) {
    return null;
  }
  return parsed;
}

const String catalogueMaxOrderQtyError =
    'Max order qty must be a whole number from 1 to $absoluteMaxQtyPerLine';

int? parseCatalogueMaxOrderQty(String value) {
  final int? parsed = int.tryParse(value.trim());
  if (parsed == null || parsed < 1 || parsed > absoluteMaxQtyPerLine) {
    return null;
  }
  return parsed;
}

void _addTextLengthError(
  List<String> errors, {
  required String label,
  required String value,
  required int maxLength,
}) {
  final String? error = catalogueTextLengthError(
    label: label,
    value: value,
    maxLength: maxLength,
  );
  if (error != null) errors.add(error);
}

String? catalogueTextLengthError({
  required String label,
  required String value,
  required int maxLength,
}) {
  if (value.length <= maxLength) return null;
  return '$label must be at most $maxLength characters';
}

String? validateManualCatalogueProductFields({
  required String departmentName,
  required String departmentManagerName,
  required String mainCategoryName,
  required String itemName,
  required String itemCode,
  required String barcode,
  required String packingSize,
  required String uom,
  required String displayProductName,
  required String departmentId,
  required String categoryId,
  required String productId,
}) {
  final List<({String label, String value, int maxLength})> fields =
      <({String label, String value, int maxLength})>[
        (
          label: 'Department name',
          value: departmentName,
          maxLength: maxCatalogueGroupNameLength,
        ),
        (
          label: 'Department manager name',
          value: departmentManagerName,
          maxLength: maxCatalogueSupportingTextLength,
        ),
        (
          label: 'Category name',
          value: mainCategoryName,
          maxLength: maxCatalogueGroupNameLength,
        ),
        (
          label: 'Product/item name',
          value: itemName,
          maxLength: maxCatalogueProductTextLength,
        ),
        (
          label: 'Item code',
          value: itemCode,
          maxLength: maxCatalogueSupportingTextLength,
        ),
        (
          label: 'Barcode',
          value: barcode,
          maxLength: maxCatalogueSupportingTextLength,
        ),
        (
          label: 'Packing size',
          value: packingSize,
          maxLength: maxCatalogueSupportingTextLength,
        ),
        (
          label: 'Product display name',
          value: displayProductName,
          maxLength: maxCatalogueProductTextLength,
        ),
        (
          label: 'Unit of measure',
          value: uom,
          maxLength: maxCatalogueUomLength,
        ),
        (
          label: 'Department ID',
          value: departmentId,
          maxLength: maxCatalogueProductIdLength,
        ),
        (
          label: 'Category ID',
          value: categoryId,
          maxLength: maxCatalogueHierarchyIdLength,
        ),
        (
          label: 'Product ID',
          value: productId,
          maxLength: maxCatalogueProductIdLength,
        ),
      ];
  for (final ({String label, String value, int maxLength}) field in fields) {
    final String? error = catalogueTextLengthError(
      label: field.label,
      value: field.value,
      maxLength: field.maxLength,
    );
    if (error != null) return error;
  }
  return null;
}

bool _readVisible(_RowReader reader) {
  return isCatalogueProductVisible(<String, dynamic>{
    if (reader.text(_statusAliases).isNotEmpty)
      'status': reader.text(_statusAliases),
    if (reader.text(_visibleAliases).isNotEmpty)
      'isVisible': reader.text(_visibleAliases),
  });
}

class _RowReader {
  _RowReader(Map<String, dynamic> source)
    : values = <String, dynamic>{
        for (final MapEntry<String, dynamic> entry in source.entries)
          _normaliseHeader(entry.key): entry.value,
      };

  final Map<String, dynamic> values;

  String text(List<String> aliases) {
    for (final String alias in aliases) {
      final String value = '${values[alias] ?? ''}'.trim();
      if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
    }
    return '';
  }
}

const List<String> _departmentAliases = <String>[
  'departmentname',
  'department',
  'dept',
  'division',
];
const List<String> _categoryAliases = <String>[
  'maincategoryname',
  'maincategory',
  'categoryname',
  'category',
  'productgroup',
  'group',
];
const List<String> _subCategoryAliases = <String>[
  'subcategoryname',
  'subcategory',
  'subgroup',
];
const List<String> _productNameAliases = <String>[
  'productname',
  'itemname',
  'product',
  'item',
  'description',
  'flavour',
  'flavor',
  'name',
];
const List<String> _productIdAliases = <String>['productid', 'itemid', 'id'];
const List<String> _itemCodeAliases = <String>[
  'itemcode',
  'productcode',
  'sku',
  'code',
];
const List<String> _brandAliases = <String>['brandname', 'brand'];
const List<String> _barcodeAliases = <String>[
  'barcode',
  'itembarcode',
  'ean',
  'upc',
];
const List<String> _packingAliases = <String>[
  'packingsize',
  'packsize',
  'packing',
  'packaging',
  'pack',
];
const List<String> _priceAliases = <String>[
  'unitprice',
  'sellingprice',
  'priceguide',
  'price',
];
const List<String> _uomAliases = <String>[
  'uom',
  'uomlabel',
  'unitofmeasure',
  'unit',
];
const List<String> _sortOrderAliases = <String>[
  'sortorder',
  'position',
  'sequence',
  'order',
];
const List<String> _maxOrderQtyAliases = <String>[
  'maxorderqty',
  'maxorderquantity',
  'maxqty',
  'maxquantity',
];
const List<String> _visibleAliases = <String>[
  'isvisible',
  'visible',
  'display',
];
const List<String> _statusAliases = <String>['status'];
