import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../app/permission_policy.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/permission_policy_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/price_stamp.dart';
import '../../../utils/catalogue_cache.dart';
import '../../../utils/cms_permissions.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/retailer_scope.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../../../widgets/dso_filter_controls.dart';
import '../../../widgets/catalogue/catalogue_column.dart';
import '../../../widgets/catalogue/catalogue_drawer.dart';
import '../../../widgets/catalogue/catalogue_issue_count.dart';
import '../../../widgets/catalogue/catalogue_states.dart';
import '../../../widgets/catalogue/catalogue_table.dart';
import '../../../widgets/catalogue/catalogue_toolbar.dart';
import '../../../widgets/catalogue/catalogue_view_state.dart';
import '../../../widgets/catalogue/catalogue_workspace.dart';
import 'score_sheet_template_library.dart';

const Set<String> _retailerProductOverrideFields = <String>{
  'packingSize',
  'barcode',
  'itemBarcode',
  'unitPrice',
  'price',
  'priceGuide',
  'sortOrder',
  'isVisible',
};

class RetailerScoreSheetPage extends StatefulWidget {
  const RetailerScoreSheetPage({super.key, this.currentUser});

  final UserProfile? currentUser;

  @override
  State<RetailerScoreSheetPage> createState() => _RetailerScoreSheetPageState();
}

class _RetailerScoreSheetPageState extends State<RetailerScoreSheetPage> {
  final CmsRepository _repository = CmsRepository();

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _sheetNameController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final CatalogueViewState<Map<String, dynamic>> _view =
      CatalogueViewState<Map<String, dynamic>>();
  final TextEditingController _packingController = TextEditingController();
  final TextEditingController _barcodeController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _sortController = TextEditingController();

  String? _selectedRetailerId;
  String? _selectedRetailerName;
  bool _isLoadingExistingSheet = false;
  bool _isSaving = false;
  bool _overrideDrawerOpen = false;
  bool _libraryOpen = false;
  bool _overrideVisible = true;
  Map<String, dynamic>? _editingProduct;
  _ScoreSheetItemDraft? _overrideDraft;
  List<Map<String, dynamic>> _currentProducts = <Map<String, dynamic>>[];
  Map<String, double?> _masterPrices = <String, double?>{};
  ScoreSheetLoadedState _loaded = const ScoreSheetLoadedState(
    stamp: null,
    visibleIds: <String>{},
  );

  static const Duration _catalogueTtl = Duration(minutes: 5);
  late final CatalogueCache<List<Map<String, dynamic>>> _catalogue =
      CatalogueCache<List<Map<String, dynamic>>>(ttl: _catalogueTtl);

  int _selectRequestId = 0;

  final Map<String, _ScoreSheetItemDraft> _draftItems =
      <String, _ScoreSheetItemDraft>{};

  bool _densityDefaulted = false;
  bool _settingsExist = false;
  String _salespersonCode = '';
  List<_Salesperson> _salespeople = <_Salesperson>[];
  bool _salespeopleLoaded = false;

  bool get _isAdminView =>
      widget.currentUser == null || widget.currentUser!.isAdmin;

  bool get _canWriteSheet =>
      _isAdminView ||
      cmsActionAllowed(
        widget.currentUser,
        'retailer_scoresheets',
        _settingsExist ? PermissionAction.edit : PermissionAction.create,
      );

