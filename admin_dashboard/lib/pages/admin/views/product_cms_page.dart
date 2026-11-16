import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../app/permission_policy.dart';
import '../../../app_runtime.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/catalogue_product_repository.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/csv_downloader.dart';
import '../../../services/dashboard_preferences_service.dart';
import '../../../services/permission_policy_service.dart';
import '../../../services/platform_api_client.dart' show PlatformApiException;
import '../../../theme/dso_theme.dart';
import '../../../utils/catalogue_import.dart';
import '../../../utils/catalogue_product_availability.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/price_stamp.dart';
import '../../../utils/quantity_unit.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../../../widgets/confirm_destructive_dialog.dart';
import '../../../widgets/catalogue/catalogue_bulk_bar.dart';
import '../../../widgets/catalogue/catalogue_column.dart';
import '../../../widgets/catalogue/catalogue_csv.dart';
import '../../../widgets/catalogue/catalogue_drawer.dart';
import '../../../widgets/catalogue/catalogue_issue_count.dart';
import '../../../widgets/catalogue/catalogue_shortcuts.dart';
import '../../../widgets/catalogue/catalogue_states.dart';
import '../../../widgets/catalogue/catalogue_status_pill.dart';
import '../../../widgets/catalogue/catalogue_table.dart';
import '../../../widgets/catalogue/catalogue_toolbar.dart';
import '../../../widgets/catalogue/catalogue_view_state.dart';
import '../../../widgets/catalogue/catalogue_workspace.dart';
import '../widgets/cms_form_widgets.dart';
import '../../../utils/money_format.dart';

typedef _Row = Map<String, dynamic>;

class ProductCmsPage extends StatefulWidget {
  const ProductCmsPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<ProductCmsPage> createState() => _ProductCmsPageState();
}

