import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/catalogue_product_repository.dart';
import '../../../services/audit_log_service.dart';
import '../../../services/forecasting_api_service.dart';
import '../../../services/platform_api_client.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/catalogue_import.dart';
import '../../../utils/catalogue_product_availability.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/retailer_import_mapping.dart';
import '../../../utils/safe_doc_id.dart';
import '../../../utils/user_facing_error.dart';
import '../widgets/cms_panel.dart';

class ImportPreviewPage extends StatefulWidget {
  const ImportPreviewPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<ImportPreviewPage> createState() => _ImportPreviewPageState();
}

class _ImportPreviewPageState extends State<ImportPreviewPage> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final ForecastingApiService _forecastService = ForecastingApiService();

  String _target = 'products';
  PickedFile? _file;
  List<_ImportRow> _preview = <_ImportRow>[];
  CatalogueImportPlan? _cataloguePlan;
  bool _loading = false;
  bool _allowUpdates = false;
  String _message = '';

  Future<void> _pickAndPreview() async {
    final PickedFile? file = await ForecastingApiService.pickSpreadsheet();
    if (file == null) return;
    setState(() {
      _loading = true;
      _file = file;
      _preview = <_ImportRow>[];
      _cataloguePlan = null;
      _message = '';
      _allowUpdates = false;
    });
    try {
      final String extension = file.name.split('.').last.toLowerCase();
      if (_target == 'forecasts' && extension != 'csv' && extension != 'tsv') {
        if (<String>['xlsx', 'xls', 'xlsm'].contains(extension)) {
          if (!mounted) return;
          setState(() {
            _preview = <_ImportRow>[
              _ImportRow(
                source: const <String, dynamic>{},
                id: file.name,
                exists: false,
                errors: const <String>[],
                warnings: const <String>[],
                summary:
                    'Excel forecast file will be checked when you confirm the import.',
              ),
            ];
            _loading = false;
          });
          return;
        }
        throw const FormatException('Choose a supported forecast spreadsheet.');
      }

      final List<Map<String, dynamic>> records = parseImportFile(
        file.bytes,
        file.name,
        catalogueOnly: _target == 'products',
      );
      if (records.isEmpty) {
        throw const FormatException('The spreadsheet has no data rows.');
      }
      if (_target != 'products' && records.length > 400) {
        throw const FormatException(
          'Preview is limited to 400 rows so the import is saved all at once. '
          'Split the file into smaller files.',
        );
      }
      if (_target == 'forecasts') {
        final List<_ImportRow> preview = records
            .map(
              (Map<String, dynamic> row) => _ImportRow(
                source: row,
                id: _first(row, <String>[
                  'productId',
                  'product_id',
                  'sku',
                  'productName',
                  'product_name',
                ]),
                exists: false,
                errors: row.isEmpty
                    ? const <String>['Empty row']
                    : const <String>[],
                warnings: const <String>[],
                summary: _rowSummary(row),
              ),
            )
            .toList(growable: false);
        if (!mounted) return;
        setState(() {
          _preview = preview;
          _loading = false;
        });
        return;
      }

      if (_target == 'products') {
        final CatalogueImportPlan plan = buildCatalogueImportPlan(records);
        final List<DocumentSnapshot<Map<String, dynamic>>?> targetDocuments =
            await Future.wait(
              plan.rows.map((CatalogueImportRow row) async {
                if (row.productId.isEmpty) return null;
                return _db
                    .collection('products')
                    .doc(row.productId)
                    .get(const GetOptions(source: Source.server));
              }),
            );
        final List<DocumentSnapshot<Map<String, dynamic>>?> legacyDocuments =
            await Future.wait(
              plan.rows.map((CatalogueImportRow row) async {
                if (row.legacyProductId.isEmpty) return null;
                return _db
                    .collection('products')
                    .doc(row.legacyProductId)
                    .get(const GetOptions(source: Source.server));
              }),
            );

        final Map<String, int> legacyCandidateCounts = <String, int>{};
        for (int index = 0; index < plan.rows.length; index++) {
          final CatalogueImportRow row = plan.rows[index];
          final DocumentSnapshot<Map<String, dynamic>>? legacyDocument =
              legacyDocuments[index];
          final Map<String, dynamic> legacyData = <String, dynamic>{
            ...?legacyDocument?.data(),
            if (legacyDocument != null) 'docId': legacyDocument.id,
          };
          if (legacyDocument?.exists != true ||
              isDemoProductRecord(legacyData) ||
              !_legacyBrandMatches(legacyData, row.product)) {
            continue;
          }
          legacyCandidateCounts.update(
            row.legacyProductId,
            (int count) => count + 1,
            ifAbsent: () => 1,
          );
        }

        final List<CatalogueImportRow> resolvedRows = <CatalogueImportRow>[];
        final List<_ImportRow> preview = <_ImportRow>[];
        for (int index = 0; index < plan.rows.length; index++) {
          final CatalogueImportRow planned = plan.rows[index];
          final DocumentSnapshot<Map<String, dynamic>>? targetDocument =
              targetDocuments[index];
          final DocumentSnapshot<Map<String, dynamic>>? legacyDocument =
              legacyDocuments[index];
          final Map<String, dynamic> legacyData = <String, dynamic>{
            ...?legacyDocument?.data(),
            if (legacyDocument != null) 'docId': legacyDocument.id,
          };
          final bool canMigrateLegacy =
              legacyDocument?.exists == true &&
              !isDemoProductRecord(legacyData) &&
              _legacyBrandMatches(legacyData, planned.product);
          String targetId = planned.productId;
          List<String> errors = planned.errors;
          List<String> warnings = planned.warnings;
          if (canMigrateLegacy &&
              (legacyCandidateCounts[planned.legacyProductId] ?? 0) > 1) {
            errors = <String>[
              ...errors,
              'More than one row matches the same legacy product. Add a product ID, item code, or barcode to keep each product distinct.',
            ];
          } else if (canMigrateLegacy && targetDocument?.exists == true) {
            errors = <String>[
              ...errors,
              'Both the new brand-based product and its legacy product already exist. Resolve the duplicate before importing.',
            ];
          } else if (canMigrateLegacy) {
            targetId = legacyDocument!.id;
            warnings = <String>[
              ...warnings,
              'This row updates the existing legacy product ID to preserve score-sheet and saved-order links.',
            ];
          }

          final Map<String, dynamic> product = <String, dynamic>{
            ...planned.product,
            'productId': targetId,
          };
          final Map<String, dynamic> updateProduct = <String, dynamic>{
            ...planned.updateProduct,
            'productId': targetId,
          };
          final CatalogueImportRow resolved = CatalogueImportRow(
            product: product,
            updateProduct: updateProduct,
            errors: errors,
            warnings: warnings,
            sourceRow: planned.sourceRow,
            legacyProductId: planned.legacyProductId,
            requestedProductId: planned.productId,
          );
          resolvedRows.add(resolved);
          preview.add(
            _ImportRow(
              source: product,
              id: targetId,
              exists: targetId == planned.productId
                  ? targetDocument?.exists == true
                  : true,
              errors: errors,
              warnings: warnings,
              summary: <String>[
                '${product['departmentName']}',
                '${product['mainCategoryName']}',
                '${product['productName']}',
              ].join(' › '),
            ),
          );
        }

        final Map<String, int> resolvedTargetCounts = <String, int>{};
        for (final CatalogueImportRow row in resolvedRows) {
          resolvedTargetCounts.update(
            row.productId,
            (int count) => count + 1,
            ifAbsent: () => 1,
          );
        }
        for (int index = 0; index < resolvedRows.length; index++) {
          final CatalogueImportRow row = resolvedRows[index];
          if ((resolvedTargetCounts[row.productId] ?? 0) < 2) continue;
          final List<String> errors = <String>[
            ...row.errors,
            'Multiple import rows resolve to product ID "${row.productId}". Give each product a unique brand, pack, product code, or barcode before importing.',
          ];
          resolvedRows[index] = CatalogueImportRow(
            product: row.product,
            updateProduct: row.updateProduct,
            errors: errors,
            warnings: row.warnings,
            sourceRow: row.sourceRow,
            legacyProductId: row.legacyProductId,
            requestedProductId: row.requestedProductId,
          );
          final _ImportRow oldPreview = preview[index];
          preview[index] = _ImportRow(
            source: oldPreview.source,
            id: oldPreview.id,
            exists: oldPreview.exists,
            errors: errors,
            warnings: oldPreview.warnings,
            summary: oldPreview.summary,
          );
        }

        final QuerySnapshot<Map<String, dynamic>> catalogueSnapshot = await _db
            .collection('products')
            .get(const GetOptions(source: Source.server));
        final List<CatalogueImportRow> barcodeCheckedRows =
            withCatalogueBarcodeWarnings(
              resolvedRows,
              existingProducts: <String, Map<String, dynamic>>{
                for (final document in catalogueSnapshot.docs)
                  document.id: document.data(),
              },
            );
        for (int index = 0; index < barcodeCheckedRows.length; index++) {
          final _ImportRow row = preview[index];
          preview[index] = _ImportRow(
            source: row.source,
            id: row.id,
            exists: row.exists,
            errors: row.errors,
            warnings: barcodeCheckedRows[index].warnings,
            summary: row.summary,
          );
        }

        final CatalogueImportPlan resolvedPlan = CatalogueImportPlan(
          rows: barcodeCheckedRows,
          departments: plan.departments,
          categories: plan.categories,
        );
        if (!mounted) return;
        setState(() {
          _cataloguePlan = resolvedPlan;
          _preview = preview;
          _loading = false;
        });
        return;
      }

      final RetailerImportKind kind = _target == 'assignments'
          ? RetailerImportKind.assignments
          : RetailerImportKind.retailers;
      final Set<String> branchIds = await _loadBranchIds();
      final List<_ImportRow> preview = await Future.wait(
        records.map(
          (Map<String, dynamic> raw) =>
              _previewRetailerRow(raw, kind, branchIds),
        ),
      );
      _flagDuplicateIds(preview);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = error is FormatException
            ? error.message
            : userFacingError(error, action: 'read the file');
      });
    }
  }

  Future<Set<String>> _loadBranchIds() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _db
          .collection('branches')
          .get();
      return snapshot.docs
          .map((QueryDocumentSnapshot<Map<String, dynamic>> doc) => doc.id)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<_ImportRow> _previewRetailerRow(
    Map<String, dynamic> raw,
    RetailerImportKind kind,
    Set<String> branchIds,
  ) async {
    final RetailerImportRow mapped = mapRetailerImportRow(raw, kind: kind);
    final List<String> errors = <String>[...mapped.errors];
    final List<String> warnings = <String>[...mapped.warnings];
    String id = mapped.id;
    final String name = '${mapped.fields['retailerName'] ?? ''}';
    if (id.isEmpty && kind == RetailerImportKind.retailers && name.isNotEmpty) {
      id = safeDocId(name, fallbackPrefix: 'retailer');
    }
    bool exists = false;
    bool skip = false;
    if (id.isNotEmpty && mapped.errors.isEmpty) {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await _db
          .collection('retailers')
          .doc(id)
          .get();
      exists = snapshot.exists;
      final Map<String, dynamic> data = snapshot.data() ?? <String, dynamic>{};
      if (exists &&
          ('${data['status'] ?? ''}'.toLowerCase() == 'retired' ||
              data['retiredAt'] != null)) {
        skip = true;
        warnings.add('This retailer is retired, so the row will be skipped.');
      }
      if (kind == RetailerImportKind.assignments && !exists) {
        errors.add(
          'No retailer with ID "$id" exists. Assignment rows never create '
          'retailers.',
        );
      }
    }
    final String branch = '${mapped.fields['branchId'] ?? ''}';
    if (branch.isNotEmpty &&
        branchIds.isNotEmpty &&
        !branchIds.contains(branch)) {
      errors.add(
        'Branch "$branch" does not exist. Create it under Branches first.',
      );
    }
    if (kind == RetailerImportKind.retailers &&
        !exists &&
        branch.isEmpty &&
        errors.isEmpty) {
      warnings.add(
        'No branch set, so branch-scoped users will not see this retailer.',
      );
    }
    final Map<String, dynamic> fields = <String, dynamic>{
      ...mapped.fields,
      if (kind == RetailerImportKind.retailers && id.isNotEmpty)
        'retailerId': id,
    };
    return _ImportRow(
      source: fields,
      id: id,
      exists: exists,
      errors: skip ? const <String>[] : errors,
      warnings: warnings,
      summary: _rowSummary(fields),
      skip: skip,
    );
  }

  void _flagDuplicateIds(List<_ImportRow> rows) {
    final Set<String> seen = <String>{};
    for (int i = 0; i < rows.length; i++) {
      final _ImportRow row = rows[i];
      if (row.id.isEmpty || row.skip) continue;
      if (seen.add(row.id)) continue;
      rows[i] = _ImportRow(
        source: row.source,
        id: row.id,
        exists: row.exists,
        errors: <String>[
          ...row.errors,
          'Retailer ID "${row.id}" appears more than once in this file.',
        ],
        warnings: row.warnings,
        summary: row.summary,
        skip: row.skip,
      );
    }
  }

  String _productBrand(Map<String, dynamic> product) {
    for (final String key in <String>['brandName', 'brand']) {
      final String value = (product[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _productText(Map<String, dynamic> product, List<String> keys) {
    for (final String key in keys) {
      final String value = (product[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _normalizeIdentityText(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  bool _legacyBrandMatches(
    Map<String, dynamic> legacy,
    Map<String, dynamic> incoming,
  ) {
    final String existingBrand = _productBrand(legacy);
    final String incomingBrand = _productBrand(incoming);
    if (existingBrand.isEmpty ||
        incomingBrand.isEmpty ||
        _normalizeIdentityText(existingBrand) !=
            _normalizeIdentityText(incomingBrand)) {
      return false;
    }

    final String legacyName = _productText(legacy, <String>[
      'productFlavor',
      'flavor',
      'itemName',
      'productName',
    ]);
    final String incomingName = _productText(incoming, <String>[
      'productFlavor',
      'flavor',
      'itemName',
      'productName',
    ]);
    if (legacyName.isEmpty ||
        incomingName.isEmpty ||
        _normalizeIdentityText(legacyName) !=
            _normalizeIdentityText(incomingName)) {
      return false;
    }

    const List<List<String>> optionalIdentityFields = <List<String>>[
      <String>['packingSize', 'packagingSize'],
      <String>['itemCode', 'productCode', 'sku'],
      <String>['itemBarcode', 'barcode', 'productBarcode'],
    ];
    for (final List<String> aliases in optionalIdentityFields) {
      final String legacyValue = _productText(legacy, aliases);
      final String incomingValue = _productText(incoming, aliases);
      if ((legacyValue.isEmpty != incomingValue.isEmpty) ||
          _normalizeIdentityText(legacyValue) !=
              _normalizeIdentityText(incomingValue)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _confirmImport() async {
    final PickedFile? file = _file;
    if (file == null || _preview.isEmpty) return;
    final List<_ImportRow> invalid = _preview
        .where((_ImportRow row) => row.errors.isNotEmpty)
        .toList(growable: false);
    if (invalid.isNotEmpty) {
      setState(() => _message = 'Fix invalid rows before confirming.');
      return;
    }
    final bool hasUpdates = _preview.any(
      (_ImportRow row) => row.exists && !row.skip,
    );
    if (hasUpdates && !_allowUpdates) {
      setState(() {
        _message =
            'Existing records are present. Enable explicit updates or remove '
            'those rows; nothing was written.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _message = '';
    });
    String? hiddenNote;
    try {
      if (_target == 'forecasts') {
        final Map<String, dynamic> result = await _forecastService.importExcel(
          file,
        );
        final bool success =
            result['success'] == true ||
            '${result['status'] ?? ''}'.toLowerCase() == 'ok';
        if (!success && result.isEmpty) {
          throw StateError(
            'The forecast import returned no result. Try again.',
          );
        }
      } else if (_target == 'products') {
        hiddenNote = await _confirmCatalogueImport(file);
      } else {
        final List<_ImportRow> rows = _preview
            .where((_ImportRow row) => !row.skip)
            .toList(growable: false);
        if (rows.isEmpty) {
          throw StateError(
            'Every row was skipped, so there is nothing to import.',
          );
        }
        if (rows.length > 400) {
          throw StateError(
            'This import needs ${rows.length} retailer writes. Split it into files of no more than 400 rows.',
          );
        }
        await _db.runTransaction((Transaction transaction) async {
          final List<DocumentReference<Map<String, dynamic>>> references = rows
              .map((_ImportRow row) => _db.collection('retailers').doc(row.id))
              .toList(growable: false);
          final List<DocumentSnapshot<Map<String, dynamic>>> snapshots =
              <DocumentSnapshot<Map<String, dynamic>>>[];
          for (final DocumentReference<Map<String, dynamic>> reference
              in references) {
            snapshots.add(await transaction.get(reference));
          }
          if (!_allowUpdates &&
              snapshots.any(
                (DocumentSnapshot<Map<String, dynamic>> snapshot) =>
                    snapshot.exists,
              )) {
            throw StateError(
              'An existing record appeared after preview. Refresh the preview '
              'or explicitly allow updates.',
            );
          }
          for (int i = 0; i < rows.length; i++) {
            transaction.set(references[i], <String, dynamic>{
              if (_target == 'retailers' &&
                  !snapshots[i].exists) ...<String, dynamic>{
                'status': 'active',
                'stockListVisible': true,
              },
              ...rows[i].source,
              'importSource': file.name,
              'updatedAt': FieldValue.serverTimestamp(),
              if (!snapshots[i].exists)
                'createdAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
        });
      }

      await AuditLogService.instance.record(
        action: 'imported',
        entityType: _target,
        entityId: file.name,
        summary:
            'Imported ${_preview.where((_ImportRow row) => !row.skip).length} '
            '$_target row(s) from ${file.name}',
        actor: widget.currentUser,
        metadata: <String, dynamic>{
          'rows': _preview.where((_ImportRow row) => !row.skip).length,
          'skipped': _preview.where((_ImportRow row) => row.skip).length,
          'updatesAllowed': _allowUpdates,
          'fileName': file.name,
        },
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        final int skipped = _preview.where((_ImportRow row) => row.skip).length;
        _message =
            'Import completed: ${_preview.length - skipped} row(s)'
            '${skipped == 0 ? '' : ', $skipped retired row(s) skipped'}.'
            '${hiddenNote == null ? '' : ' $hiddenNote'}';
        _file = null;
        _preview = <_ImportRow>[];
        _cataloguePlan = null;
        _allowUpdates = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = userFacingError(error, action: 'import the file');
      });
    }
  }

  Future<String?> _confirmCatalogueImport(PickedFile file) async {
    final CatalogueImportPlan? plan = _cataloguePlan;
    if (plan == null) {
      throw StateError('Build a fresh catalogue preview first.');
    }
    if (plan.plannedWrites > maxAtomicImportWrites) {
      throw StateError(
        'This catalogue import needs up to ${plan.plannedWrites} linked writes. Split it so each preview needs no more than $maxAtomicImportWrites writes.',
      );
    }
    final List<String> targetIds = plan.rows
        .map((CatalogueImportRow row) => row.productId)
        .toList(growable: false);
    if (targetIds.toSet().length != targetIds.length) {
      throw StateError(
        'More than one import row targets the same product ID. Refresh the preview and resolve duplicate products before importing.',
      );
    }

    final Map<String, bool> availability = await _checkProductRoom(plan);

    await _db.runTransaction((Transaction transaction) async {
      final List<DocumentReference<Map<String, dynamic>>> productReferences =
          plan.rows
              .map(
                (CatalogueImportRow row) =>
                    _db.collection('products').doc(row.productId),
              )
              .toList(growable: false);
      final List<DocumentSnapshot<Map<String, dynamic>>> productSnapshots =
          <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final DocumentReference<Map<String, dynamic>> reference
          in productReferences) {
        productSnapshots.add(await transaction.get(reference));
      }

      final List<DocumentSnapshot<Map<String, dynamic>>?>
      requestedProductSnapshots = <DocumentSnapshot<Map<String, dynamic>>?>[];
      for (final CatalogueImportRow row in plan.rows) {
        final String requestedId = row.requestedProductId.trim();
        if (requestedId.isEmpty || requestedId == row.productId) {
          requestedProductSnapshots.add(null);
          continue;
        }
        requestedProductSnapshots.add(
          await transaction.get(_db.collection('products').doc(requestedId)),
        );
      }

      for (int index = 0; index < plan.rows.length; index++) {
        if (requestedProductSnapshots[index]?.exists == true) {
          throw StateError(
            'A product appeared at its brand-based ID after preview. Refresh the import preview and resolve the duplicate before importing.',
          );
        }
        final DocumentSnapshot<Map<String, dynamic>> snapshot =
            productSnapshots[index];
        if (!snapshot.exists) continue;
        final String existingBrand = _productBrand(
          snapshot.data() ?? <String, dynamic>{},
        );
        final String incomingBrand = _productBrand(plan.rows[index].product);
        if (existingBrand.isNotEmpty &&
            incomingBrand.isNotEmpty &&
            existingBrand.toLowerCase() != incomingBrand.toLowerCase()) {
          throw StateError(
            'A product brand changed after preview. Refresh the import preview before importing.',
          );
        }
      }

      final Set<String> departmentIdsToEnsure = <String>{};
      final Set<String> categoryIdsToEnsure = <String>{};
      for (int index = 0; index < plan.rows.length; index++) {
        final CatalogueImportRow row = plan.rows[index];
        final bool isNewProduct = !productSnapshots[index].exists;
        if (isNewProduct || row.updateProduct.containsKey('departmentId')) {
          departmentIdsToEnsure.add('${row.product['departmentId']}');
        }
        if (isNewProduct || row.updateProduct.containsKey('categoryId')) {
          categoryIdsToEnsure.add('${row.product['categoryId']}');
        }
      }

      final Map<String, DocumentSnapshot<Map<String, dynamic>>>
      departmentSnapshots = <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final String id in plan.departments.keys) {
        departmentSnapshots[id] = await transaction.get(
          _db.collection('departments').doc(id),
        );
      }
      final Map<String, DocumentSnapshot<Map<String, dynamic>>>
      categorySnapshots = <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final String id in plan.categories.keys) {
        categorySnapshots[id] = await transaction.get(
          _db.collection('categories').doc(id),
        );
      }
      final DocumentReference<Map<String, dynamic>> scoreSheetReference = _db
          .collection('score_sheets')
          .doc('default');
      final DocumentSnapshot<Map<String, dynamic>> scoreSheetSnapshot =
          await transaction.get(scoreSheetReference);

      if (!_allowUpdates &&
          productSnapshots.any(
            (DocumentSnapshot<Map<String, dynamic>> snapshot) =>
                snapshot.exists,
          )) {
        throw StateError(
          'An existing product appeared after preview. Refresh the preview or explicitly allow updates.',
        );
      }

      for (int index = 0; index < plan.rows.length; index++) {
        final bool exists = productSnapshots[index].exists;
        transaction.set(productReferences[index], <String, dynamic>{
          ...plan.rows[index].writeFields(
            exists: exists,
            existingProduct: productSnapshots[index].data(),
          ),
          'importSource': file.name,
          'updatedAt': FieldValue.serverTimestamp(),
          if (!exists) 'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      for (final MapEntry<String, Map<String, dynamic>> entry
          in plan.departments.entries) {
        if (!departmentIdsToEnsure.contains(entry.key) ||
            departmentSnapshots[entry.key]?.exists == true) {
          continue;
        }
        transaction.set(
          _db.collection('departments').doc(entry.key),
          <String, dynamic>{
            ...entry.value,
            'importSource': file.name,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        );
      }
      for (final MapEntry<String, Map<String, dynamic>> entry
          in plan.categories.entries) {
        if (!categoryIdsToEnsure.contains(entry.key) ||
            categorySnapshots[entry.key]?.exists == true) {
          continue;
        }
        transaction
            .set(_db.collection('categories').doc(entry.key), <String, dynamic>{
              ...entry.value,
              'importSource': file.name,
              'createdAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            });
      }

      final Set<String> productIds = <String>{
        ...((scoreSheetSnapshot.data()?['productIds'] as List<dynamic>?) ??
                <dynamic>[])
            .map((dynamic value) => '$value'),
        ...plan.rows.map((CatalogueImportRow row) => row.productId),
      };
      final Set<String> visibleProductIds = <String>{
        ...((scoreSheetSnapshot.data()?['visibleProductIds']
                    as List<dynamic>?) ??
                <dynamic>[])
            .map((dynamic value) => '$value'),
      };
      for (int index = 0; index < plan.rows.length; index++) {
        final CatalogueImportRow row = plan.rows[index];
        final String productId = row.productId;
        visibleProductIds.remove(productId);

        final Map<String, dynamic> update = row.updateProduct;
        final Map<String, dynamic>? existing = productSnapshots[index].data();
        bool isVisible =
            existing?['isVisible'] != false &&
            '${existing?['status'] ?? ''}'.toLowerCase() != 'hidden';
        if (!productSnapshots[index].exists) {
          isVisible =
              row.product['isVisible'] != false &&
              '${row.product['status'] ?? ''}'.toLowerCase() != 'hidden';
        } else if (update.containsKey('isVisible')) {
          isVisible = update['isVisible'] == true;
        } else if (update.containsKey('status')) {
          isVisible = '${update['status']}'.toLowerCase() != 'hidden';
        }
        if (isVisible) visibleProductIds.add(productId);
      }
      final List<String> sortedProductIds = productIds.toList()..sort();
      final List<String> sortedVisibleProductIds = visibleProductIds.toList()
        ..sort();
      transaction.set(scoreSheetReference, <String, dynamic>{
        'scoreSheetId': 'default',
        'sheetName': 'Default Score Sheet',
        'productIds': sortedProductIds,
        'visibleProductIds': sortedVisibleProductIds,
        'productCount': sortedProductIds.length,
        'visibleProductCount': sortedVisibleProductIds.length,
        'isDefault': true,
        'status': 'active',
        'importSource': file.name,
        'updatedAt': FieldValue.serverTimestamp(),
        if (!scoreSheetSnapshot.exists)
          'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });

    try {
      await CatalogueProductRepository().applyAvailability(availability);
    } on PlatformApiException catch (error) {
      return 'Imported, but some products stay hidden: ${error.message}';
    }
    return null;
  }

  Future<Map<String, bool>> _checkProductRoom(CatalogueImportPlan plan) async {
    final PlanUsage usage = await PlatformApiClient().getUsage();
    final List<DocumentSnapshot<Map<String, dynamic>>> current =
        await Future.wait(
          plan.rows.map(
            (CatalogueImportRow row) =>
                _db.collection('products').doc(row.productId).get(),
          ),
        );
    final Map<String, bool> changes = <String, bool>{};
    int toShow = 0;
    for (int index = 0; index < plan.rows.length; index++) {
      final CatalogueImportRow row = plan.rows[index];
      final bool exists = current[index].exists;
      final bool? wanted = row.requestedVisible(exists: exists);
      if (wanted == null) continue;
      final bool orderable =
          exists && isCatalogueProductVisible(current[index].data()!);
      if (wanted == orderable && exists) continue;
      if (!exists && !wanted) continue;
      changes[row.productId] = wanted;
      if (wanted && !orderable) toShow++;
    }
    if (changes.length > CatalogueProductRepository.maxAvailabilityChanges) {
      throw StateError(
        'This file changes the visibility of ${changes.length} products. '
        'Import at most ${CatalogueProductRepository.maxAvailabilityChanges} '
        'at a time. Nothing was written.',
      );
    }
    final int? room = usage.productRoom;
    if (room != null && toShow > room) {
      final int limit = usage.limits['products'] ?? 0;
      throw StateError(
        'Your plan allows $limit products. This file would show $toShow more '
        'but only ${room < 0 ? 0 : room} more fit. Hide or remove some '
        'products, change the visibility column in the file, or ask to '
        'upgrade. Nothing was written.',
      );
    }
    return changes;
  }

  @override
  Widget build(BuildContext context) {
    final int invalid = _preview
        .where((_ImportRow row) => row.errors.isNotEmpty)
        .length;
    final int updates = _preview.where((_ImportRow row) => row.exists).length;
    final int warnings = _preview
        .where((_ImportRow row) => row.warnings.isNotEmpty)
        .length;
    return CmsPanel(
      title: 'Batch import',
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    DropdownButton<String>(
                      value: _target,
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem(
                          value: 'products',
                          child: Text('Products'),
                        ),
                        DropdownMenuItem(
                          value: 'retailers',
                          child: Text('Retailers'),
                        ),
                        DropdownMenuItem(
                          value: 'assignments',
                          child: Text('Salesman / branch assignments'),
                        ),
                        DropdownMenuItem(
                          value: 'forecasts',
                          child: Text('Forecasts'),
                        ),
                      ],
                      onChanged: _loading
                          ? null
                          : (String? value) {
                              if (value == null) return;
                              setState(() {
                                _target = value;
                                _file = null;
                                _preview = <_ImportRow>[];
                                _cataloguePlan = null;
                                _allowUpdates = false;
                                _message = '';
                              });
                            },
                    ),
                    FilledButton.icon(
                      onPressed: _loading ? null : _pickAndPreview,
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('Upload and preview'),
                    ),
                    if (_file != null) Text(_file!.name),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Product catalogues accept XLSX, CSV, or TSV. Products are '
                  'normalised into the master catalogue, linked to departments '
                  'and categories, and added to the default mobile score '
                  'sheet. Retailer files may use headers such as "Retailer '
                  'Name", "Address", "Salesman Code" or "Branch ID"; unknown '
                  'columns are skipped. Assignment files only update retailers '
                  'that already exist. Existing records are never updated '
                  'unless the explicit update checkbox is enabled.',
                  style: TextStyle(color: context.dso.muted, height: 1.45),
                ),
                if (_preview.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    children: <Widget>[
                      Text('${_preview.length} rows'),
                      Text('$invalid invalid'),
                      Text('$warnings with warnings'),
                      Text('$updates existing'),
                      if (_cataloguePlan != null)
                        Text(
                          '${_cataloguePlan!.departments.length} departments · ${_cataloguePlan!.categories.length} categories',
                        ),
                    ],
                  ),
                  if (_target == 'products' && warnings > 0)
                    const Text(
                      'Review warnings before confirming. Duplicate active '
                      'barcodes can make scans ambiguous. Warnings do not '
                      'block import.',
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _allowUpdates,
                    onChanged: _target == 'forecasts'
                        ? null
                        : (bool? value) {
                            setState(() => _allowUpdates = value == true);
                          },
                    title: const Text(
                      'Allow explicit merge updates to existing records',
                    ),
                    subtitle: const Text(
                      'Off by default. Imports never remove existing information.',
                    ),
                  ),
                ],
                if (_message.isNotEmpty)
                  Text(
                    _message,
                    style: TextStyle(
                      color: _message.startsWith('Import completed')
                          ? context.dso.successText
                          : context.dso.dangerText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _preview.isEmpty
                ? const Center(
                    child: Text('Upload a file to build a validation preview.'),
                  )
                : ListView.separated(
                    itemCount: _preview.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final _ImportRow row = _preview[index];
                      return ListTile(
                        leading: Icon(
                          row.errors.isNotEmpty
                              ? Icons.error_outline
                              : row.warnings.isNotEmpty
                              ? Icons.warning_amber_outlined
                              : row.exists
                              ? Icons.edit_note_outlined
                              : Icons.add_circle_outline,
                          color: row.errors.isNotEmpty
                              ? context.dso.dangerText
                              : row.warnings.isNotEmpty
                              ? const Color(0xFFF79009)
                              : row.exists
                              ? const Color(0xFFF79009)
                              : const Color(0xFF12B76A),
                        ),
                        title: Text(
                          row.id.isEmpty ? 'Row ${index + 1}' : row.id,
                        ),
                        subtitle: Text(
                          row.errors.isEmpty
                              ? <String>[
                                  row.summary,
                                  if (row.warnings.isNotEmpty)
                                    row.warnings.join(' · '),
                                ].join('\n')
                              : row.errors.join(' · '),
                        ),
                        trailing: Text(
                          row.errors.isNotEmpty
                              ? 'Invalid'
                              : row.warnings.isNotEmpty
                              ? 'Review'
                              : row.skip
                              ? 'Skipped'
                              : row.exists
                              ? 'Update'
                              : 'Create',
                        ),
                      );
                    },
                  ),
          ),
          if (_preview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _loading ? null : _confirmImport,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Confirm batch import'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ImportRow {
  const _ImportRow({
    required this.source,
    required this.id,
    required this.exists,
    required this.errors,
    required this.warnings,
    required this.summary,
    this.skip = false,
  });

  final Map<String, dynamic> source;
  final String id;
  final bool exists;
  final List<String> errors;
  final List<String> warnings;
  final String summary;

  final bool skip;
}

String _first(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    final String value = '${row[key] ?? ''}'.trim();
    if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
  }
  return '';
}

String _rowSummary(Map<String, dynamic> row) {
  return row.entries
      .take(4)
      .map((MapEntry<String, dynamic> entry) => '${entry.key}: ${entry.value}')
      .join(' · ');
}
