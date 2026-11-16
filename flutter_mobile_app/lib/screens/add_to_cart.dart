import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:provider/provider.dart';
import 'order_cart_screen.dart';
import 'barcode_scanner_screen.dart';
import '../copilot/mobile_copilot_commands.dart';
import '../copilot/mobile_copilot_page.dart';
import '../providers/auth_provider.dart';
import '../models/guided_visit_context.dart';
import '../services/cart_draft_cache.dart';
import '../services/order_line_prices.dart';
import '../utils/barcode_key.dart';
import '../utils/order_reference.dart';
import '../widgets/app_icon_button.dart';
import '../widgets/barcode_product_choice.dart';
import '../widgets/cart_selection_sheet.dart';
import '../utils/salesperson_cart_limits.dart';
import '../utils/tenten_catalogue.dart';
import '../utils/product_catalogue_pager.dart';
import '../voice/core/action_registry.dart';
import '../voice/core/voice_binding.dart';
import '../voice/core/voice_dispatcher.dart';
import '../voice/core/voice_engine.dart';
import '../voice/core/voice_types.dart';
import '../voice/voice_registry_factory.dart';
import '../theme/app_theme.dart';

class ProductItem {
  final String productId;
  final String itemBarcode;
  final String name;
  final String packingSize;
  final String uom;
  final num unitPrice;
  final int sortOrder;
  bool isChecked;

  ProductItem({
    required this.productId,
    required this.itemBarcode,
    required this.name,
    required this.packingSize,
    required this.uom,
    required this.unitPrice,
    required this.sortOrder,
    this.isChecked = false,
  });

  factory ProductItem.fromFirestore(Map<String, dynamic> data) {
    return ProductItem(
      productId: _readText(data, <String>[
        'docId',
        'productId',
        'itemCode',
        'productCode',
        'sku',
      ]),
      itemBarcode: _readText(data, <String>['itemBarcode', 'barcode']),
      name: _readText(data, <String>[
        'itemName',
        'productName',
        'product_name',
        'displayName',
        'name',
      ]),
      packingSize: _readText(data, <String>['packingSize', 'packagingSize']),
      uom: _readText(data, <String>[
        'uom',
        'uomLabel',
        'unitOfMeasure',
      ], fallback: 'ctn'),
      unitPrice: _readNum(data, <String>['unitPrice', 'price', 'priceGuide']),
      sortOrder: _readInt(data, <String>['sortOrder', 'position']),
    );
  }
}

String _readText(
  Map<String, dynamic> data,
  List<String> keys, {
  String fallback = '',
}) {
  for (final String key in keys) {
    final Object? raw = data[key];
    if (raw == null) continue;
    final String value = raw.toString().trim();
    if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
  }
  return fallback;
}