class _ProductCmsPageState extends State<ProductCmsPage>
    with WidgetsBindingObserver {
  static const String _pageKey = 'product';
  static const int _maxBulkWrites =
      CatalogueProductRepository.maxAvailabilityChanges;

  final CmsRepository _repository = CmsRepository();
  final CatalogueProductRepository _catalogueRepository =
      CatalogueProductRepository();
  final CatalogueViewState<_Row> _view = CatalogueViewState<_Row>();
  final FocusNode _searchFocus = FocusNode();
  final GlobalKey<CatalogueToolbarState<_Row>> _toolbarKey =
      GlobalKey<CatalogueToolbarState<_Row>>();

  final TextEditingController _searchController = TextEditingController();
  String? _queryBeforeResize;
  Timer? _resizeRestoreTimer;
  bool _restoringSearchAfterResize = false;
  final TextEditingController _departmentController = TextEditingController();
  final TextEditingController _departmentManagerController =
      TextEditingController();
  final TextEditingController _mainCategoryController = TextEditingController();
  final TextEditingController _itemNameController = TextEditingController();
  final TextEditingController _brandNameController = TextEditingController();
  final TextEditingController _itemCodeController = TextEditingController();
  final TextEditingController _barcodeController = TextEditingController();
  final TextEditingController _packingSizeController = TextEditingController();
  final TextEditingController _uomController = TextEditingController(
    text: 'ctn',
  );
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _sortOrderController = TextEditingController(
    text: '0',
  );
  final TextEditingController _maxOrderQtyController = TextEditingController(
    text: '$defaultMaxQtyPerLine',
  );

  late Stream<List<_Row>> _stream = _watchProducts();
  String? _editingId;
  bool _isVisible = true;

  bool _loadedVisible = true;
  double? _loadedPrice;
  double? _loadedPriceGuide;
  double? _loadedPriceField;
  bool _companyUsesBarcodes = false;
  bool _drawerOpen = false;
  bool _saving = false;
  String _formSnapshot = '';
  bool _bulkBusy = false;
  bool _densityDefaulted = false;
  List<String> _visibleIds = <String>[];
  Timer? _saveViewTimer;
  String _savedViewSignature = '';

  Stream<List<_Row>> _watchProducts() =>
      _repository.watchCollection('products', orderBy: 'departmentName');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _view.hiddenColumnIds = <String>{
      for (final CatalogueColumn<_Row> c in _columns())
        if (!c.visibleByDefault) c.id,
    };
    _searchController.addListener(_handleSearchChanged);
    _view.addListener(_onViewChanged);
    _loadSavedView();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resizeRestoreTimer?.cancel();
    if (_saveViewTimer?.isActive ?? false) {
      _saveViewTimer!.cancel();
      unawaited(_saveView());
    }
    _view.dispose();
    _searchFocus.dispose();
    _searchController.dispose();
    _departmentController.dispose();
    _departmentManagerController.dispose();
    _mainCategoryController.dispose();
    _itemNameController.dispose();
    _brandNameController.dispose();
    _itemCodeController.dispose();
    _barcodeController.dispose();
    _packingSizeController.dispose();
    _uomController.dispose();
    _priceController.dispose();
    _sortOrderController.dispose();
    _maxOrderQtyController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final String query = _searchController.text;
    debugPrint(
      'E2E_RESIZE_METRICS|query=$query|focus=${_searchFocus.hasFocus}',
    );
    if (query.isEmpty) return;
    _queryBeforeResize = query;
    _resizeRestoreTimer?.cancel();
    _resizeRestoreTimer = Timer(const Duration(milliseconds: 750), () {
      _queryBeforeResize = null;
    });
  }

  void _handleSearchChanged() {
    final String query = _searchController.text;
    final String? previous = _queryBeforeResize;
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool userPressedDelete =
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.backspace) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.delete);
    if (_restoringSearchAfterResize) {
      _view.setQuery(query);
      return;
    }
    debugPrint(
      'E2E_RESIZE_SEARCH|query=$query|saved=$previous|focus=${_searchFocus.hasFocus}',
    );
    if (query.isEmpty &&
        previous != null &&
        (_resizeRestoreTimer?.isActive ?? false) &&
        !userPressedDelete) {
      debugPrint('E2E_RESIZE_RESTORE|query=$previous');
      _restoringSearchAfterResize = true;
      _searchController.value = TextEditingValue(
        text: previous,
        selection: TextSelection.collapsed(offset: previous.length),
      );
      _restoringSearchAfterResize = false;
      return;
    }
    if (query.isEmpty && userPressedDelete) _clearSearchRestore();
    if (query.isNotEmpty) _clearSearchRestore();
    _view.setQuery(query);
  }

  void _clearSearchRestore() {
    _queryBeforeResize = null;
    _resizeRestoreTimer?.cancel();
    _resizeRestoreTimer = null;
  }

  void _clearSearch() {
    _clearSearchRestore();
    _searchController.clear();
  }

  String? get _uid {
    if (!AppRuntime.firebaseReady) return null;
    try {
      final String uid =
          FirebaseAuth.instance.currentUser?.uid ??
          widget.currentUser.uid ??
          '';
      return uid.isEmpty ? null : uid;
    } catch (_) {
      return null;
    }
  }

  String _viewSignature() =>
      '${_view.density.name}|${(_view.hiddenColumnIds.toList()..sort()).join(',')}';

  Future<void> _loadSavedView() async {
    final String? uid = _uid;
    if (uid == null) return;
    try {
      final Map<String, dynamic> saved = await DashboardPreferencesService()
          .loadCatalogueView(uid, _pageKey);
      if (!mounted || saved.isEmpty) return;
      final Object? density = saved['density'];
      final Object? hidden = saved['hiddenColumns'];
      if (density is String) {
        for (final CatalogueDensity d in CatalogueDensity.values) {
          if (d.name == density) _view.density = d;
        }
      }
      if (hidden is List) {
        _view.hiddenColumnIds = hidden.map((Object? e) => '$e').toSet();
      }
      _savedViewSignature = _viewSignature();
      _view.setPreset(_view.presetId);
    } catch (_) {}
  }

  void _onViewChanged() {
    if (_viewSignature() == _savedViewSignature) return;
    _saveViewTimer?.cancel();
    _saveViewTimer = Timer(const Duration(milliseconds: 800), _saveView);
  }

  Future<void> _saveView() async {
    final String? uid = _uid;
    if (uid == null) return;
    final String signature = _viewSignature();
    try {
      await DashboardPreferencesService()
          .saveCatalogueView(uid, _pageKey, <String, dynamic>{
            'density': _view.density.name,
            'hiddenColumns': _view.hiddenColumnIds.toList()..sort(),
          });
      _savedViewSignature = signature;
    } catch (_) {}
  }

  bool _allowed(PermissionAction action) => PermissionPolicyService.instance
      .cachedAllows(widget.currentUser.role, 'products', action);

  String _formSignature() => <String>[
    _departmentController.text,
    _departmentManagerController.text,
    _mainCategoryController.text,
    _itemNameController.text,
    _brandNameController.text,
    _itemCodeController.text,
    _barcodeController.text,
    _packingSizeController.text,
    _uomController.text,
    _priceController.text,
    _sortOrderController.text,
    _maxOrderQtyController.text,
    '$_isVisible',
  ].join('\u0000');

  bool get _dirty => _drawerOpen && _formSignature() != _formSnapshot;

  void _fillForm(_Row? product) {
    setState(() {
      if (product == null) {
        _resetFields();
      } else {
        _editingId = '${product['docId'] ?? ''}';
        _departmentController.text = _readText(product, 'departmentName');
        _departmentManagerController.text = _readText(
          product,
          'departmentManagerName',
        );
        _mainCategoryController.text = _readText(product, 'mainCategoryName');
        _itemNameController.text = _readText(
          product,
          'productFlavor',
          fallbackKeys: <String>['flavor', 'itemName', 'productName'],
        );
        _brandNameController.text = _readText(
          product,
          'brandName',
          fallbackKeys: <String>['brand'],
        );
        _itemCodeController.text = _readText(
          product,
          'itemCode',
          fallbackKeys: <String>['productCode', 'sku'],
        );
        _barcodeController.text = _readText(
          product,
          'barcode',
          fallbackKeys: <String>['itemBarcode'],
        );
        _packingSizeController.text = _readText(product, 'packingSize');
        _uomController.text = _readText(
          product,
          'uom',
          fallbackKeys: <String>['uomLabel', 'unitOfMeasure'],
          fallback: 'ctn',
        );
        final double loadedUnitPrice = cataloguePriceOf(product);
        _priceController.text =
            product.containsKey('unitPrice') ||
                product.containsKey('price') ||
                product.containsKey('priceGuide')
            ? '$loadedUnitPrice'
            : '';
        _sortOrderController.text = _readText(
          product,
          'sortOrder',
          fallback: '0',
        );
        _maxOrderQtyController.text = '${maxQtyFor(product)}';
        _isVisible = isCatalogueProductVisible(product);
        _loadedPrice = parseCataloguePrice('${product['unitPrice'] ?? ''}');
        _loadedPriceGuide = parseCataloguePrice(
          '${product['priceGuide'] ?? ''}',
        );
        _loadedPriceField = parseCataloguePrice('${product['price'] ?? ''}');
      }
      _loadedVisible = _isVisible;
      _drawerOpen = true;
      _formSnapshot = _formSignature();
    });
  }

  void _resetFields() {
    _editingId = null;
    _departmentController.clear();
    _departmentManagerController.clear();
    _mainCategoryController.clear();
    _itemNameController.clear();
    _brandNameController.clear();
    _itemCodeController.clear();
    _barcodeController.clear();
    _packingSizeController.clear();
    _uomController.text = 'ctn';
    _priceController.clear();
    _sortOrderController.text = '0';
    _maxOrderQtyController.text = '$defaultMaxQtyPerLine';
    _isVisible = true;
    _loadedVisible = true;
    _loadedPrice = null;
    _loadedPriceGuide = null;
    _loadedPriceField = null;
  }

  void _closeDrawer() {
    setState(() {
      _resetFields();
      _drawerOpen = false;
      _formSnapshot = '';
    });
  }

  void _openDrawer(_Row? product) => closeCatalogueDrawer(
    context,
    dirty: _dirty,
    onClose: () => _fillForm(product),
  );

  void _requestCloseDrawer() =>
      closeCatalogueDrawer(context, dirty: _dirty, onClose: _closeDrawer);

  Future<void> _saveProductItem() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _saveProductItemUnguarded();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveProductItemUnguarded() async {
    final String departmentName = _departmentController.text.trim();
    final String mainCategoryName = _mainCategoryController.text.trim();
    final String itemName = _itemNameController.text.trim();
    final String brandName = _brandNameController.text.trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    final String itemCode = _itemCodeController.text.trim();
    final String barcode = _barcodeController.text.trim();
    final String packingSize = _packingSizeController.text.trim();
    final String departmentManagerName = _departmentManagerController.text
        .trim();
    final String uom = _uomController.text.trim().isEmpty
        ? 'ctn'
        : _uomController.text.trim();
    final String priceText = _priceController.text.trim();
    final double? unitPrice = parseCataloguePrice(priceText);
    final String displayProductName =
        packingSize.isEmpty || itemName.contains('(')
        ? itemName
        : '$itemName ($packingSize)';

    if (departmentName.isEmpty ||
        mainCategoryName.isEmpty ||
        itemName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter department, main category and product name.'),
        ),
      );
      return;
    }
    final String? brandValidationError = catalogueTextLengthError(
      label: 'Brand name',
      value: brandName,
      maxLength: maxCatalogueBrandNameLength,
    );
    if (brandValidationError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(brandValidationError)));
      return;
    }
    final String departmentId = _cleanDocId(departmentName);
    final String categoryId = _cleanDocId(
      '$departmentName\u0000$mainCategoryName',
    );
    final String productIdentity = <String>[
      if (brandName.isNotEmpty) brandName,
      itemCode.isNotEmpty
          ? itemCode
          : barcode.isNotEmpty
          ? barcode
          : itemName,
      if (itemCode.isEmpty && barcode.isEmpty && brandName.isNotEmpty)
        packingSize,
    ].where((String value) => value.trim().isNotEmpty).join('\u0000');
    final String productId =
        _editingId ??
        _cleanDocId(
          <String>[
            departmentName,
            mainCategoryName,
            productIdentity,
          ].where((String value) => value.trim().isNotEmpty).join('\u0000'),
        );
    final String? textValidationError = validateManualCatalogueProductFields(
      departmentName: departmentName,
      departmentManagerName: departmentManagerName,
      mainCategoryName: mainCategoryName,
      itemName: itemName,
      itemCode: itemCode,
      barcode: barcode,
      packingSize: packingSize,
      uom: uom,
      displayProductName: displayProductName,
      departmentId: departmentId,
      categoryId: categoryId,
      productId: productId,
    );
    if (textValidationError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(textValidationError)));
      return;
    }
    if (priceText.isNotEmpty && unitPrice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Enter a valid unit price in the allowed range ($cataloguePriceRangeLabel).',
          ),
        ),
      );
      return;
    }
    final String sortOrderText = _sortOrderController.text.trim();
    final int? sortOrder = parseCatalogueSortOrder(sortOrderText);
    if (sortOrderText.isNotEmpty && sortOrder == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sort order must be a whole number from 0 to $maxCatalogueSortOrder.',
          ),
        ),
      );
      return;
    }
    final String maxOrderQtyText = _maxOrderQtyController.text.trim();
    final int? maxOrderQty = maxOrderQtyText.isEmpty
        ? defaultMaxQtyPerLine
        : parseCatalogueMaxOrderQty(maxOrderQtyText);
    if (maxOrderQty == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('$catalogueMaxOrderQtyError.')),
      );
      return;
    }

    try {
      final Map<String, dynamic> productData = <String, dynamic>{
        'productId': productId,
        'departmentId': departmentId,
        'categoryId': categoryId,
        'departmentName': departmentName,
        'departmentManagerName': departmentManagerName,
        'mainCategoryName': mainCategoryName,
        'itemName': displayProductName,
        'productName': displayProductName,
        'productFlavor': itemName,
        'flavor': itemName,
        'categoryName': mainCategoryName,
        'itemCode': itemCode,
        'productCode': itemCode,
        'sku': itemCode,
        'barcode': barcode,
        'itemBarcode': barcode,
        'packingSize': packingSize,
        ...cataloguePriceFields(unitPrice ?? 0.0),
        'uom': uom,
        'uomLabel': uom,
        'unitOfMeasure': uom,
        'brandName': brandName,
        'sortOrder': sortOrder ?? 0,
        'maxOrderQty': maxOrderQty,
        'mobileDisplayMode': 'textOnly',
        ...priceStampFor(
          changed:
              _editingId == null ||
              priceChanged(_loadedPrice, unitPrice ?? 0.0) ||
              priceChanged(_loadedPriceGuide, unitPrice ?? 0.0) ||
              priceChanged(_loadedPriceField, unitPrice ?? 0.0),
        ),
      };
      if (_editingId == null) {
        final PermissionPolicyService permissionPolicy =
            PermissionPolicyService.instance;
        final bool canEnsureDepartment =
            permissionPolicy.cachedAllows(
              widget.currentUser.role,
              'departments',
              PermissionAction.view,
            ) &&
            permissionPolicy.cachedAllows(
              widget.currentUser.role,
              'departments',
              PermissionAction.create,
            );
        final bool canEnsureCategory =
            permissionPolicy.cachedAllows(
              widget.currentUser.role,
              'categories',
              PermissionAction.view,
            ) &&
            permissionPolicy.cachedAllows(
              widget.currentUser.role,
              'categories',
              PermissionAction.create,
            );
        await _catalogueRepository.createIfAbsent(
          productId: productId,
          product: productData,
          departmentId: departmentId,
          department: <String, dynamic>{
            'departmentId': departmentId,
            'departmentName': departmentName,
            'name': departmentName,
            'status': 'active',
            'isActive': true,
          },
          categoryId: categoryId,
          category: <String, dynamic>{
            'categoryId': categoryId,
            'mainCategoryId': categoryId,
            'departmentId': departmentId,
            'departmentName': departmentName,
            'mainCategoryName': mainCategoryName,
            'categoryName': mainCategoryName,
            'name': mainCategoryName,
            'status': 'active',
            'isActive': true,
          },
          ensureDepartment: canEnsureDepartment,
          ensureCategory: canEnsureCategory,
        );
      } else {
        await _repository.upsertDocument(
          collectionName: 'products',
          docId: productId,
          data: productData,
        );
      }
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'save the product'),
        isError: true,
      );
      return;
    }

    final bool wasNew = _editingId == null;
    final bool wantVisible = _isVisible;
    String? notShown;
    if (wasNew ? wantVisible : wantVisible != _loadedVisible) {
      try {
        await _catalogueRepository.applyAvailability(<String, bool>{
          productId: wantVisible,
        });
      } on PlatformApiException catch (error) {
        notShown = error.message;
      }
    }

    if (!mounted) return;
    if (notShown != null) {
      showCmsToast(
        context,
        wasNew
            ? 'Product saved, but hidden: $notShown'
            : 'Product saved, but its visibility did not change: $notShown',
        isError: true,
      );
    } else {
      showCmsToast(context, 'Product item saved.');
    }
    _closeDrawer();
  }

  String _searchBlob(_Row product) {
    return <Object?>[
      product['retailerName'],
      product['departmentName'],
      product['mainCategoryName'],
      _brand(product),
      product['itemName'],
      product['productName'],
      product['itemCode'],
      product['productCode'],
      product['sku'],
      product['barcode'],
      product['itemBarcode'],
      product['packingSize'],
    ].join(' ').toLowerCase();
  }

  String _productDedupeKey(_Row product) {
    final String productId = _readText(
      product,
      'docId',
      fallbackKeys: const <String>[
        'productId',
        'itemId',
        'sku',
        'productCode',
        'itemCode',
      ],
    );
    return productId.isEmpty ? 'doc:${_id(product)}' : 'id:$productId';
  }

  int _productQualityScore(_Row product) {
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
    if (_readText(product, 'categoryId').isNotEmpty) score += 80;
    if (_readText(product, 'departmentId').isNotEmpty) score += 60;
    if (_readText(product, 'productName').isNotEmpty) score += 30;
    if (_readText(product, 'itemName').isNotEmpty) score += 25;
    if (_readText(product, 'packingSize').isNotEmpty) score += 20;
    if (cataloguePriceOf(product) > 0) score += 20;
    if (isCatalogueProductVisible(product)) score += 10;
    return score;
  }

  List<_Row> _dedupeProducts(List<_Row> products) {
    final Map<String, _Row> bestByKey = <String, _Row>{};
    for (final _Row product in products) {
      final String key = _productDedupeKey(product);
      final _Row? current = bestByKey[key];
      if (current == null ||
          _productQualityScore(product) > _productQualityScore(current)) {
        bestByKey[key] = product;
      }
    }
    return bestByKey.values.toList();
  }

  int _uniqueCount(List<_Row> rows, String Function(_Row) read) =>
      rows.map(read).where((String value) => value.isNotEmpty).toSet().length;

  String _id(_Row row) => '${row['docId'] ?? ''}';
  String _department(_Row row) => _readText(row, 'departmentName');
  String _brand(_Row row) =>
      _readText(row, 'brandName', fallbackKeys: const <String>['brand']);
  String _category(_Row row) => _readText(
    row,
    'mainCategoryName',
    fallbackKeys: const <String>['categoryName'],
  );
  String _name(_Row row) => _readText(
    row,
    'itemName',
    fallbackKeys: const <String>['productName'],
    fallback: _id(row),
  );
  String _barcode(_Row row) =>
      _readText(row, 'barcode', fallbackKeys: const <String>['itemBarcode']);
  double _price(_Row row) => cataloguePriceOf(row);
  bool _visible(_Row row) => isCatalogueProductVisible(row);

  int _defaultOrder(_Row a, _Row b) {
    final int department = _department(a).compareTo(_department(b));
    if (department != 0) return department;
    final int category = _category(a).compareTo(_category(b));
    if (category != 0) return category;
    final int orderA =
        int.tryParse(_readText(a, 'sortOrder', fallback: '0')) ?? 0;
    final int orderB =
        int.tryParse(_readText(b, 'sortOrder', fallback: '0')) ?? 0;
    return orderA.compareTo(orderB);
  }

  bool _anyBarcode(List<_Row> rows) =>
      rows.any((_Row r) => _barcode(r).isNotEmpty);

  List<CataloguePreset<_Row>> get _presets => <CataloguePreset<_Row>>[
    CataloguePreset<_Row>(id: 'all', label: 'All products', test: (_) => true),
    CataloguePreset<_Row>(
      id: 'hidden',
      label: 'Hidden',
      test: (_Row r) => !_visible(r),
    ),
    CataloguePreset<_Row>(
      id: 'missing_price',
      label: 'Missing price',
      test: (_Row r) => _price(r) <= 0,
    ),
    if (_companyUsesBarcodes)
      CataloguePreset<_Row>(
        id: 'missing_barcode',
        label: 'Missing barcode',
        test: (_Row r) => _barcode(r).isEmpty,
      ),
  ];

  List<CatalogueColumn<_Row>> _columns() {
    Widget text(BuildContext context, String value, {bool warn = false}) {
      final DsoColors dso = context.dso;
      return Text(
        value.isEmpty ? 'Not set' : value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: value.isEmpty
            ? TextStyle(color: warn ? dso.warningText : dso.muted)
            : null,
      );
    }

    return <CatalogueColumn<_Row>>[
      CatalogueColumn<_Row>(
        id: 'product',
        label: 'Product',
        width: 260,
        flex: 4,
        hideable: false,
        sortKey: (_Row r) => _name(r).toLowerCase(),
        csv: _name,
        cell: (BuildContext c, _Row r) => Tooltip(
          message: _name(r),
          child: Text(
            _name(r),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w600, color: c.dso.ink),
          ),
        ),
      ),
      CatalogueColumn<_Row>(
        id: 'brand',
        label: 'Brand',
        width: 130,
        flex: 1,
        hideBelowWidth: 1100,
        sortKey: (_Row r) => _brand(r).toLowerCase(),
        csv: _brand,
        cell: (BuildContext c, _Row r) =>
            Tooltip(message: _brand(r), child: text(c, _brand(r))),
      ),
      CatalogueColumn<_Row>(
        id: 'department',
        label: 'Department',
        width: 130,
        flex: 1,
        hideBelowWidth: 1340,
        sortKey: (_Row r) => _department(r).toLowerCase(),
        csv: _department,
        cell: (BuildContext c, _Row r) => text(c, _department(r)),
      ),
      CatalogueColumn<_Row>(
        id: 'category',
        label: 'Category',
        width: 170,
        flex: 2,
        sortKey: (_Row r) => _category(r).toLowerCase(),
        csv: _category,
        cell: (BuildContext c, _Row r) => text(c, _category(r)),
      ),
      CatalogueColumn<_Row>(
        id: 'code',
        label: 'Code',
        width: 110,
        sortKey: (_Row r) => _readText(
          r,
          'itemCode',
          fallbackKeys: const <String>['productCode', 'sku'],
        ).toLowerCase(),
        csv: (_Row r) => _readText(
          r,
          'itemCode',
          fallbackKeys: const <String>['productCode', 'sku'],
        ),
        cell: (BuildContext c, _Row r) => text(
          c,
          _readText(
            r,
            'itemCode',
            fallbackKeys: const <String>['productCode', 'sku'],
          ),
        ),
      ),
      CatalogueColumn<_Row>(
        id: 'barcode',
        label: 'Barcode',
        width: 140,
        hideBelowWidth: 1480,
        sortKey: (_Row r) => _barcode(r),
        csv: _barcode,
        cell: (BuildContext c, _Row r) =>
            text(c, _barcode(r), warn: _companyUsesBarcodes),
      ),
      CatalogueColumn<_Row>(
        id: 'pack',
        label: 'Pack',
        width: 110,
        hideBelowWidth: 1210,
        csv: (_Row r) => _readText(r, 'packingSize'),
        cell: (BuildContext c, _Row r) => text(c, _readText(r, 'packingSize')),
      ),
      CatalogueColumn<_Row>(
        id: 'uom',
        label: 'UOM',
        width: 84,
        csv: (_Row r) => _readText(
          r,
          'uom',
          fallbackKeys: const <String>['uomLabel', 'unitOfMeasure'],
        ),
        cell: (BuildContext c, _Row r) => text(
          c,
          _readText(
            r,
            'uom',
            fallbackKeys: const <String>['uomLabel', 'unitOfMeasure'],
          ),
        ),
      ),
      CatalogueColumn<_Row>(
        id: 'price',
        label: 'Price',
        width: 90,
        numeric: true,
        sortKey: _price,
        csv: (_Row r) => _price(r) > 0 ? _price(r).toStringAsFixed(2) : '',
        cell: (BuildContext c, _Row r) => _price(r) > 0
            ? Text(formatRm(_price(r)))
            : Text('Not set', style: TextStyle(color: c.dso.warningText)),
      ),
      CatalogueColumn<_Row>(
        id: 'sort',
        label: 'Sort',
        width: 60,
        numeric: true,
        visibleByDefault: false,
        sortKey: (_Row r) =>
            int.tryParse(_readText(r, 'sortOrder', fallback: '0')) ?? 0,
        csv: (_Row r) => _readText(r, 'sortOrder', fallback: '0'),
        cell: (BuildContext c, _Row r) =>
            Text(_readText(r, 'sortOrder', fallback: '0')),
      ),
      CatalogueColumn<_Row>(
        id: 'status',
        label: 'Status',
        width: 100,
        hideable: false,
        sortKey: (_Row r) => _visible(r) ? 'visible' : 'hidden',
        csv: (_Row r) => _visible(r) ? 'Visible' : 'Hidden',
        cell: (BuildContext c, _Row r) => Align(
          alignment: Alignment.centerLeft,
          child: CatalogueStatusPill(
            label: _visible(r) ? 'Visible' : 'Hidden',
            tone: _visible(r) ? CatalogueTone.success : CatalogueTone.neutral,
          ),
        ),
      ),
    ];
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _exportCsv(List<_Row> rows, List<CatalogueColumn<_Row>> columns) {
    final List<CatalogueColumn<_Row>> visible = columns
        .where(
          (CatalogueColumn<_Row> c) => !_view.hiddenColumnIds.contains(c.id),
        )
        .toList();
    final DateTime now = DateTime.now();
    final String stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final bool started = downloadCsv(
      filename: 'products_$stamp.csv',
      csv: catalogueCsv<_Row>(rows, visible),
    );
    _snack(
      started
          ? 'Exported ${rows.length} products.'
          : 'CSV download is only available in the browser.',
    );
  }

  Future<void> _setVisibility(List<_Row> rows, bool visible) async {
    if (rows.isEmpty || _bulkBusy) return;
    if (rows.length > _maxBulkWrites) {
      _snack(
        'Select up to $_maxBulkWrites products at a time to '
        '${visible ? 'show' : 'hide'} them.',
      );
      return;
    }
    setState(() => _bulkBusy = true);
    try {
      await _catalogueRepository.setVisibility(
        productIds: rows.map(_id).toList(growable: false),
        visible: visible,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _bulkBusy = false);
      showCmsToast(
        context,
        userFacingError(error, action: 'change product visibility'),
        isError: true,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _bulkBusy = false);
    _view.clearSelection();
    final String verb = visible ? 'Showed' : 'Hid';
    _snack('$verb ${rows.length} ${rows.length == 1 ? 'product' : 'products'}');
  }

  Future<void> _toggleVisibility(_Row row) =>
      _setVisibility(<_Row>[row], !_visible(row));

  Future<void> _deleteProduct(_Row product) async {
    final String productId = '${product['docId'] ?? ''}'.trim();
    final String productName = _readText(
      product,
      'productName',
      fallbackKeys: const <String>['itemName', 'name'],
      fallback: productId,
    );
    if (productId.isEmpty) return;
    if (isDemoProductRecord(product)) {
      _snack('This catalogue record is protected.');
      return;
    }
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Delete product?',
      message:
          'Delete "$productName" from the catalogue? Existing order history '
          'will not be changed.',
    );
    if (!confirmed) return;
    try {
      await _catalogueRepository.deleteProducts(<String>[productId]);
      if (!mounted) return;
      if (_editingId == productId) _closeDrawer();
      _snack('Deleted $productName.');
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'delete $productName'),
        isError: true,
      );
    }
  }

  void _onEscape() {
    if (_toolbarKey.currentState?.closeMenus() ?? false) return;
    if (_drawerOpen) {
      _requestCloseDrawer();
    } else if (_view.selectedIds.isNotEmpty) {
      _view.clearSelection();
    } else if (_searchController.text.isNotEmpty) {
      _clearSearch();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
    }
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
          StreamBuilder<List<_Row>>(
            stream: _stream,
            builder: (BuildContext context, AsyncSnapshot<List<_Row>> snap) =>
                ListenableBuilder(
                  listenable: _view,
                  builder: (BuildContext context, Widget? _) =>
                      _buildWorkspace(context, snap),
                ),
          ),
    );
  }

  Widget _buildWorkspace(BuildContext context, AsyncSnapshot<List<_Row>> snap) {
    final bool canCreate = _allowed(PermissionAction.create);
    final bool canEdit = _allowed(PermissionAction.edit);
    final bool canDelete = _allowed(PermissionAction.delete);

    final List<_Row> allProducts = _dedupeProducts(
      List<_Row>.from(snap.data ?? <_Row>[])
          .where((_Row product) => !isDemoProductRecord(product))
          .toList(growable: false),
    );
    _companyUsesBarcodes = _anyBarcode(allProducts);
    final List<CatalogueColumn<_Row>> columns = _columns();
    final List<_Row> products = _view.apply(
      allProducts,
      idOf: _id,
      searchBlob: _searchBlob,
      filterValue: <String, String Function(_Row)>{
        'department': _department,
        'category': _category,
        'visibility': (_Row r) => _visible(r) ? 'Visible' : 'Hidden',
      },
      columns: columns,
      defaultSort: _defaultOrder,
      presets: _presets,
    );
    _visibleIds = products.map(_id).toList(growable: false);

    int count(String presetId) => allProducts
        .where(
          _presets
              .firstWhere((CataloguePreset<_Row> p) => p.id == presetId)
              .test,
        )
        .length;
    List<String> options(String Function(_Row) read) =>
        (allProducts
            .map(read)
            .where((String v) => v.isNotEmpty)
            .toSet()
            .toList()
          ..sort());
    Set<String> selected(String key) => _view.filters[key] ?? <String>{};

    final bool formAllowed = _editingId == null ? canCreate : canEdit;
    final List<_Row> selectedRows = products
        .where((_Row r) => _view.selectedIds.contains(_id(r)))
        .toList();

    return CatalogueShortcuts(
      onSearch: _searchFocus.requestFocus,
      onNew: canCreate ? () => _openDrawer(null) : null,
      onEscape: _onEscape,
      onNext: () => _view.moveActive(_visibleIds, 1),
      onPrevious: () => _view.moveActive(_visibleIds, -1),
      onOpen: canEdit
          ? () {
              final String? id = _view.activeId;
              if (id == null) return;
              _openDrawer(products.firstWhere((_Row r) => _id(r) == id));
            }
          : null,
      onToggleSelect: () {
        final String? id = _view.activeId;
        if (id != null) _view.toggleSelected(id);
      },
      child: CatalogueWorkspace(
        title: 'Product list',
        subtitle:
            '${allProducts.length} products · '
            '${_uniqueCount(allProducts, _department)} departments · '
            '${_uniqueCount(allProducts, _category)} categories',
        issues: <CatalogueIssueCount>[
          for (final (String id, String label) in <(String, String)>[
            ('hidden', 'Hidden'),
            ('missing_price', 'Missing price'),
            if (_companyUsesBarcodes) ('missing_barcode', 'Missing barcode'),
          ])
            CatalogueIssueCount(
              label: label,
              count: count(id),
              active: _view.presetId == id,
              onTap: () => _view.setPreset(_view.presetId == id ? 'all' : id),
            ),
        ],
        primaryAction: canCreate
            ? FilledButton.icon(
                onPressed: () => _openDrawer(null),
                icon: const Icon(ScootIcons.add, size: 18),
                label: const Text('Add product'),
              )
            : null,
        secondaryActions: <Widget>[
          if (!canCreate && !canEdit && !canDelete)
            Semantics(
              container: true,
              label: 'View only',
              excludeSemantics: true,
              child: Text(
                'View only',
                style: TextStyle(fontSize: 13, color: context.dso.muted),
              ),
            ),
          OutlinedButton.icon(
            onPressed: products.isEmpty
                ? null
                : () => _exportCsv(products, columns),
            icon: const Icon(ScootIcons.download, size: 18),
            label: const Text('Export CSV'),
          ),
        ],
        toolbar: CatalogueToolbar<_Row>(
          key: _toolbarKey,
          search: _searchController,
          searchFocus: _searchFocus,
          searchHint: 'Search products, brands, codes, barcodes',
          filters: <CatalogueFilterMenu>[
            CatalogueFilterMenu(
              label: 'Department',
              options: options(_department),
              selected: selected('department'),
              onChanged: (Set<String> v) => _view.setFilter('department', v),
            ),
            CatalogueFilterMenu(
              label: 'Category',
              options: options(_category),
              selected: selected('category'),
              onChanged: (Set<String> v) => _view.setFilter('category', v),
            ),
            CatalogueFilterMenu(
              label: 'Visibility',
              options: const <String>['Visible', 'Hidden'],
              selected: selected('visibility'),
              onChanged: (Set<String> v) => _view.setFilter('visibility', v),
            ),
          ],
          presets: _presets,
          presetId: _view.presetId,
          onPreset: _view.setPreset,
          columns: columns,
          hiddenColumnIds: _view.hiddenColumnIds,
          onColumns: _view.setHiddenColumns,
          density: _view.density,
          onDensity: _view.setDensity,
          hasActiveFilters: _view.hasActiveFilters || _view.query.isNotEmpty,
          resultSummary:
              'Showing ${products.length} of ${allProducts.length}${_view.showingCloseMatches ? ' · no exact match, showing close spellings' : ''}',
          onClearFilters: () {
            _clearSearch();
            _view.clearFilters();
          },
        ),
        bulkBar: _view.selectedIds.isEmpty
            ? null
            : CatalogueBulkBar(
                selectedCount: _view.selectedIds.length,
                busy: _bulkBusy,
                onClear: _view.clearSelection,
                actions: <CatalogueBulkAction>[
                  if (canEdit)
                    CatalogueBulkAction(
                      label: 'Show products',
                      run: () => _setVisibility(selectedRows, true),
                    ),
                  if (canEdit)
                    CatalogueBulkAction(
                      label: 'Hide products',
                      run: () => _setVisibility(selectedRows, false),
                    ),
                  CatalogueBulkAction(
                    label: 'Export CSV',
                    run: () async => _exportCsv(selectedRows, columns),
                  ),
                ],
              ),
        body: _buildBody(
          snap,
          allProducts,
          products,
          columns,
          canEdit: canEdit,
          canDelete: canDelete,
        ),
        drawerOpen: _drawerOpen && formAllowed,
        onCloseDrawer: _requestCloseDrawer,
        drawer: CatalogueDrawer(
          title: _editingId == null ? 'Add product' : 'Edit product',
          dirty: _dirty,
          onClose: _closeDrawer,
          body: _buildForm(),
          footer: <Widget>[
            if (_editingId != null && canDelete)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: context.dso.dangerText,
                ),
                onPressed: () {
                  final String id = _editingId!;
                  final _Row? row = allProducts
                      .where((_Row r) => _id(r) == id)
                      .firstOrNull;
                  if (row != null) _deleteProduct(row);
                },
                child: const Text('Delete…'),
              ),
            const Spacer(),
            TextButton(
              onPressed: _requestCloseDrawer,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving ? null : _saveProductItem,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    AsyncSnapshot<List<_Row>> snap,
    List<_Row> allProducts,
    List<_Row> products,
    List<CatalogueColumn<_Row>> columns, {
    required bool canEdit,
    required bool canDelete,
  }) {
    Future<void> retry() async {
      await _repository.resetCollectionStream(
        'products',
        orderBy: 'departmentName',
      );
      if (mounted) setState(() => _stream = _watchProducts());
    }

    if (snap.hasError) {
      final Object? error = snap.error;
      if (error is FirebaseException && error.code == 'permission-denied') {
        return const CataloguePermissionDenied();
      }
      return CatalogueError(
        message: userFacingError(
          error ?? 'unknown',
          action: 'load the product catalogue',
        ),
        onRetry: retry,
      );
    }
    if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
      return CatalogueLoading(onRetry: retry);
    }
    if (allProducts.isEmpty) {
      return CatalogueEmpty(
        title: 'No products yet',
        message: _allowed(PermissionAction.create)
            ? 'Add the first product to start the master catalogue.'
            : 'The master catalogue is empty.',
      );
    }
    if (products.isEmpty) {
      return CatalogueNoResults(
        onClear: () {
          _clearSearch();
          _view.clearFilters();
        },
      );
    }
    return CatalogueTable<_Row>(
      rows: products,
      idOf: _id,
      labelOf: (_Row r) {
        final String brand = _brand(r);
        return '${_name(r)}${brand.isEmpty ? '' : ', Brand $brand'}, '
            '${_visible(r) ? 'Visible' : 'Hidden'}'
            '${_price(r) > 0 ? ', ${formatRm(_price(r))}' : ', no price'}';
      },
      columns: columns,
      state: _view,
      groupOf: _department,
      semanticsLabelPrefix: 'Product',
      onOpen: canEdit ? _openDrawer : null,
      rowActions: (_Row r) => <CatalogueRowAction<_Row>>[
        if (canEdit)
          CatalogueRowAction<_Row>(
            label: 'Edit',
            icon: ScootIcons.edit,
            onPressed: _openDrawer,
          ),
        if (canEdit)
          CatalogueRowAction<_Row>(
            label: _visible(r) ? 'Hide' : 'Show',
            icon: _visible(r) ? ScootIcons.paused : ScootIcons.play,
            onPressed: _toggleVisibility,
          ),
        if (canDelete)
          CatalogueRowAction<_Row>(
            label: 'Delete',
            icon: ScootIcons.remove,
            destructive: true,
            onPressed: _deleteProduct,
          ),
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Products are saved once in the master catalogue. Brand is product '
          'information. Global visibility and retailer score sheet settings '
          'control salesperson availability.',
          style: TextStyle(color: context.dso.muted, fontSize: 13),
        ),
        const SizedBox(height: 16),
        _field(
          label: 'Department',
          controller: _departmentController,
          hint: 'Beverage',
        ),
        const SizedBox(height: 16),
        _field(
          label: 'Department Manager',
          controller: _departmentManagerController,
          hint: 'Beverage Manager',
        ),
        const SizedBox(height: 16),
        _field(
          label: 'Main Category',
          controller: _mainCategoryController,
          hint: 'AJ100 CREAM SANDWICH BISCUIT',
        ),
        const SizedBox(height: 16),
        _field(
          label: 'Product',
          controller: _itemNameController,
          hint: 'CHOCOLATE',
        ),
        const SizedBox(height: 16),
        _field(
          label: 'Brand',
          controller: _brandNameController,
          hint: 'TENTEN, Nestlé, or another brand',
        ),
        const SizedBox(height: 16),
        _pair(
          _field(
            label: 'Product Code / SKU',
            controller: _itemCodeController,
            hint: 'R001-BEV-001',
          ),
          _field(
            label: 'Barcode No.',
            controller: _barcodeController,
            hint: '9551000000015',
          ),
        ),
        const SizedBox(height: 16),
        _pair(
          _field(
            label: 'Packaging Specification',
            controller: _packingSizeController,
            hint: '24 x 320ML',
          ),
          _field(
            label: 'Unit Price (RM)',
            controller: _priceController,
            hint: '19.45',
          ),
        ),
        const SizedBox(height: 16),
        _pair(
          _field(label: 'UOM', controller: _uomController, hint: 'ctn'),
          _field(
            label: 'Sort Order',
            controller: _sortOrderController,
            hint: '1',
          ),
        ),
        const SizedBox(height: 16),
        _pair(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _field(
                label: 'Max order qty',
                controller: _maxOrderQtyController,
                hint: '$defaultMaxQtyPerLine',
              ),
              const SizedBox(height: 4),
              Text(
                'Most a salesperson can order of this product in one order. '
                'Whole number from 1 to $absoluteMaxQtyPerLine.',
                style: TextStyle(color: context.dso.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox.shrink(),
        ),
        const SizedBox(height: 16),
        SwitchListTile.adaptive(
          value: _isVisible,
          contentPadding: EdgeInsets.zero,
          title: const Text('Visible in score sheet'),
          subtitle: const Text(
            'Turn off to hide this product from salesperson selection.',
          ),
          onChanged: (bool value) => setState(() => _isVisible = value),
        ),
      ],
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required String hint,
  }) {
    return CmsInput(controller: controller, hintText: hint, label: label);
  }

  Widget _pair(Widget left, Widget right) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Expanded(child: left),
      const SizedBox(width: 12),
      Expanded(child: right),
    ],
  );

  String _cleanDocId(String text) {
    return cleanImportId(text);
  }

  String _readText(
    _Row row,
    String key, {
    List<String> fallbackKeys = const <String>[],
    String fallback = '',
  }) {
    for (final String currentKey in <String>[key, ...fallbackKeys]) {
      final Object? value = row[currentKey];
      final String text = '$value'.trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return fallback;
  }
}