  bool get _canEditPrices =>
      _isAdminView ||
      cmsActionAllowed(
        widget.currentUser,
        'retailer_scoresheets',
        PermissionAction.edit,
      );

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadSalespeople();
  }

  Future<void> _loadSalespeople() async {
    try {
      final List<Map<String, dynamic>> users = await _repository
          .getCollectionOnce('users', raw: true, limit: 500);
      final UserProfile? actor = widget.currentUser;
      final List<_Salesperson> found = <_Salesperson>[];
      for (final Map<String, dynamic> user in users) {
        final String role = _readText(
          user,
          'role',
          fallbackKeys: <String>['user_group'],
        ).toLowerCase();
        final String status = _readText(
          user,
          'status',
          fallback: 'active',
        ).toLowerCase();
        final String code = _readText(
          user,
          'employeeCode',
          fallbackKeys: <String>['staffId'],
        );
        if (role != 'salesman' || code.isEmpty) continue;
        if (status == 'suspended' || status == 'inactive') continue;
        if (actor != null &&
            actor.isSupervisor &&
            !actor.assignedSalesmanCodes.contains(code)) {
          continue;
        }
        found.add(
          _Salesperson(
            code: code,
            name: _readText(
              user,
              'name',
              fallbackKeys: <String>['displayName'],
              fallback: code,
            ),
          ),
        );
      }
      found.sort(
        (_Salesperson a, _Salesperson b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _salespeople = found;
        _salespeopleLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'load salespeople'),
        isError: true,
      );
      setState(() => _salespeopleLoaded = true);
    }
  }

  void _pickSalesperson(String code) {
    if (_isSaving || code == _salespersonCode) return;
    setState(() {
      _salespersonCode = code;
      _selectRequestId++;
      _selectedRetailerId = null;
      _selectedRetailerName = null;
      _draftItems.clear();
      _currentProducts = <Map<String, dynamic>>[];
      _isLoadingExistingSheet = false;
      _settingsExist = false;
    });
  }

  @override
  void dispose() {
    _view.dispose();
    _searchFocus.dispose();
    _searchController.dispose();
    _sheetNameController.dispose();
    _packingController.dispose();
    _barcodeController.dispose();
    _priceController.dispose();
    _sortController.dispose();
    super.dispose();
  }

  void _onSearchChanged() => _view.setQuery(_searchController.text);

  Future<void> _selectRetailer(Map<String, dynamic> retailer) async {
    if (_isSaving) return;
    if (_overrideDrawerOpen) {
      await closeCatalogueDrawer(
        context,
        dirty: _overrideDirty,
        onClose: _closeOverrideDrawer,
      );
      if (_overrideDrawerOpen) return;
    }

    final int requestId = ++_selectRequestId;
    final String retailerId = _readText(
      retailer,
      'retailerId',
      fallbackKeys: <String>['docId'],
    );
    final String retailerName = _readText(
      retailer,
      'retailerName',
      fallbackKeys: <String>['name'],
      fallback: '-',
    );

    setState(() {
      _selectedRetailerId = retailerId;
      _selectedRetailerName = retailerName;
      _sheetNameController.text = '$retailerName Score Sheet';
      _draftItems.clear();
      _currentProducts = <Map<String, dynamic>>[];
      _masterPrices = <String, double?>{};
      _loaded = ScoreSheetLoadedState(
        stamp: null,
        visibleIds: _loaded.visibleIds,
      );
      _isLoadingExistingSheet = true;
    });

    final List<Object?> loaded;
    try {
      loaded = await Future.wait(<Future<Object?>>[
        _masterProducts(),
        FirebaseFirestore.instance
            .collection('retailer_score_sheet_settings')
            .doc(retailerId)
            .get(),
      ]);
    } catch (error) {
      if (!mounted || requestId != _selectRequestId) return;
      setState(() => _isLoadingExistingSheet = false);
      showCmsToast(
        context,
        userFacingError(
          error,
          action: 'load the score sheet for $retailerName',
        ),
        isError: true,
      );
      return;
    }
    if (!mounted || requestId != _selectRequestId) return;
    final List<Map<String, dynamic>> masterProducts =
        loaded[0]! as List<Map<String, dynamic>>;
    final DocumentSnapshot<Map<String, dynamic>> settingsDoc =
        loaded[1]! as DocumentSnapshot<Map<String, dynamic>>;
    final Map<String, dynamic> settings =
        settingsDoc.data() ?? <String, dynamic>{};
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

    final List<Map<String, dynamic>> products =
        masterProducts.map((Map<String, dynamic> product) {
          final List<String> identityAliases = _productIdentityAliases(product);
          final Map<String, dynamic> override = _firstMapForKeys(
            overrides,
            identityAliases,
          );
          final Map<String, dynamic> merged = Map<String, dynamic>.from(
            product,
          );
          for (final MapEntry<String, dynamic> entry in override.entries) {
            if (entry.value != null &&
                _retailerProductOverrideFields.contains(entry.key)) {
              merged[entry.key] = entry.value;
            }
          }
          return merged;
        }).toList()..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
          final int department = _readText(
            a,
            'departmentName',
          ).compareTo(_readText(b, 'departmentName'));
          if (department != 0) return department;
          final int category =
              _readText(
                a,
                'mainCategoryName',
                fallbackKeys: <String>['categoryName'],
              ).compareTo(
                _readText(
                  b,
                  'mainCategoryName',
                  fallbackKeys: <String>['categoryName'],
                ),
              );
          if (category != 0) return category;
          return (int.tryParse(_readText(a, 'sortOrder', fallback: '0')) ?? 0)
              .compareTo(
                int.tryParse(_readText(b, 'sortOrder', fallback: '0')) ?? 0,
              );
        });

    if (!mounted || requestId != _selectRequestId) return;
    setState(() {
      for (final Map<String, dynamic> product in products) {
        final String productId = _productId(product);
        if (productId.isEmpty) continue;
        final List<String> identityAliases = _productIdentityAliases(product);
        final bool isHidden = identityAliases.any(hiddenProductIds.contains);
        if (scoreSheetProductLoadsTicked(
          aliases: identityAliases,
          disabledIds: disabledProductIds,
          hiddenIds: hiddenProductIds,
          visibleIds: visibleProductIds,
          createdAt: product['createdAt'],
          sheetUpdatedAt: settings['updatedAt'],
        )) {
          _draftItems[productId] = _ScoreSheetItemDraft.fromProduct(
            product,
          ).copyWith(isVisible: !isHidden);
        }
      }
      _currentProducts = products;
      _masterPrices = <String, double?>{
        for (final Map<String, dynamic> product in masterProducts)
          _productId(product): _ScoreSheetItemDraft.fromProduct(
            product,
          ).unitPrice,
      };
      _loaded = ScoreSheetLoadedState(
        stamp: settings['updatedAt'],
        visibleIds: visibleProductIds,
      );
      _settingsExist = settingsDoc.exists;
      _isLoadingExistingSheet = false;
    });
  }

  Future<Object?> _storedSheetStamp(String retailerId) async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await FirebaseFirestore.instance
            .collection('retailer_score_sheet_settings')
            .doc(retailerId)
            .get();
    return snapshot.data()?['updatedAt'];
  }

  Future<void> _reloadSelectedRetailer() async {
    final String? retailerId = _selectedRetailerId;
    final String? retailerName = _selectedRetailerName;
    if (retailerId == null || retailerName == null) return;
    await _selectRetailer(<String, dynamic>{
      'retailerId': retailerId,
      'retailerName': retailerName,
    });
  }

  Future<void> _toggleLibrary() async {
    final bool leavingLibrary = _libraryOpen;
    setState(() => _libraryOpen = !_libraryOpen);
    final String? retailerId = _selectedRetailerId;
    if (!leavingLibrary || retailerId == null || _isLoadingExistingSheet) {
      return;
    }
    final Object? storedStamp;
    try {
      storedStamp = await _storedSheetStamp(retailerId);
    } on FirebaseException {
      return;
    }
    if (!mounted ||
        retailerId != _selectedRetailerId ||
        storedStamp == _loaded.stamp) {
      return;
    }
    await _reloadSelectedRetailer();
    if (!mounted) return;
    showCmsToast(
      context,
      "This retailer's sheet changed in the template library. The latest sheet is now shown.",
    );
  }

  Future<List<Map<String, dynamic>>> _masterProducts() async {
    return _catalogue.get(
      () async => _dedupeProducts(
        scoreSheetEligibleProducts(
          await _repository.getCollectionOnce('products'),
        ),
      ),
    );
  }

  Future<void> _toggleProduct(
    Map<String, dynamic> product,
    bool selected,
  ) async {
    final String productId = _productId(product);
    if (productId.isEmpty) return;

    if (!selected &&
        _overrideDrawerOpen &&
        _editingProduct != null &&
        _productId(_editingProduct!) == productId) {
      await closeCatalogueDrawer(
        context,
        dirty: _overrideDirty,
        onClose: _closeOverrideDrawer,
      );
      if (_overrideDrawerOpen) return;
    }
    setState(() {
      if (selected) {
        _draftItems[productId] = _ScoreSheetItemDraft.fromProduct(product);
      } else {
        _draftItems.remove(productId);
      }
    });
  }

  void _openProductOverride(Map<String, dynamic> product) {
    final String productId = _productId(product);
    if (productId.isEmpty) return;

    final _ScoreSheetItemDraft draft =
        _draftItems[productId] ?? _ScoreSheetItemDraft.fromProduct(product);
    setState(() {
      _editingProduct = product;
      _overrideDraft = draft;
      _packingController.text = draft.packingSize;
      _barcodeController.text = draft.barcode;
      _priceController.text = draft.unitPrice == null
          ? ''
          : draft.unitPrice!.toStringAsFixed(2);
      _sortController.text = draft.sortOrder.toString();
      _overrideVisible = draft.isVisible;
      _overrideDrawerOpen = true;
    });
  }

  bool get _overrideDirty {
    final _ScoreSheetItemDraft? draft = _overrideDraft;
    return draft != null &&
        (_packingController.text.trim() != draft.packingSize ||
            _barcodeController.text.trim() != draft.barcode ||
            double.tryParse(_priceController.text.trim()) != draft.unitPrice ||
            (int.tryParse(_sortController.text.trim()) ?? draft.sortOrder) !=
                draft.sortOrder ||
            _overrideVisible != draft.isVisible);
  }

  void _requestCloseOverrideDrawer() => closeCatalogueDrawer(
    context,
    dirty: _overrideDirty,
    onClose: _closeOverrideDrawer,
  );

  void _closeOverrideDrawer() {
    setState(() {
      _overrideDrawerOpen = false;
      _editingProduct = null;
      _overrideDraft = null;
    });
  }

  void _applyProductOverride() {
    final Map<String, dynamic>? product = _editingProduct;
    final _ScoreSheetItemDraft? draft = _overrideDraft;
    if (product == null || draft == null) return;

    setState(() {
      _draftItems[draft.productId] = draft.copyWith(
        productName: '${product['productName'] ?? draft.productName}',
        productCode:
            '${product['productCode'] ?? product['sku'] ?? draft.productCode}',
        categoryName: '${product['categoryName'] ?? draft.categoryName}',
        subCategoryName:
            '${product['subCategoryName'] ?? draft.subCategoryName}',
        packingSize: _packingController.text.trim(),
        barcode: _barcodeController.text.trim(),
        unitPrice: double.tryParse(_priceController.text.trim()),
        sortOrder: int.tryParse(_sortController.text.trim()) ?? draft.sortOrder,
        isVisible: _overrideVisible,
      );
      _overrideDrawerOpen = false;
      _editingProduct = null;
      _overrideDraft = null;
    });
  }

  bool _allShownProductsSelected(List<Map<String, dynamic>> products) {
    if (products.isEmpty) return false;
    return products.every((Map<String, dynamic> product) {
      final String productId = _productId(product);
      return productId.isNotEmpty && _draftItems.containsKey(productId);
    });
  }

  bool _selectedShownProductsAllHidden(List<Map<String, dynamic>> products) {
    final List<_ScoreSheetItemDraft> selectedShown = products
        .map((Map<String, dynamic> product) => _draftItems[_productId(product)])
        .whereType<_ScoreSheetItemDraft>()
        .toList(growable: false);
    if (selectedShown.isEmpty) return false;
    return selectedShown.every((_ScoreSheetItemDraft item) => !item.isVisible);
  }

  void _toggleAllShownProducts(List<Map<String, dynamic>> products) {
    final bool shouldDeselect = _allShownProductsSelected(products);
    setState(() {
      for (final Map<String, dynamic> product in products) {
        final String productId = _productId(product);
        if (productId.isEmpty) continue;
        if (shouldDeselect) {
          _draftItems.remove(productId);
        } else {
          _draftItems[productId] =
              (_draftItems[productId] ??
                      _ScoreSheetItemDraft.fromProduct(product))
                  .copyWith(isVisible: true);
        }
      }
    });
  }

  void _toggleVisibleForSelectedShown(List<Map<String, dynamic>> products) {
    final bool shouldShow = _selectedShownProductsAllHidden(products);
    setState(() {
      for (final Map<String, dynamic> product in products) {
        final String productId = _productId(product);
        final _ScoreSheetItemDraft? draft = _draftItems[productId];
        if (draft == null) continue;
        _draftItems[productId] = draft.copyWith(isVisible: shouldShow);
      }
    });
  }

  Future<void> _saveScoreSheet() async {
    if (_isSaving) return;
    final String? selectedRetailerId = _selectedRetailerId;
    final String? selectedRetailerName = _selectedRetailerName;
    if (selectedRetailerId == null || selectedRetailerName == null) {
      showCmsToast(
        context,
        'Please choose a retailer/mart first.',
        isError: true,
      );
      return;
    }

    final List<Map<String, dynamic>> allProducts =
        List<Map<String, dynamic>>.from(_currentProducts);
    final Map<String, double?> masterPrices = Map<String, double?>.of(
      _masterPrices,
    );
    final Object? loadedSheetStamp = _loaded.stamp;
    final bool onlyNewerProducts = _loaded.readsOnlyNewerProducts;
    final String requestedSheetName = _sheetNameController.text.trim();
    final List<_ScoreSheetItemDraft> sortedItems =
        List<_ScoreSheetItemDraft>.of(_draftItems.values)..sort(
          (_ScoreSheetItemDraft a, _ScoreSheetItemDraft b) =>
              a.sortOrder.compareTo(b.sortOrder),
        );

    final FirebaseFirestore firestore = FirebaseFirestore.instance;
    final DocumentReference<Map<String, dynamic>> defaultSheetReference =
        firestore.collection('score_sheets').doc('default');
    final DocumentReference<Map<String, dynamic>> retailerSettingsReference =
        firestore
            .collection('retailer_score_sheet_settings')
            .doc(selectedRetailerId);
    final bool writesDefaultSheet = _isAdminView;
    final bool writesPrices = _canEditPrices;
    late bool defaultSheetWasCreated;
    late bool retailerSettingsWereCreated;
    late Map<String, dynamic> defaultSheetData;
    late Map<String, dynamic> retailerSettingsData;
    bool sheetChangedSinceLoad = false;

    setState(() => _isSaving = true);
    try {
      Query<Map<String, dynamic>> productQuery = firestore.collection(
        'products',
      );
      if (onlyNewerProducts) {
        productQuery = productQuery.where(
          'createdAt',
          isGreaterThan: loadedSheetStamp,
        );
      }
      final QuerySnapshot<Map<String, dynamic>> freshSnapshot =
          await productQuery.get(const GetOptions(source: Source.server));
      final List<Map<String, dynamic>> freshProducts = <Map<String, dynamic>>[
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
            in freshSnapshot.docs)
          <String, dynamic>{...doc.data(), 'docId': doc.id},
      ];
      await firestore.runTransaction<void>((Transaction transaction) async {
        sheetChangedSinceLoad = false;
        final DocumentSnapshot<Map<String, dynamic>>? defaultSheetDocument =
            writesDefaultSheet
            ? await transaction.get(defaultSheetReference)
            : null;
        final DocumentSnapshot<Map<String, dynamic>> retailerSettingsDocument =
            await transaction.get(retailerSettingsReference);
        final Map<String, dynamic> existingDefaultSheet =
            defaultSheetDocument?.data() ?? <String, dynamic>{};
        final Map<String, dynamic> existingRetailerSettings =
            retailerSettingsDocument.data() ?? <String, dynamic>{};
        if (existingRetailerSettings['updatedAt'] != loadedSheetStamp) {
          sheetChangedSinceLoad = true;
          return;
        }

        final Set<String> selectedProductIds = sortedItems
            .map((_ScoreSheetItemDraft item) => item.productId)
            .toSet();
        final List<String> allProductIds = allProducts
            .map((Map<String, dynamic> product) => _productId(product))
            .where((String id) => id.isNotEmpty)
            .toList();
        final Set<String> currentProductAliases = allProducts
            .expand(_productIdentityAliases)
            .toSet();
        Set<String> retainedIds(Object? raw) => raw is List
            ? raw
                  .map((Object? value) => value.toString())
                  .where(
                    (String id) =>
                        id.isNotEmpty && !currentProductAliases.contains(id),
                  )
                  .toSet()
            : <String>{};

        final List<String> disabledProductIds = scoreSheetDisabledIds(
          retained: retainedIds(existingRetailerSettings['disabledProductIds']),
          allProductIds: allProductIds,
          selectedProductIds: selectedProductIds,
        );
        final List<String> hiddenProductIds = <String>{
          ...retainedIds(existingRetailerSettings['hiddenProductIds']),
          ...sortedItems
              .where((_ScoreSheetItemDraft item) => !item.isVisible)
              .map((_ScoreSheetItemDraft item) => item.productId),
        }.toList();
        final Set<String> savedVisibleIds = <String>{
          ...retainedIds(existingRetailerSettings['visibleProductIds']),
          ...sortedItems
              .where((_ScoreSheetItemDraft item) => item.isVisible)
              .map((_ScoreSheetItemDraft item) => item.productId),
        };
        final List<String> visibleProductIds = <String>{
          ...savedVisibleIds,
          ...scoreSheetUnseenProductsToKeep(
            freshProducts: freshProducts,
            shownIds: currentProductAliases,
            disabledIds: _storedIds(
              existingRetailerSettings['disabledProductIds'],
            ),
            hiddenIds: _storedIds(existingRetailerSettings['hiddenProductIds']),
            visibleIds: _storedIds(
              existingRetailerSettings['visibleProductIds'],
            ),
            savedVisibleIds: savedVisibleIds,
            sheetUpdatedAt: loadedSheetStamp,
          ),
        }.toList();

        final Object? rawOverrides =
            existingRetailerSettings['productOverrides'];
        final Map<String, dynamic> retainedOverrides = <String, dynamic>{};
        if (rawOverrides is Map) {
          retainedOverrides.addAll(Map<String, dynamic>.from(rawOverrides));
          retainedOverrides.removeWhere(
            (String key, dynamic _) => currentProductAliases.contains(key),
          );
        }
        final Map<String, dynamic> productOverrides = <String, dynamic>{
          ...retainedOverrides,
          for (final _ScoreSheetItemDraft item in sortedItems)
            item.productId: <String, dynamic>{
              'packingSize': item.packingSize,
              'barcode': item.barcode,
              'itemBarcode': item.barcode,
              if (_isRetailerPrice(
                item.unitPrice,
                masterPrices[item.productId],
              )) ...<String, dynamic>{
                'unitPrice': item.unitPrice,
                'price': item.unitPrice,
              },
              'sortOrder': item.sortOrder,
              'isVisible': item.isVisible,
            },
        };

        final Set<String> defaultProductIds = <String>{
          ...retainedIds(existingDefaultSheet['productIds']),
          ...allProductIds,
        };
        final Set<String> defaultVisibleProductIds = <String>{
          ...retainedIds(existingDefaultSheet['visibleProductIds']),
          ...allProductIds,
        };

        defaultSheetWasCreated = defaultSheetDocument?.exists == false;
        retailerSettingsWereCreated = !retailerSettingsDocument.exists;
        defaultSheetData = <String, dynamic>{
          'scoreSheetId': 'default',
          'sheetName': 'Default Score Sheet',
          ...existingDefaultSheet,
          'productIds': defaultProductIds.toList(),
          'visibleProductIds': defaultVisibleProductIds.toList(),
          'productCount': defaultProductIds.length,
          'visibleProductCount': defaultVisibleProductIds.length,
          'isDefault': true,
          'status': 'active',
        };
        final bool overridePriceChanged = retailerOverridePricesChanged(
          existingRetailerSettings['productOverrides'],
          <String, num?>{
            for (final _ScoreSheetItemDraft item in sortedItems)
              item.productId:
                  _isRetailerPrice(item.unitPrice, masterPrices[item.productId])
                  ? item.unitPrice
                  : null,
          },
        );
        retailerSettingsData = <String, dynamic>{
          ...existingRetailerSettings,
          ...priceStampFor(changed: writesPrices && overridePriceChanged),
          'retailerId': selectedRetailerId,
          'retailerName': selectedRetailerName,
          'scoreSheetId': 'default',
          'sheetName': requestedSheetName.isEmpty
              ? '$selectedRetailerName Score Sheet'
              : requestedSheetName,
          'disabledProductIds': disabledProductIds,
          'hiddenProductIds': hiddenProductIds,
          'visibleProductIds': visibleProductIds,
          if (writesPrices) 'productOverrides': productOverrides,
          'productCount': sortedItems.length,
          'visibleProductCount': visibleProductIds.length,
        };
        if (!writesPrices) {
          retailerSettingsData.remove('productOverrides');
        }

        if (writesDefaultSheet) {
          transaction.set(defaultSheetReference, <String, dynamic>{
            ...defaultSheetData,
            'updatedAt': FieldValue.serverTimestamp(),
            if (defaultSheetWasCreated)
              'createdAt': FieldValue.serverTimestamp(),
          });
        }
        transaction.set(retailerSettingsReference, <String, dynamic>{
          ...retailerSettingsData,
          'updatedAt': FieldValue.serverTimestamp(),
          if (retailerSettingsWereCreated)
            'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: !writesPrices));
      });

      if (sheetChangedSinceLoad) {
        if (!mounted) return;
        setState(() => _isSaving = false);
        await _reloadSelectedRetailer();
        if (!mounted) return;
        showCmsToast(
          context,
          "This retailer's sheet changed after you opened it, for example by a template assignment. The latest sheet is now shown. Make your changes again and save.",
          isError: true,
        );
        return;
      }

      if (writesDefaultSheet) {
        await _repository.recordDocumentUpsert(
          collectionName: 'score_sheets',
          isCreate: defaultSheetWasCreated,
          data: defaultSheetData,
          docId: 'default',
        );
      }
      await _repository.recordDocumentUpsert(
        collectionName: 'retailer_score_sheet_settings',
        isCreate: retailerSettingsWereCreated,
        data: retailerSettingsData,
        docId: selectedRetailerId,
      );

      if (!mounted) return;
      showCmsToast(
        context,
        'Retailer score sheet settings saved. Mobile app will pull from the master product catalogue.',
      );
      final Object? savedStamp;
      try {
        savedStamp = await _storedSheetStamp(selectedRetailerId);
      } on FirebaseException {
        return;
      }
      if (selectedRetailerId == _selectedRetailerId) {
        _loaded = _loaded.afterSave(
          stamp: savedStamp,
          savedVisibleIds: _storedIds(
            retailerSettingsData['visibleProductIds'],
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'save the score sheet settings'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String _productId(Map<String, dynamic> product) {
    return _readText(
      product,
      'docId',
      fallbackKeys: <String>[
        'productId',
        'itemId',
        'sku',
        'productCode',
        'itemCode',
        'barcode',
      ],
    );
  }

  String _productLabel(Map<String, dynamic> product) {
    final String name = _readText(
      product,
      'itemName',
      fallbackKeys: <String>['productName'],
      fallback: '-',
    );
    final String brand = _readText(
      product,
      'brandName',
      fallbackKeys: <String>['brand'],
    );
    return brand.isEmpty ? name : '$brand · $name';
  }

  List<String> _productIdentityAliases(Map<String, dynamic> product) {
    final List<String> identifiers = <String>[
      _productId(product),
      _readText(product, 'productId'),
      _readText(product, 'itemId'),
      _readText(product, 'sku'),
      _readText(product, 'productCode'),
      _readText(product, 'itemCode'),
      _readText(product, 'barcode'),
    ];
    return identifiers
        .where((String value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  Map<String, dynamic> _firstMapForKeys(
    Map<String, dynamic> source,
    List<String> keys,
  ) {
    for (final String key in keys) {
      final Object? value = source[key];
      if (value is Map) return Map<String, dynamic>.from(value);
    }
    return <String, dynamic>{};
  }

  String _productDedupeKey(Map<String, dynamic> product) {
    final String documentId = _readText(product, 'docId');
    if (documentId.isNotEmpty) return 'doc:$documentId';
    return 'product:${_productId(product)}';
  }

  int _productQualityScore(Map<String, dynamic> product) {
    int score = 0;
    final String docId = _readText(product, 'docId');
    final String productId = _readText(product, 'productId');
    final String barcode = _readText(
      product,
      'barcode',
      fallbackKeys: <String>['itemBarcode'],
    );
    if (docId.isNotEmpty && productId.isNotEmpty && docId == productId) {
      score += 500;
    }
    if (barcode.isNotEmpty &&
        barcode == barcode.replaceAll(RegExp(r'\s+'), '')) {
      score += 250;
    }
    if (_readText(product, 'categoryId').isNotEmpty) {
      score += 80;
    }
    if (_readText(product, 'departmentId').isNotEmpty) {
      score += 60;
    }
    if (_readText(product, 'productName').isNotEmpty) {
      score += 30;
    }
    if (_readText(product, 'itemName').isNotEmpty) {
      score += 25;
    }
    if (_readText(product, 'packingSize').isNotEmpty) {
      score += 20;
    }
    if (_readText(
      product,
      'unitPrice',
      fallbackKeys: <String>['price', 'priceGuide'],
    ).isNotEmpty) {
      score += 20;
    }
    if (product['isVisible'] != false &&
        '${product['status'] ?? ''}'.toLowerCase() != 'hidden') {
      score += 10;
    }
    return score;
  }

  List<Map<String, dynamic>> _dedupeProducts(
    List<Map<String, dynamic>> products,
  ) {
    final Map<String, Map<String, dynamic>> bestByKey =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> product in products) {
      final String key = _productDedupeKey(product);
      final Map<String, dynamic>? current = bestByKey[key];
      if (current == null ||
          _productQualityScore(product) > _productQualityScore(current)) {
        bestByKey[key] = product;
      }
    }
    return bestByKey.values.toList();
  }

  String _readText(
    Map<String, dynamic> row,
    String key, {
    List<String> fallbackKeys = const <String>[],
    String fallback = '',
  }) {
    for (final String currentKey in <String>[key, ...fallbackKeys]) {
      final String text = '${row[currentKey]}'.trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return fallback;
  }

  String _searchBlob(Map<String, dynamic> product) {
    return [
      product['retailerName'],
      product['departmentName'],
      product['mainCategoryName'],
      product['productName'],
      product['itemName'],
      product['productCode'],
      product['itemCode'],
      product['sku'],
      product['barcode'],
      product['itemBarcode'],
      product['packingSize'],
      product['brandName'],
      product['categoryName'],
      product['subCategoryName'],
    ].join(' ').toLowerCase();
  }

  int _productDisplayOrder(Map<String, dynamic> a, Map<String, dynamic> b) {
    final int department = _readText(
      a,
      'departmentName',
    ).compareTo(_readText(b, 'departmentName'));
    if (department != 0) return department;
    final int category = _readText(
      a,
      'mainCategoryName',
    ).compareTo(_readText(b, 'mainCategoryName'));
    if (category != 0) return category;
    return _readText(
      a,
      'itemName',
      fallbackKeys: <String>['productName'],
    ).compareTo(
      _readText(b, 'itemName', fallbackKeys: <String>['productName']),
    );
  }

  List<CataloguePreset<Map<String, dynamic>>> get _presets =>
      <CataloguePreset<Map<String, dynamic>>>[
        CataloguePreset<Map<String, dynamic>>(
          id: 'all',
          label: 'All products',
          test: (_) => true,
        ),
        CataloguePreset<Map<String, dynamic>>(
          id: 'selected',
          label: 'In score sheet',
          test: (Map<String, dynamic> product) =>
              _draftItems.containsKey(_productId(product)),
        ),
        CataloguePreset<Map<String, dynamic>>(
          id: 'visible',
          label: 'Visible on mobile',
          test: (Map<String, dynamic> product) =>
              _draftItems[_productId(product)]?.isVisible == true,
        ),
      ];

  List<CatalogueColumn<Map<String, dynamic>>> _columns() {
    String productCode(Map<String, dynamic> product) => _readText(
      product,
      'itemCode',
      fallbackKeys: <String>['productCode', 'sku'],
      fallback: '-',
    );

    String barcodeValue(Map<String, dynamic> product) {
      final String override = _draftItems[_productId(product)]?.barcode ?? '';
      return override.isNotEmpty
          ? override
          : _readText(
              product,
              'barcode',
              fallbackKeys: <String>['itemBarcode'],
              fallback: '-',
            );
    }

    String packingValue(Map<String, dynamic> product) {
      final String override =
          _draftItems[_productId(product)]?.packingSize ?? '';
      return override.isNotEmpty
          ? override
          : _readText(product, 'packingSize', fallback: '-');
    }

    return <CatalogueColumn<Map<String, dynamic>>>[
      CatalogueColumn<Map<String, dynamic>>(
        id: 'product',
        label: 'Product',
        width: 230,
        flex: 3,
        hideable: false,
        cell: (BuildContext context, Map<String, dynamic> product) => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _productLabel(product),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.dso.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              productCode(product),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: context.dso.muted),
            ),
          ],
        ),
      ),
      CatalogueColumn<Map<String, dynamic>>(
        id: 'included',
        label: 'In sheet',
        width: 82,
        hideable: false,
        interactive: true,
        cell: (BuildContext context, Map<String, dynamic> product) {
          final bool selected = _draftItems.containsKey(_productId(product));
          final bool enabled = !_overrideDrawerOpen && _canWriteSheet;
          return Semantics(
            container: true,
            excludeSemantics: true,
            label: 'Select ${_productLabel(product)}',
            checked: selected,
            enabled: enabled,
            onTap: enabled ? () => _toggleProduct(product, !selected) : null,
            child: Checkbox(
              value: selected,
              onChanged: enabled
                  ? (bool? value) {
                      _toggleProduct(product, value ?? false);
                    }
                  : null,
            ),
          );
        },
      ),
      CatalogueColumn<Map<String, dynamic>>(
        id: 'barcode',
        label: 'Barcode',
        width: 135,
        cell: (BuildContext context, Map<String, dynamic> product) => Text(
          barcodeValue(product),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      CatalogueColumn<Map<String, dynamic>>(
        id: 'packing',
        label: 'Packing size',
        width: 115,
        cell: (BuildContext context, Map<String, dynamic> product) => Text(
          packingValue(product),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      CatalogueColumn<Map<String, dynamic>>(
        id: 'price',
        label: 'Price',
        width: 100,
        numeric: true,
        cell: (BuildContext context, Map<String, dynamic> product) {
          final _ScoreSheetItemDraft? draft = _draftItems[_productId(product)];
          return Text(
            'RM ${draft?.unitPrice ?? product['unitPrice'] ?? product['priceGuide'] ?? 0}',
          );
        },
      ),
      CatalogueColumn<Map<String, dynamic>>(
        id: 'category',
        label: 'Department / category',
        width: 205,
        flex: 2,
        cell: (BuildContext context, Map<String, dynamic> product) => Text(
          "${_readText(product, 'departmentName', fallback: '-')} → "
          "${_readText(product, 'mainCategoryName', fallbackKeys: <String>['categoryName'], fallback: '-')}",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      CatalogueColumn<Map<String, dynamic>>(
        id: 'visibility',
        label: 'Mobile',
        width: 105,
        hideable: false,
        interactive: true,
        cell: (BuildContext context, Map<String, dynamic> product) {
          final String productId = _productId(product);
          final _ScoreSheetItemDraft? draft = _draftItems[productId];
          final bool visible = draft?.isVisible ?? false;
          final bool enabled =
              draft != null &&
              !_overrideDrawerOpen &&
              !_isSaving &&
              _canWriteSheet;
          void setVisible(bool value) {
            setState(() {
              _draftItems[productId] = draft!.copyWith(isVisible: value);
            });
          }

          return Semantics(
            container: true,
            excludeSemantics: true,
            label: 'Show on mobile for ${_productLabel(product)}',
            toggled: visible,
            enabled: enabled,
            onTap: enabled ? () => setVisible(!visible) : null,
            child: Switch(
              value: visible,
              onChanged: enabled ? setVisible : null,
            ),
          );
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!_densityDefaulted) {
      _densityDefaulted = true;
      _view.density = MediaQuery.sizeOf(context).width < 900
          ? CatalogueDensity.comfortable
          : CatalogueDensity.compact;
    }

    return ValueListenableBuilder<PermissionPolicy>(
      valueListenable: PermissionPolicyService.instance.policy,
      builder: (BuildContext context, PermissionPolicy _, Widget? child) =>
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: operationalRetailerStream(
              _repository.watchCollection('retailers', orderBy: 'retailerName'),
            ),
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, dynamic>>> retailerSnapshot,
                ) => ListenableBuilder(
                  listenable: _view,
                  builder: (BuildContext context, Widget? child) {
                    final List<Map<String, dynamic>> retailers =
                        retailerSnapshot.data ?? <Map<String, dynamic>>[];
                    return _buildWorkspace(
                      context,
                      retailerSnapshot,
                      retailers,
                    );
                  },
                ),
          ),
    );
  }

  Widget _buildWorkspace(
    BuildContext context,
    AsyncSnapshot<List<Map<String, dynamic>>> retailerSnapshot,
    List<Map<String, dynamic>> retailers,
  ) {
    final List<CatalogueColumn<Map<String, dynamic>>> columns = _columns();
    final List<Map<String, dynamic>> products = _view.apply(
      List<Map<String, dynamic>>.from(_currentProducts),
      idOf: _productId,
      searchBlob: _searchBlob,
      filterValue: <String, String Function(Map<String, dynamic>)>{},
      columns: columns,
      defaultSort: _productDisplayOrder,
      presets: _presets,
    );
    final int visibleCount = _draftItems.values
        .where((_ScoreSheetItemDraft item) => item.isVisible)
        .length;
    final List<Map<String, dynamic>> pickable = _pickableRetailers(retailers);

    return CatalogueWorkspace(
      title: 'Retailer Score Sheets',
      subtitle: _canWriteSheet || _selectedRetailerId == null
          ? 'Configure product selection and mobile visibility by retailer.'
          : 'View only. An admin can allow you to edit score sheets of your '
                'own salespeople in Role Permissions.',
      viewSwitcher: <Widget>[_salespersonPicker(), _retailerPicker(pickable)],
      issues: _selectedRetailerId == null
          ? const <CatalogueIssueCount>[]
          : <CatalogueIssueCount>[
              CatalogueIssueCount(
                label: 'In score sheet',
                count: _draftItems.length,
                active: _view.presetId == 'selected',
                onTap: () => _view.setPreset(
                  _view.presetId == 'selected' ? 'all' : 'selected',
                ),
              ),
              CatalogueIssueCount(
                label: 'Visible on mobile',
                count: visibleCount,
                active: _view.presetId == 'visible',
                onTap: () => _view.setPreset(
                  _view.presetId == 'visible' ? 'all' : 'visible',
                ),
              ),
            ],
      primaryAction: _selectedRetailerId == null || !_canWriteSheet
          ? null
          : FilledButton.icon(
              onPressed:
                  _isLoadingExistingSheet || _overrideDrawerOpen || _isSaving
                  ? null
                  : _saveScoreSheet,
              icon: const Icon(ScootIcons.check, size: 18),
              label: const Text('Save sheet'),
            ),
      secondaryActions: <Widget>[
        if (_isAdminView)
          OutlinedButton.icon(
            onPressed: _overrideDrawerOpen || _isSaving ? null : _toggleLibrary,
            icon: Icon(
              _libraryOpen ? ScootIcons.back : ScootIcons.document,
              size: 16,
            ),
            label: Text(_libraryOpen ? 'Back to sheet' : 'Template library'),
          ),
        if (_selectedRetailerId != null &&
            !_libraryOpen &&
            _canWriteSheet) ...<Widget>[
          OutlinedButton.icon(
            onPressed: _overrideDrawerOpen || _isSaving || products.isEmpty
                ? null
                : () => _toggleAllShownProducts(products),
            icon: Icon(
              _allShownProductsSelected(products)
                  ? ScootIcons.remove
                  : ScootIcons.check,
              size: 16,
            ),
            label: Text(
              _allShownProductsSelected(products)
                  ? 'Deselect all'
                  : 'Select all',
            ),
          ),
          OutlinedButton.icon(
            onPressed: _overrideDrawerOpen || _isSaving || _draftItems.isEmpty
                ? null
                : () => _toggleVisibleForSelectedShown(products),
            icon: Icon(
              _selectedShownProductsAllHidden(products)
                  ? ScootIcons.play
                  : ScootIcons.paused,
              size: 16,
            ),
            label: Text(
              _selectedShownProductsAllHidden(products)
                  ? 'Show selected'
                  : 'Hide selected',
            ),
          ),
        ],
      ],
      toolbar: _libraryOpen
          ? const SizedBox.shrink()
          : CatalogueToolbar<Map<String, dynamic>>(
              search: _searchController,
              searchFocus: _searchFocus,
              searchHint: 'Search products, codes, barcodes',
              filters: const <CatalogueFilterMenu>[],
              presets: _presets,
              presetId: _view.presetId,
              onPreset: _view.setPreset,
              columns: columns,
              hiddenColumnIds: _view.hiddenColumnIds,
              onColumns: _view.setHiddenColumns,
              density: _view.density,
              onDensity: _view.setDensity,
              hasActiveFilters:
                  _view.hasActiveFilters || _view.query.isNotEmpty,
              resultSummary:
                  'Showing ${products.length} of ${_currentProducts.length}${_view.showingCloseMatches ? ' · no exact match, showing close spellings' : ''}',
              onClearFilters: () {
                _searchController.clear();
                _view.clearFilters();
              },
            ),
      body: _libraryOpen && _isAdminView
          ? ScoreSheetTemplateLibrary(
              retailers: retailers,
              currentProductIds:
                  _selectedRetailerId == null || _isLoadingExistingSheet
                  ? null
                  : _draftItems.values
                        .where((_ScoreSheetItemDraft item) => item.isVisible)
                        .map((_ScoreSheetItemDraft item) => item.productId)
                        .toList(growable: false),
              currentRetailerId: _selectedRetailerId ?? '',
              currentRetailerName: _selectedRetailerName ?? '',
            )
          : AbsorbPointer(
              absorbing: _isSaving,
              child: _buildProductBody(
                retailerSnapshot,
                pickable,
                products,
                columns,
              ),
            ),
      drawerOpen: _overrideDrawerOpen,
      onCloseDrawer: _requestCloseOverrideDrawer,
      drawer: _overrideDrawerOpen && _editingProduct != null
          ? CatalogueDrawer(
              title: 'Score sheet product settings',
              dirty: _overrideDirty,
              onClose: _closeOverrideDrawer,
              body: _buildOverrideForm(),
              footer: <Widget>[
                TextButton(
                  onPressed: _requestCloseOverrideDrawer,
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _applyProductOverride,
                  child: const Text('Apply'),
                ),
              ],
            )
          : null,
    );
  }

  List<Map<String, dynamic>> _pickableRetailers(
    List<Map<String, dynamic>> retailers,
  ) {
    if (_salespersonCode.isNotEmpty) {
      return retailers
          .where(
            (Map<String, dynamic> retailer) =>
                retailerAssignedToCode(retailer, _salespersonCode) &&
                retailerInActorScope(widget.currentUser, retailer),
          )
          .toList(growable: false);
    }
    return _isAdminView ? retailers : <Map<String, dynamic>>[];
  }

  Widget _salespersonPicker() {
    final bool selectedExists = _salespeople.any(
      (_Salesperson person) => person.code == _salespersonCode,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ExcludeSemantics(
          child: Text(
            'Salesperson',
            style: TextStyle(
              fontSize: DsoFilterMetrics.fontSize,
              fontWeight: FontWeight.w600,
              color: context.dso.body,
            ),
          ),
        ),
        const SizedBox(width: DsoFilterMetrics.gap),
        Flexible(
          child: SizedBox(
            width: 240,
            height: DsoFilterMetrics.height,
            child: Semantics(
              label: 'Salesperson',
              container: true,
              child: !_salespeopleLoaded
                  ? InputDecorator(
                      decoration: dsoFilterDropdownDecoration(context),
                      child: Text(
                        'Loading salespeople',
                        style: TextStyle(
                          fontSize: DsoFilterMetrics.fontSize,
                          color: context.dso.body,
                        ),
                      ),
                    )
                  : InputDecorator(
                      decoration: dsoFilterDropdownDecoration(context),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          style: TextStyle(
                            fontSize: DsoFilterMetrics.fontSize,
                            color: context.dso.body,
                          ),
                          value: selectedExists ? _salespersonCode : '',
                          isExpanded: true,
                          items: <DropdownMenuItem<String>>[
                            DropdownMenuItem<String>(
                              value: '',
                              child: Text(
                                _isAdminView
                                    ? 'All salespeople'
                                    : 'Choose salesperson',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            for (final _Salesperson person in _salespeople)
                              DropdownMenuItem<String>(
                                value: person.code,
                                child: Text(
                                  person.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _isSaving
                              ? null
                              : (String? value) =>
                                    _pickSalesperson(value ?? ''),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 16),
      ],
    );
  }

  Widget _retailerPicker(List<Map<String, dynamic>> retailers) {
    final bool selectedExists = retailers.any(
      (Map<String, dynamic> retailer) =>
          _readText(retailer, 'retailerId', fallbackKeys: <String>['docId']) ==
          _selectedRetailerId,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ExcludeSemantics(
          child: Text(
            'Retailer',
            style: TextStyle(
              fontSize: DsoFilterMetrics.fontSize,
              fontWeight: FontWeight.w600,
              color: context.dso.body,
            ),
          ),
        ),
        const SizedBox(width: DsoFilterMetrics.gap),
        Flexible(child: _retailerDropdown(retailers, selectedExists)),
      ],
    );
  }

  Widget _retailerDropdown(
    List<Map<String, dynamic>> retailers,
    bool selectedExists,
  ) {
    return SizedBox(
      width: 320,
      height: DsoFilterMetrics.height,
      child: Semantics(
        label: 'Retailer',
        container: true,
        child: InputDecorator(
          decoration: dsoFilterDropdownDecoration(context),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              style: TextStyle(
                fontSize: DsoFilterMetrics.fontSize,
                color: context.dso.body,
              ),
              value: selectedExists ? _selectedRetailerId : null,
              isExpanded: true,
              hint: const Text('Choose retailer'),
              items: retailers.map((Map<String, dynamic> retailer) {
                final String id = _readText(
                  retailer,
                  'retailerId',
                  fallbackKeys: <String>['docId'],
                );
                return DropdownMenuItem<String>(
                  value: id,
                  child: Text(
                    _readText(
                      retailer,
                      'retailerName',
                      fallbackKeys: <String>['name'],
                      fallback: '-',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: retailers.isEmpty || _isSaving
                  ? null
                  : (String? value) {
                      if (value == null) return;
                      final Map<String, dynamic> retailer = retailers
                          .firstWhere(
                            (Map<String, dynamic> candidate) =>
                                _readText(
                                  candidate,
                                  'retailerId',
                                  fallbackKeys: <String>['docId'],
                                ) ==
                                value,
                          );
                      _selectRetailer(retailer);
                    },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProductBody(
    AsyncSnapshot<List<Map<String, dynamic>>> retailerSnapshot,
    List<Map<String, dynamic>> retailers,
    List<Map<String, dynamic>> products,
    List<CatalogueColumn<Map<String, dynamic>>> columns,
  ) {
    if (retailerSnapshot.hasError) {
      return CatalogueError(
        message: userFacingError(
          retailerSnapshot.error!,
          action: 'load retailers',
        ),
      );
    }
    if (retailerSnapshot.connectionState == ConnectionState.waiting &&
        !retailerSnapshot.hasData) {
      return const CatalogueLoading();
    }
    if (retailers.isEmpty) {
      if (_salespersonCode.isEmpty && !_isAdminView) {
        return const CatalogueEmpty(
          title: 'Choose a salesperson',
          message: 'Choose a salesperson to see the shops assigned to them.',
        );
      }
      if (_salespersonCode.isNotEmpty) {
        return const CatalogueEmpty(
          title: 'No shops assigned',
          message: 'This salesperson has no assigned shops yet.',
        );
      }
      return const CatalogueEmpty(
        title: 'No retailers found',
        message: 'Add a retailer before configuring its score sheet.',
      );
    }
    if (_selectedRetailerId == null) {
      return const CatalogueEmpty(
        title: 'Select a retailer',
        message: 'Choose a retailer to configure its product score sheet.',
      );
    }
    if (_isLoadingExistingSheet) return const CatalogueLoading();
    if (_currentProducts.isEmpty) {
      return const CatalogueEmpty(
        title: 'No products found',
        message: 'The eligible master catalogue has no products to assign.',
      );
    }
    if (products.isEmpty) {
      return CatalogueNoResults(
        onClear: () {
          _searchController.clear();
          _view.clearFilters();
        },
      );
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            width: 360,
            child: TextField(
              controller: _sheetNameController,
              enabled: _canWriteSheet,
              decoration: const InputDecoration(
                labelText: 'Score sheet name',
                isDense: true,
              ),
            ),
          ),
        ),
        Expanded(
          child: CatalogueTable<Map<String, dynamic>>(
            rows: products,
            idOf: _productId,
            labelOf: (Map<String, dynamic> product) {
              final String productId = _productId(product);
              final _ScoreSheetItemDraft? draft = _draftItems[productId];
              return '${_productLabel(product)}, '
                  '${draft == null ? 'not selected' : 'selected'}, '
                  '${draft?.isVisible == true ? 'visible on mobile' : 'hidden on mobile'}';
            },
            columns: columns,
            state: _view,
            groupOf: (Map<String, dynamic> product) =>
                _readText(product, 'departmentName'),
            semanticsLabelPrefix: 'Product',
            selectable: false,
            rowActions: (Map<String, dynamic> product) =>
                !_overrideDrawerOpen &&
                    _canWriteSheet &&
                    _draftItems.containsKey(_productId(product))
                ? <CatalogueRowAction<Map<String, dynamic>>>[
                    CatalogueRowAction<Map<String, dynamic>>(
                      label: 'Settings',
                      icon: ScootIcons.settings,
                      onPressed: _openProductOverride,
                    ),
                  ]
                : const <CatalogueRowAction<Map<String, dynamic>>>[],
          ),
        ),
      ],
    );
  }

  Widget _buildOverrideForm() {
    final Map<String, dynamic> product = _editingProduct!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          _readText(
            product,
            'itemName',
            fallbackKeys: <String>['productName'],
            fallback: '-',
          ),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: context.dso.ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'These values stay in the retailer draft until you save the sheet.',
          style: TextStyle(fontSize: 13, color: context.dso.muted),
        ),
        const SizedBox(height: 18),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _overrideVisible,
          onChanged: (bool value) => setState(() => _overrideVisible = value),
          title: const Text('Visible in salesman mobile score sheet'),
        ),
        if (_canEditPrices) ...<Widget>[
          const SizedBox(height: 10),
          TextField(
            controller: _packingController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Packing Size Override',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _barcodeController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Barcode Override'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _priceController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Unit Price Override'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _sortController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Sort Order'),
          ),
        ],
      ],
    );
  }
}

class ScoreSheetLoadedState {
  const ScoreSheetLoadedState({required this.stamp, required this.visibleIds});

  final Object? stamp;
  final Set<String> visibleIds;

  bool get readsOnlyNewerProducts =>
      stamp is Timestamp && visibleIds.isNotEmpty;

  ScoreSheetLoadedState afterSave({
    required Object? stamp,
    required Set<String> savedVisibleIds,
  }) => ScoreSheetLoadedState(stamp: stamp, visibleIds: savedVisibleIds);
}

bool scoreSheetProductLoadsTicked({
  required List<String> aliases,
  required Set<String> disabledIds,
  required Set<String> hiddenIds,
  required Set<String> visibleIds,
  required Object? createdAt,
  required Object? sheetUpdatedAt,
}) {
  if (aliases.any(disabledIds.contains)) return false;
  if (aliases.any(hiddenIds.contains)) return true;
  if (visibleIds.isEmpty || aliases.any(visibleIds.contains)) return true;
  return createdAt is Timestamp &&
      sheetUpdatedAt is Timestamp &&
      createdAt.compareTo(sheetUpdatedAt) > 0;
}

List<String> scoreSheetDisabledIds({
  required Set<String> retained,
  required List<String> allProductIds,
  required Set<String> selectedProductIds,
}) => <String>{
  ...retained,
  ...allProductIds.where(
    (String productId) => !selectedProductIds.contains(productId),
  ),
}.toList();

Set<String> _storedIds(Object? raw) => raw is List
    ? raw.map((Object? value) => value.toString()).toSet()
    : <String>{};

List<String> scoreSheetUnseenProductsToKeep({
  required Iterable<Map<String, dynamic>> freshProducts,
  required Set<String> shownIds,
  required Set<String> disabledIds,
  required Set<String> hiddenIds,
  required Set<String> visibleIds,
  required Set<String> savedVisibleIds,
  required Object? sheetUpdatedAt,
}) {
  if (savedVisibleIds.isEmpty) return <String>[];
  final List<String> kept = <String>[];
  for (final Map<String, dynamic> product in freshProducts) {
    final String id = '${product['docId'] ?? ''}'.trim();
    if (id.isEmpty ||
        shownIds.contains(id) ||
        disabledIds.contains(id) ||
        hiddenIds.contains(id) ||
        isDemoProductRecord(product)) {
      continue;
    }
    final Object? createdAt = product['createdAt'];
    final bool createdAfterSheet =
        createdAt is Timestamp &&
        sheetUpdatedAt is Timestamp &&
        createdAt.compareTo(sheetUpdatedAt) > 0;
    if (visibleIds.isEmpty || createdAfterSheet) kept.add(id);
  }
  return kept;
}

bool _isRetailerPrice(double? price, double? masterPrice) {
  if (price == null) return false;
  if (masterPrice == null) return true;
  return (price * 100).round() != (masterPrice * 100).round();
}

class _ScoreSheetItemDraft {
  const _ScoreSheetItemDraft({
    required this.productId,
    this.productName = '',
    this.productCode = '',
    this.categoryName = '',
    this.subCategoryName = '',
    this.packingSize = '',
    this.barcode = '',
    this.unitPrice,
    this.sortOrder = 0,
    this.isVisible = true,
  });

  final String productId;
  final String productName;
  final String productCode;
  final String categoryName;
  final String subCategoryName;
  final String packingSize;
  final String barcode;
  final double? unitPrice;
  final int sortOrder;
  final bool isVisible;

  factory _ScoreSheetItemDraft.fromProduct(Map<String, dynamic> product) {
    return _ScoreSheetItemDraft(
      productId:
          '${product['docId'] ?? product['productId'] ?? product['itemId'] ?? product['sku'] ?? product['productCode'] ?? product['itemCode'] ?? product['barcode'] ?? ''}',
      productName: '${product['productName'] ?? product['itemName'] ?? ''}',
      productCode:
          '${product['productCode'] ?? product['itemCode'] ?? product['sku'] ?? ''}',
      categoryName:
          '${product['mainCategoryName'] ?? product['categoryName'] ?? ''}',
      subCategoryName: '${product['subCategoryName'] ?? ''}',
      packingSize: '${product['packingSize'] ?? ''}',
      barcode: '${product['barcode'] ?? product['itemBarcode'] ?? ''}',
      unitPrice:
          dataNumberOrNull(product['unitPrice']) ??
          dataNumberOrNull(product['priceGuide']),
      sortOrder: product['sortOrder'] is int
          ? product['sortOrder'] as int
          : (product['position'] is int ? product['position'] as int : 0),
      isVisible: true,
    );
  }

  _ScoreSheetItemDraft copyWith({
    String? productName,
    String? productCode,
    String? categoryName,
    String? subCategoryName,
    String? packingSize,
    String? barcode,
    double? unitPrice,
    int? sortOrder,
    bool? isVisible,
  }) {
    return _ScoreSheetItemDraft(
      productId: productId,
      productName: productName ?? this.productName,
      productCode: productCode ?? this.productCode,
      categoryName: categoryName ?? this.categoryName,
      subCategoryName: subCategoryName ?? this.subCategoryName,
      packingSize: packingSize ?? this.packingSize,
      barcode: barcode ?? this.barcode,
      unitPrice: unitPrice ?? this.unitPrice,
      sortOrder: sortOrder ?? this.sortOrder,
      isVisible: isVisible ?? this.isVisible,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'productId': productId,
      'productName': productName,
      'productCode': productCode,
      'categoryName': categoryName,
      'mainCategoryName': categoryName,
      'subCategoryName': subCategoryName,
      'packingSize': packingSize,
      'barcode': barcode,
      'unitPrice': unitPrice,
      'sortOrder': sortOrder,
      'isVisible': isVisible,
    };
  }
}

class _Salesperson {
  const _Salesperson({required this.code, required this.name});

  final String code;
  final String name;
}