num _readNum(Map<String, dynamic> data, List<String> keys, {num fallback = 0}) {
  for (final String key in keys) {
    final Object? raw = data[key];
    if (raw is num) return raw;
    final num? parsed = num.tryParse(raw?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return fallback;
}

int _readInt(Map<String, dynamic> data, List<String> keys, {int fallback = 0}) {
  for (final String key in keys) {
    final Object? raw = data[key];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    final int? parsed = int.tryParse(raw?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return fallback;
}

class SubCategory {
  final String name;
  final List<ProductItem> items;
  SubCategory({required this.name, required this.items});
}

class MainCategory {
  final String name;
  final List<SubCategory> subCategories;
  MainCategory({required this.name, required this.subCategories});
}

class Department {
  final String name;
  final List<MainCategory> mainCategories;
  Department({required this.name, required this.mainCategories});
}

bool _createdAfter(Object? createdAt, Object? settingsUpdatedAt) {
  return createdAt is Timestamp &&
      settingsUpdatedAt is Timestamp &&
      createdAt.compareTo(settingsUpdatedAt) > 0;
}

List<Department> _groupProductRowsIntoDepartments(
  List<Map<String, dynamic>> rows,
) {
  final Map<String, Map<String, Map<String, List<ProductItem>>>> grouped =
      <String, Map<String, Map<String, List<ProductItem>>>>{};
  for (final Map<String, dynamic> data in rows) {
    if (!isOrderableCatalogueProduct(data)) continue;
    final String dept = _readText(data, <String>[
      'departmentName',
      'department',
    ], fallback: 'Other');
    final String mainCat = _readText(data, <String>[
      'mainCategoryName',
      'categoryName',
      'category',
    ], fallback: 'Other');
    final String subCat = _readText(data, <String>[
      'subCategoryName',
      'subCategory',
    ], fallback: 'Other');
    grouped.putIfAbsent(dept, () => <String, Map<String, List<ProductItem>>>{});
    grouped[dept]!.putIfAbsent(mainCat, () => <String, List<ProductItem>>{});
    grouped[dept]![mainCat]!.putIfAbsent(subCat, () => <ProductItem>[]);
    grouped[dept]![mainCat]![subCat]!.add(ProductItem.fromFirestore(data));
  }

  for (final Map<String, Map<String, List<ProductItem>>> mainMap
      in grouped.values) {
    for (final Map<String, List<ProductItem>> subMap in mainMap.values) {
      for (final List<ProductItem> items in subMap.values) {
        items.sort(
          (ProductItem a, ProductItem b) => a.sortOrder.compareTo(b.sortOrder),
        );
      }
    }
  }

  final List<Department> departments = grouped.entries.map((
    MapEntry<String, Map<String, Map<String, List<ProductItem>>>> deptEntry,
  ) {
    final List<MainCategory> mainCategories =
        deptEntry.value.entries.map((
            MapEntry<String, Map<String, List<ProductItem>>> mainEntry,
          ) {
            final List<SubCategory> subCategories = mainEntry.value.entries.map(
              (MapEntry<String, List<ProductItem>> subEntry) {
                return SubCategory(name: subEntry.key, items: subEntry.value);
              },
            ).toList();
            return MainCategory(
              name: mainEntry.key,
              subCategories: subCategories,
            );
          }).toList()
          ..sort((MainCategory a, MainCategory b) => a.name.compareTo(b.name));
    return Department(name: deptEntry.key, mainCategories: mainCategories);
  }).toList()..sort((Department a, Department b) => a.name.compareTo(b.name));

  return departments;
}

Map<String, dynamic> _applyProductOverride(
  Map<String, dynamic> product,
  Map<String, dynamic> override,
) {
  if (override.isEmpty) return product;
  final Map<String, dynamic> merged = Map<String, dynamic>.from(product);
  for (final MapEntry<String, dynamic> entry in override.entries) {
    if (entry.value != null) merged[entry.key] = entry.value;
  }
  return merged;
}

Stream<List<Department>> streamDepartmentsForRetailer(String retailerId) {
  final FirebaseFirestore firestore = FirebaseFirestore.instance;
  final StreamController<List<Department>> controller =
      StreamController<List<Department>>();

  List<Map<String, dynamic>>? latestProducts;
  DocumentSnapshot<Map<String, dynamic>>? latestSettings;
  StreamSubscription<List<Map<String, dynamic>>>? productsSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? settingsSub;
  bool active = true;
  Future<void>? cancellation;

  Future<void> stop() {
    active = false;
    return cancellation ??= Future.wait<void>(<Future<void>>[
      if (productsSub != null) productsSub.cancel(),
      if (settingsSub != null) settingsSub.cancel(),
    ]).then<void>((_) {});
  }

  void reportError(Object error, StackTrace stack) {
    if (active) controller.addError(error, stack);
  }

  void emit() {
    final List<Map<String, dynamic>>? products = latestProducts;
    if (!active ||
        products == null ||
        latestSettings == null ||
        controller.isClosed) {
      return;
    }

    final Map<String, dynamic> settings =
        latestSettings?.data() ?? <String, dynamic>{};
    final Set<String> disabledProductIds =
        ((settings['disabledProductIds'] as List<dynamic>?) ?? <dynamic>[])
            .map((dynamic value) => value.toString())
            .toSet();
    final Set<String> hiddenProductIds =
        ((settings['hiddenProductIds'] as List<dynamic>?) ?? <dynamic>[])
            .map((dynamic value) => value.toString())
            .toSet();
    final List<dynamic> visibleList =
        (settings['visibleProductIds'] as List<dynamic>?) ?? <dynamic>[];
    final Set<String> visibleProductIds = visibleList
        .map((dynamic value) => value.toString())
        .toSet();
    final Map<String, dynamic> overrides = Map<String, dynamic>.from(
      (settings['productOverrides'] as Map<dynamic, dynamic>?) ??
          <dynamic, dynamic>{},
    );

    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> row in products) {
      final String productId = row['docId'] as String;
      final Map<String, dynamic> product = Map<String, dynamic>.from(row)
        ..['productId'] = productId;
      if (!isOrderableCatalogueProduct(product)) continue;
      if (disabledProductIds.contains(productId)) continue;
      if (hiddenProductIds.contains(productId)) continue;
      if (visibleProductIds.isNotEmpty &&
          !visibleProductIds.contains(productId) &&
          !_createdAfter(product['createdAt'], settings['updatedAt'])) {
        continue;
      }
      final Map<String, dynamic> override = Map<String, dynamic>.from(
        (overrides[productId] as Map<dynamic, dynamic>?) ??
            <dynamic, dynamic>{},
      );
      final EffectiveLinePrice price = effectiveLinePrice(
        productId: productId,
        product: product,
        retailerSheet: settings,
      );
      rows.add(
        _applyProductOverride(product, override)
          ..['docId'] = productId
          ..['productId'] = productId
          ..['unitPrice'] = price.unitPrice ?? 0,
      );
    }

    rows.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final int dept = _readText(a, <String>[
        'departmentName',
      ]).compareTo(_readText(b, <String>['departmentName']));
      if (dept != 0) return dept;
      final int cat = _readText(a, <String>[
        'mainCategoryName',
        'categoryName',
      ]).compareTo(_readText(b, <String>['mainCategoryName', 'categoryName']));
      if (cat != 0) return cat;
      final int order = _readInt(a, <String>[
        'sortOrder',
      ]).compareTo(_readInt(b, <String>['sortOrder']));
      if (order != 0) return order;
      return _readText(a, <String>[
        'productName',
        'itemName',
      ]).compareTo(_readText(b, <String>['productName', 'itemName']));
    });

    controller.add(_groupProductRowsIntoDepartments(rows));
  }

  productsSub = watchPagedProducts(firestore).listen(
    (List<Map<String, dynamic>> products) {
      if (!active) return;
      latestProducts = products;
      emit();
    },
    onError: reportError,
    onDone: () {
      if (active) unawaited(stop().then((_) => controller.close()));
    },
  );

  settingsSub = firestore
      .collection('retailer_score_sheet_settings')
      .doc(retailerId)
      .snapshots()
      .listen((DocumentSnapshot<Map<String, dynamic>> snapshot) async {
        if (!active) return;
        unawaited(CurrentLinePrices.rememberSheet(retailerId, snapshot));
        if (!snapshot.exists && snapshot.metadata.isFromCache) {
          final bool noSheet = await CurrentLinePrices.confirmedNoSheet(
            retailerId,
          );
          if (!active || latestSettings != null) return;
          if (!noSheet) {
            reportError(const RetailerSheetUnavailable(), StackTrace.current);
            return;
          }
        }
        latestSettings = snapshot;
        emit();
      }, onError: reportError);

  controller.onCancel = stop;

  return controller.stream;
}

class AddToCartPage extends StatefulWidget {
  final String retailerId;
  final String retailerName;
  final List<Map<String, dynamic>> initialSelectedItems;
  final String? visitId;
  final GuidedVisitContext? guidedVisitContext;

  const AddToCartPage({
    super.key,
    required this.retailerId,
    required this.retailerName,
    this.initialSelectedItems = const [],
    this.visitId,
    this.guidedVisitContext,
  });

  @override
  State<AddToCartPage> createState() => _AddToCartState();
}

class _AddToCartState extends State<AddToCartPage> {
  List<Department> _departments = [];
  bool _isLoading = true;
  String? _error;

  String? _expandedCategoryName;
  bool _autoExpandedOnce = false;

  final Set<String> _initiallySelected = {};
  final Set<String> _legacySelectedNames = {};
  bool _selectionRestored = false;
  String? _legacySelectionWarning;
  bool _restoreLimitPromptShown = false;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  late final VoiceScreenBinding _voiceBinding;
  late final VoiceCommandEngine _voiceEngine;

  StreamSubscription<List<Department>>? _productsSub;
  late final AuthProvider _catalogueAuth;
  late final String _catalogueAccess;
  bool _catalogueAccessLost = false;

  String _catalogueAccessKey() {
    final user = _catalogueAuth.user;
    return '${user?.uid}|${user?.branchId}|${user?.role}|${user?.identityCode}';
  }

  void _checkCatalogueAccess() {
    if (!mounted || _catalogueAccessLost) return;
    final user = _catalogueAuth.user;
    if (_catalogueAuth.isLoggedIn &&
        user?.hasActiveAccount == true &&
        user?.hasSalespersonRole == true &&
        user?.uid == _salesmanUid &&
        _catalogueAccessKey() == _catalogueAccess) {
      return;
    }
    _catalogueAccessLost = true;
    unawaited(_productsSub?.cancel());
    _productsSub = null;
    setState(() {
      _departments = <Department>[];
      _initiallySelected.clear();
      _legacySelectedNames.clear();
      _isLoading = false;
      _error = 'Your access changed. Reopen this visit after signing in.';
    });
  }

  String get _salesmanUid =>
      FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

  String get _draftKey => CartDraftCache.keyFor(
    salesmanUid: _salesmanUid,
    retailerId: widget.retailerId,
    visitId: widget.visitId,
    routePlanId: widget.guidedVisitContext?.planId,
    routeStopId: widget.guidedVisitContext?.stopId,
  );

  CartDraftSnapshot? get _draft => CartDraftCache.read(_draftKey);

  @override
  void initState() {
    super.initState();
    _catalogueAuth = context.read<AuthProvider>();
    _catalogueAccess = _catalogueAccessKey();
    _catalogueAuth.addListener(_checkCatalogueAccess);
    _voiceBinding = VoiceScreenBinding(surfaceId: VoiceSurfaceIds.addToCart);
    _voiceBinding.registerHandler(
      VoiceActionId.searchProducts,
      _handleVoiceSearchProducts,
    );
    _voiceBinding.registerHandler(
      VoiceActionId.clearProductSearch,
      _handleVoiceClearProductSearch,
    );
    _voiceEngine = VoiceCommandEngine(
      sessionId: 'add-to-cart-${DateTime.now().microsecondsSinceEpoch}',
      binding: _voiceBinding,
      dispatcher: VoiceActionDispatcher(
        registry: buildVoiceActionRegistry(),
        binding: _voiceBinding,
      ),
    );
    final draft = _draft;
    for (final item in [...widget.initialSelectedItems, ...?draft?.items]) {
      final id = (item['productId'] ?? '').toString().trim();
      final name = (item['name'] ?? '').toString().trim();
      if (id.isNotEmpty) {
        _initiallySelected.add(id);
      } else if (name.isNotEmpty) {
        _legacySelectedNames.add(name);
      }
    }
    _subscribeToProducts();
  }

  void _subscribeToProducts() {
    _productsSub = streamDepartmentsForRetailer(widget.retailerId).listen(
      (depts) {
        if (!mounted || _catalogueAccessLost) return;
        final currentIds = _selectionRestored
            ? _currentlySelected
            : _initiallySelected;
        final products = [
          for (final dept in depts)
            for (final main in dept.mainCategories)
              for (final sub in main.subCategories) ...sub.items,
        ];
        if (!_selectionRestored) {
          for (final name in _legacySelectedNames) {
            final matches = products.where((p) => p.name == name).toList();
            if (matches.length == 1) {
              currentIds.add(matches.single.productId);
              _legacySelectionWarning ??=
                  'Legacy draft: matched by name. Please review the selected products.';
            } else {
              _legacySelectionWarning =
                  'Legacy draft: ambiguous or unavailable product "$name". Choose the exact product again.';
            }
          }
          _selectionRestored = true;
        }
        for (final item in products) {
          item.isChecked = currentIds.contains(item.productId);
        }
        if (mounted) {
          setState(() {
            _departments = depts;
            _error = null;
            if (!_autoExpandedOnce) {
              final cats = _allCategories;
              if (cats.isNotEmpty) {
                _expandedCategoryName = cats.first.name;
                _autoExpandedOnce = true;
              }
            }
            _isLoading = false;
          });
          _maybePromptForRestoredSelectionLimit();
        }
      },
      onError: (Object e) {
        if (mounted && !_catalogueAccessLost) {
          setState(() {
            _error = e.toString();
            _isLoading = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _catalogueAccessLost = true;
    _catalogueAuth.removeListener(_checkCatalogueAccess);
    _productsSub?.cancel();
    _searchController.dispose();
    _voiceBinding.dispose();
    super.dispose();
  }

  Future<VoiceActionResult> _handleVoiceSearchProducts(
    VoiceCommandEnvelope envelope,
  ) async {
    final Object? rawQuery = envelope.interpretation.parameters['query'];
    if (rawQuery is! String || rawQuery.trim().isEmpty) {
      return const VoiceActionResult(code: VoiceResultCode.invalidParameters);
    }
    final String query = rawQuery.trim();
    _searchController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    if (mounted) setState(() => _searchQuery = query);
    return const VoiceActionResult.applied();
  }

  Future<VoiceActionResult> _handleVoiceClearProductSearch(
    VoiceCommandEnvelope envelope,
  ) async {
    _searchController.clear();
    if (mounted) setState(() => _searchQuery = '');
    return const VoiceActionResult.applied();
  }

  List<ProductItem> _productsForCategoryRaw(MainCategory main) {
    final list = <ProductItem>[];
    for (final sub in main.subCategories) {
      list.addAll(sub.items);
    }
    return list;
  }

  List<MainCategory> get _allCategories {
    final list = <MainCategory>[];
    for (final dept in _departments) {
      list.addAll(dept.mainCategories);
    }
    list.sort((a, b) {
      final aHasSelected =
          _productsForCategoryRaw(
            a,
          ).any((p) => _initiallySelected.contains(p.name))
          ? 0
          : 1;
      final bHasSelected =
          _productsForCategoryRaw(
            b,
          ).any((p) => _initiallySelected.contains(p.name))
          ? 0
          : 1;
      return aHasSelected.compareTo(bHasSelected);
    });
    return list;
  }

  List<ProductItem> _productsForCategory(MainCategory main) {
    final list = _productsForCategoryRaw(main);
    list.sort((a, b) {
      final aSelected = _initiallySelected.contains(a.productId) ? 0 : 1;
      final bSelected = _initiallySelected.contains(b.productId) ? 0 : 1;
      return aSelected.compareTo(bSelected);
    });
    return list;
  }

  List<ProductItem> get _searchResults {
    if (_searchQuery.isEmpty) return [];
    final q = _searchQuery.toLowerCase();
    final results = <ProductItem>[];
    for (final dept in _departments) {
      for (final main in dept.mainCategories) {
        for (final sub in main.subCategories) {
          for (final item in sub.items) {
            if (item.name.toLowerCase().contains(q) ||
                item.productId.toLowerCase().contains(q) ||
                barcodeMatchesQuery(item.itemBarcode, _searchQuery)) {
              results.add(item);
            }
          }
        }
      }
    }
    results.sort((a, b) {
      final aSelected = _initiallySelected.contains(a.productId) ? 0 : 1;
      final bSelected = _initiallySelected.contains(b.productId) ? 0 : 1;
      return aSelected.compareTo(bSelected);
    });
    return results;
  }

  bool get _isSearching => _searchQuery.isNotEmpty;

  int get _selectedCount {
    int count = 0;
    for (final cat in _allCategories) {
      for (final item in _productsForCategory(cat)) {
        if (item.isChecked) count++;
      }
    }
    return count;
  }

  int _categoryCheckedCount(MainCategory main) =>
      _productsForCategory(main).where((i) => i.isChecked).length;

  bool _categoryAllChecked(MainCategory main) {
    final items = _productsForCategory(main);
    return items.isNotEmpty && items.every((i) => i.isChecked);
  }

  void _showSelectionLimitMessage() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'You can select up to ${SalespersonCartLimits.maxDistinctItems} '
            'products per order. Remove a product before adding another.',
          ),
        ),
      );
  }

  void _maybePromptForRestoredSelectionLimit() {
    if (_restoreLimitPromptShown ||
        SalespersonCartLimits.isWithinDistinctItemLimit(
          _initiallySelected.length,
        ) ||
        !mounted) {
      return;
    }
    _restoreLimitPromptShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Saved cart needs review'),
          content: Text(
            'Your saved cart contains ${_initiallySelected.length} products. '
            'Orders can contain at most '
            '${SalespersonCartLimits.maxDistinctItems} products. '
            'Please remove products before continuing.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Review selection'),
            ),
          ],
        ),
      );
    });
  }

  void _setItemSelection(ProductItem item, bool selected) {
    if (item.isChecked == selected) return;
    if (selected &&
        !SalespersonCartLimits.canAddDistinctItems(
          selectedCount: _selectedCount,
        )) {
      _showSelectionLimitMessage();
      return;
    }
    setState(() => item.isChecked = selected);
  }

  void _toggleCategory(MainCategory main, bool check) {
    final items = _productsForCategory(main);
    if (!check) {
      setState(() {
        for (final item in items) {
          item.isChecked = false;
        }
      });
      return;
    }

    final unchecked = items.where((item) => !item.isChecked).toList();
    if (unchecked.isEmpty) return;

    final int remaining =
        SalespersonCartLimits.maxDistinctItems - _selectedCount;
    final int toSelectCount = remaining <= 0
        ? 0
        : remaining < unchecked.length
        ? remaining
        : unchecked.length;
    if (toSelectCount == 0) {
      _showSelectionLimitMessage();
      return;
    }

    setState(() {
      for (final item in unchecked.take(toSelectCount)) {
        item.isChecked = true;
      }
    });
    if (toSelectCount < unchecked.length) {
      _showSelectionLimitMessage();
    }
  }

  Future<void> _openBarcodeScanner() async {
    final scanned = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => BarcodeScannerScreen(retailerName: widget.retailerName),
        fullscreenDialog: true,
      ),
    );
    if (scanned == null || !mounted) return;

    final matches = <ProductItem>[];
    for (final dept in _departments) {
      for (final main in dept.mainCategories) {
        for (final sub in main.subCategories) {
          for (final item in sub.items) {
            if (barcodesMatch(item.itemBarcode, scanned)) {
              matches.add(item);
            }
          }
        }
      }
    }
    final chosen = await chooseBarcodeProduct(
      context,
      matches: matches,
      label: (item) =>
          '${item.name} · ${item.packingSize} · ${item.productId} · RM ${item.unitPrice.toStringAsFixed(2)}',
    );
    if (!mounted || (matches.isNotEmpty && chosen == null)) return;
    if (chosen == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Barcode $scanned not found for this retailer.'),
          backgroundColor: Colors.red[700],
        ),
      );
      return;
    }
    ProductItem? found;
    MainCategory? foundCategory;
    for (final category in _allCategories) {
      for (final item in _productsForCategoryRaw(category)) {
        if (item.productId == chosen.productId &&
            barcodesMatch(item.itemBarcode, scanned)) {
          found = item;
          foundCategory = category;
        }
      }
    }
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This product is no longer available. Scan again.'),
        ),
      );
      return;
    }
    final selectedProduct = found;
    if (!found.isChecked &&
        !SalespersonCartLimits.canAddDistinctItems(
          selectedCount: _selectedCount,
        )) {
      _showSelectionLimitMessage();
      return;
    }

    setState(() {
      selectedProduct.isChecked = true;
      _expandedCategoryName = foundCategory!.name;
      _searchQuery = '';
      _searchController.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text('Selected: ${selectedProduct.name}')),
          ],
        ),
        backgroundColor: AppColors.greenSolid,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Set<String> get _currentlySelected {
    final selected = <String>{};
    for (final cat in _allCategories) {
      for (final item in _productsForCategory(cat)) {
        if (item.isChecked) selected.add(item.productId);
      }
    }
    return selected;
  }

  String _productLabel(String id) {
    for (final category in _allCategories) {
      for (final product in _productsForCategoryRaw(category)) {
        if (product.productId == id) {
          return product.packingSize.isEmpty
              ? product.name
              : '${product.name} · ${product.packingSize}';
        }
      }
    }
    return id;
  }

  Future<void> _addToCart() async {
    final selected = _currentlySelected;

    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one product.')),
      );
      return;
    }
    if (!SalespersonCartLimits.isWithinDistinctItemLimit(selected.length)) {
      _showSelectionLimitMessage();
      return;
    }

    final added = selected.difference(_initiallySelected).toList();
    final removed = _initiallySelected.difference(selected).toList();

    final confirmed = await showCartSelectionSheet(
      context,
      totalSelected: selected.length,
      added: added.map(_productLabel).toList(),
      removed: removed.map(_productLabel).toList(),
      previouslySelected: _initiallySelected.map(_productLabel).toList()
        ..sort(),
    );
    if (confirmed != true || !mounted) return;

    final visitId = widget.visitId?.trim() ?? '';
    if (visitId.isNotEmpty) {
      FirebaseFirestore.instance.collection('visits').doc(visitId).update({
        'draftStage': 1,
        'progress': 1,
        'status': 'selecting',
        'step1At': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OrderCartScreen(
          selectedItems: [
            for (final id in selected) {'productId': id},
          ],
          retailerId: widget.retailerId,
          retailerName: widget.retailerName,
          visitId: widget.visitId,
          guidedVisitContext: widget.guidedVisitContext,
        ),
      ),
    );
  }

  List<String> get _copilotSuggestions {
    for (final Department department in _departments) {
      for (final MainCategory main in department.mainCategories) {
        for (final SubCategory sub in main.subCategories) {
          for (final ProductItem item in sub.items) {
            final String name = item.name
                .split(RegExp(r'\s+'))
                .where((String word) => word.isNotEmpty)
                .take(2)
                .join(' ');
            if (name.isNotEmpty) {
              return <String>['Search for $name', 'Clear search'];
            }
          }
        }
      }
    }
    return const <String>['Clear search'];
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final user = auth.user;
    _voiceBinding.updateContext(
      uid: user?.uid ?? _salesmanUid,
      role: user?.role ?? '',
      retailerId: widget.retailerId,
      visitId: widget.visitId,
      draftId: _draftKey,
    );
    final ScootColors c = ScootColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      appBar: ScootPhoneAppBar(
        title: widget.retailerName,
        subtitle: retailerCodeLabel(
          widget.retailerId,
          retailerName: widget.retailerName,
        ),
        onBack: () => Navigator.of(context).maybePop(),
        actions: <Widget>[
          CopilotEntryButton(
            screen: CopilotScreenContext(
              engine: _voiceEngine,
              suggestions: _copilotSuggestions,
            ),
          ),
          ScootPhoneAction(
            icon: ScootIcons.scanBarcode,
            label: 'Scan barcode',
            onPressed: _openBarcodeScanner,
          ),
        ],
      ),
      bottomNavigationBar: ScootPrimaryActionBar(
        label: _selectedCount > 0
            ? 'Add to Cart ($_selectedCount)'
            : 'Add to Cart',
        icon: ScootIcons.orders,
        aboveHomeIndicator: true,
        onPressed: _addToCart,
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            const ScootStepBar(
              current: 0,
              steps: <String>['Select', 'Count', 'Sign-off'],
            ),
            if (_legacySelectionWarning != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_legacySelectionWarning!),
              ),
            ValueListenableBuilder<DateTime?>(
              valueListenable: offlineCatalogueFrom,
              builder: (BuildContext context, DateTime? preparedAt, _) {
                if (preparedAt == null || _isLoading) {
                  return const SizedBox.shrink();
                }
                final String at =
                    '${preparedAt.day.toString().padLeft(2, '0')}/'
                    '${preparedAt.month.toString().padLeft(2, '0')}/'
                    '${preparedAt.year} '
                    '${preparedAt.hour.toString().padLeft(2, '0')}:'
                    '${preparedAt.minute.toString().padLeft(2, '0')}';
                return Container(
                  width: double.infinity,
                  color: const Color(0xFFEBE3CB),
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    'Offline catalogue prepared $at. Prices and products may have changed since then.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textAmber,
                    ),
                  ),
                );
              },
            ),
            _buildSearchBar(),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF00A651),
                      ),
                    )
                  : _error != null
                  ? Center(
                      child: Text(
                        'Error: $_error',
                        style: const TextStyle(
                          color: AppColors.textRed,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : _departments.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No orderable products for this retailer.\n\n'
                          'This list shows the catalogue items that the '
                          'retailer score sheet allows. Products can be '
                          'missing when the score sheet hides them or the '
                          'product is hidden in the catalogue. Ask an admin '
                          'to check both.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textGrey,
                          ),
                        ),
                      ),
                    )
                  : _isSearching
                  ? _buildSearchResults()
                  : _buildColumnLayout(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final ScootColors c = ScootColors.of(context);
    return Container(
      color: c.card,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        controller: _searchController,
        onChanged: (val) => setState(() => _searchQuery = val.trim()),
        style: const TextStyle(fontSize: 13, color: Colors.black87),
        decoration: InputDecoration(
          hintText: 'Search SKU or product...',
          hintStyle: const TextStyle(fontSize: 13, color: AppColors.textGrey),
          prefixIcon: Icon(ScootIcons.search, color: c.text2, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? AppIconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                  icon: Icons.close,
                  color: AppColors.textGrey,
                  size: 18,
                )
              : null,
          filled: true,
          fillColor: c.page,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 0,
          ),
          border: OutlineInputBorder(
            borderRadius: ScootRadius.controlAll,
            borderSide: BorderSide(color: c.line),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    final results = _searchResults;
    if (results.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 40, color: Colors.grey),
            SizedBox(height: 8),
            Text(
              'No products found',
              style: TextStyle(fontSize: 13, color: AppColors.textGrey),
            ),
          ],
        ),
      );
    }
    return Container(
      color: Colors.white,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: results.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: Colors.grey[200]),
        itemBuilder: (_, i) {
          final item = results[i];
          return CheckboxListTile(
            value: item.isChecked,
            onChanged: (val) => _setItemSelection(item, val ?? false),
            title: Text(
              '${item.packingSize.isEmpty ? '' : '${item.packingSize} · '}${item.name}',
              style: const TextStyle(fontSize: 11, color: Colors.black87),
            ),
            subtitle: item.packingSize.isNotEmpty
                ? Text(
                    '${item.productId}${item.itemBarcode.isEmpty ? '' : '  •  ${item.itemBarcode}'}  •  RM ${item.unitPrice}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textGrey,
                    ),
                  )
                : Text(
                    '${item.productId}${item.itemBarcode.isEmpty ? '' : '  •  ${item.itemBarcode}'}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textGrey,
                    ),
                  ),
            dense: true,
            activeColor: const Color(0xFF00A651),
            controlAffinity: ListTileControlAffinity.trailing,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 0,
            ),
          );
        },
      ),
    );
  }

  Widget _buildColumnLayout() {
    final ScootColors c = ScootColors.of(context);
    final categories = _allCategories;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Container(
            decoration: BoxDecoration(
              color: c.card,
              border: Border(right: BorderSide(color: c.line)),
            ),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: categories.length,
              itemBuilder: (_, i) {
                final cat = categories[i];
                final isExpanded = _expandedCategoryName == cat.name;
                final checkedCount = _categoryCheckedCount(cat);
                final allChecked = _categoryAllChecked(cat);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () => setState(() {
                        _expandedCategoryName = isExpanded ? null : cat.name;
                      }),
                      child: Container(
                        color: isExpanded ? c.brandTint : Colors.transparent,
                        padding: const EdgeInsets.fromLTRB(8, 11, 8, 11),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: Checkbox(
                                value: allChecked,
                                tristate: checkedCount > 0 && !allChecked,
                                semanticLabel: 'Select all in ${cat.name}',
                                onChanged: (_) {
                                  _toggleCategory(cat, !allChecked);
                                  setState(
                                    () => _expandedCategoryName = cat.name,
                                  );
                                },
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                cat.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: ScootType.small.copyWith(
                                  color: isExpanded ? c.brandText : c.ink,
                                  fontWeight: isExpanded
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (checkedCount > 0)
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 28),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: c.brand,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '$checkedCount',
                                    textAlign: TextAlign.center,
                                    style: ScootType.caption.copyWith(
                                      color: c.onBrand,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Divider(height: 1, color: c.hair),
                  ],
                );
              },
            ),
          ),
        ),

        Expanded(
          child: Container(
            color: c.card,
            child: _expandedCategoryName == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(ScootIcons.layers, size: 36, color: c.line2),
                        const SizedBox(height: 8),
                        Text(
                          'Tap a category to view products',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textGrey,
                          ),
                        ),
                      ],
                    ),
                  )
                : Builder(
                    builder: (_) {
                      final cat = _allCategories.firstWhere(
                        (c) => c.name == _expandedCategoryName,
                        orElse: () => _allCategories.first,
                      );
                      final products = _productsForCategory(cat);
                      return ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: products.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: c.hair),
                        itemBuilder: (_, i) {
                          final item = products[i];
                          return CheckboxListTile(
                            value: item.isChecked,
                            onChanged: (val) =>
                                _setItemSelection(item, val ?? false),
                            title: Text(
                              '${item.packingSize.isEmpty ? '' : '${item.packingSize} · '}${item.name}',
                              style: ScootType.small.copyWith(color: c.ink),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      item.itemBarcode.isEmpty
                                          ? item.productId
                                          : '${item.productId}  •  ${item.itemBarcode}',
                                      style: ScootType.mono.copyWith(
                                        fontSize: 12,
                                        color: c.text2,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'RM ${item.unitPrice.toStringAsFixed(2)}',
                                      style: ScootType.smallStrong.copyWith(
                                        color: c.brandText,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            isThreeLine: true,
                            dense: true,
                            controlAffinity: ListTileControlAffinity.trailing,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 2,
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
