import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'add_to_cart.dart';
import 'order_signature_screen.dart';
import 'draft_saved_screen.dart';
import 'barcode_scanner_screen.dart';
import '../utils/barcode_key.dart';
import '../utils/order_reference.dart';
import '../widgets/barcode_product_choice.dart';
import '../utils/tenten_catalogue.dart';
import '../copilot/mobile_copilot_page.dart';
import '../models/guided_visit_context.dart';
import '../services/cart_draft_cache.dart';
import '../services/order_line_prices.dart';
import '../utils/cart_draft_runtime.dart';
import '../utils/replenishment_prefill.dart';
import '../utils/data_number.dart';
import '../utils/quantity_unit.dart';
import '../theme/app_theme.dart';
import '../widgets/count_step_actions.dart';

class _WholeNumberFormatter extends TextInputFormatter {
  _WholeNumberFormatter({this.onInvalid});

  static const int max = 20;
  final VoidCallback? onInvalid;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;

    if (!RegExp(r'^(0|[1-9]\d*)$').hasMatch(newValue.text)) return oldValue;

    final parsed = int.tryParse(newValue.text);
    if (parsed == null || parsed > max) {
      onInvalid?.call();
      return oldValue;
    }
    return newValue;
  }
}

class OrderCartScreen extends StatefulWidget {
  final List<Map<String, dynamic>> selectedItems;
  final String retailerId;
  final String retailerName;
  final String? visitId;
  final GuidedVisitContext? guidedVisitContext;

  const OrderCartScreen({
    super.key,
    required this.selectedItems,
    required this.retailerId,
    required this.retailerName,
    this.visitId,
    this.guidedVisitContext,
  });

  @override
  State<OrderCartScreen> createState() => _OrderCartScreenState();
}

class _OrderCartScreenState extends State<OrderCartScreen> {
  List<Map<String, dynamic>> cartItems = [];
  bool _isLoadingItems = true;
  final List<String> _identityErrors = [];
  final List<String> _identityWarnings = [];
  bool _isSaved = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _scannedProductId;
  Timer? _autosaveTimer;

  final ScrollController _scrollController = ScrollController();

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
    _updateVisitProgress();
    _loadItems();
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    for (final item in cartItems) {
      for (final batch in (item["shelfBatches"] as List)) {
        (batch["focusNode"] as FocusNode?)?.dispose();
      }
    }
    super.dispose();
  }

  void _updateVisitProgress() {
    final visitId = widget.visitId?.trim() ?? '';
    if (visitId.isNotEmpty) {
      FirebaseFirestore.instance.collection('visits').doc(visitId).update({
        'progress': 2,
        'status': 'counting',
        'step2At': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  int _readInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  Map<String, dynamic> _hydrateCartDraftItem(Map<String, dynamic> data) {
    return hydrateCartDraftItemForRuntime(
      data,
      retailerId: widget.retailerId,
      retailerName: widget.retailerName,
      visitId: widget.visitId,
    );
  }

  Future<CartDraftSnapshot?> _loadDraft() async {
    final cached = _draft;
    if (cached != null) {
      return cached.copyWith(
        items: cached.items.map(_hydrateCartDraftItem).toList(),
      );
    }

    final visitId = widget.visitId?.trim() ?? '';
    if (visitId.isEmpty) return null;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('visits')
          .doc(visitId)
          .get();
      final data = snap.data();
      final rawItems = data?['cartDraftItems'] as List<dynamic>? ?? const [];
      if (rawItems.isEmpty) return null;

      final items = rawItems
          .whereType<Map>()
          .map((raw) => _hydrateCartDraftItem(Map<String, dynamic>.from(raw)))
          .where((item) => (item['name'] as String? ?? '').isNotEmpty)
          .toList();
      if (items.isEmpty) return null;

      final restored = CartDraftSnapshot(
        salesmanUid: _salesmanUid,
        retailerId: widget.retailerId,
        visitId: widget.visitId,
        progress: _readInt(data?['draftStage'], fallback: 2),
        pendingOrderId:
            ((data?['signatureDraft'] as Map?)?['pendingOrderId'] ?? '')
                .toString(),
        items: items,
      );
      CartDraftCache.save(_draftKey, restored);
      return restored;
    } catch (error) {
      debugPrint('Failed to restore count draft: $error');
      return null;
    }
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _findProduct(
    Map<String, dynamic> selection,
  ) async {
    final products = FirebaseFirestore.instance.collection('products');
    final id = (selection['productId'] ?? '').toString().trim();
    if (id.isNotEmpty) {
      final product = await products.doc(id).get();
      return product.exists ? product : null;
    }
    final name = (selection['name'] ?? '').toString().trim();
    final matches = <String, DocumentSnapshot<Map<String, dynamic>>>{};
    for (final field in ['itemName', 'productName']) {
      final snapshot = await products
          .where(field, isEqualTo: name)
          .limit(2)
          .get();
      for (final product in snapshot.docs) {
        matches[product.id] = product;
      }
    }
    if (matches.length > 1) {
      throw StateError(
        'Legacy draft: ambiguous product "$name". Use Items to choose the exact product.',
      );
    }
    if (matches.isEmpty) return null;
    _identityWarnings.add(
      'Legacy draft: "$name" matched by name. Please review this product.',
    );
    return matches.values.single;
  }

  Future<void> _loadItems() async {
    final draft = await _loadDraft();
    final List<Map<String, dynamic>> merged = [];
    Map<String, dynamic>? retailerSheet;
    Object? retailerSheetError;
    try {
      retailerSheet = await CurrentLinePrices.retailerSheet(widget.retailerId);
    } catch (error) {
      retailerSheetError = error;
    }
    for (final selection in widget.selectedItems) {
      final selectedId = (selection['productId'] ?? '').toString().trim();
      final selectedName = (selection['name'] ?? '').toString().trim();
      final savedMatches =
          draft?.items
              .where(
                (item) => selectedId.isNotEmpty
                    ? item['productId'] == selectedId
                    : (item['productId'] ?? '').toString().isEmpty &&
                          item['name'] == selectedName,
              )
              .toList() ??
          [];
      final saved = savedMatches.length == 1 ? savedMatches.single : null;
      DocumentSnapshot<Map<String, dynamic>>? product;
      try {
        product = await _findProduct(selection);
      } on StateError catch (error) {
        _identityErrors.add(error.message.toString());
        continue;
      } catch (_) {
        if (selectedId.isNotEmpty && saved != null) {
          merged.add(saved);
        } else {
          _identityErrors.add(
            'Could not load product "$selectedName" ($selectedId). Please try again.',
          );
        }
        continue;
      }
      if (product == null || !isOrderableCatalogueProduct(product.data()!)) {
        _identityErrors.add(
          'Product "${selectedName.isEmpty ? selectedId : selectedName}" is unavailable. Use Items to review the selection.',
        );
        continue;
      }
      final data = product.data()!;
      final productId = product.id;
      final EffectiveLinePrice? currentPrice = retailerSheetError == null
          ? effectiveLinePrice(
              productId: productId,
              product: data,
              retailerSheet: retailerSheet,
            )
          : null;
      final double? capturedPrice = saved == null
          ? null
          : dataNumberOrNull(saved['price']);
      final bool hasCapturedPrice =
          capturedPrice != null && unitPriceCents(capturedPrice) > 0;
      if (!hasCapturedPrice && currentPrice?.isValid != true) {
        final String label = selectedName.isEmpty
            ? (data['itemName'] ?? data['productName'] ?? productId).toString()
            : selectedName;
        _identityErrors.add(
          retailerSheetError is RetailerSheetUnavailable
              ? '$retailerSheetError'
              : retailerSheetError != null
              ? 'Could not load the price of "$label". Please try again.'
              : '"$label" has no valid price for this retailer. Ask an administrator to fix it.',
        );
        continue;
      }
      if (saved != null) {
        saved['productId'] = productId;
        saved['name'] = data['itemName'] ?? data['productName'] ?? '';
        if (!hasCapturedPrice) {
          saved['price'] = currentPrice!.unitPrice;
          saved['priceSource'] = currentPrice.source;
        }
        saved['packingSize'] =
            data['packingSize'] ?? data['packagingSize'] ?? '';
        saved['barcode'] = data['itemBarcode'] ?? data['barcode'] ?? '';
        saved.remove('uom');
        if (uomOf(data) != null) saved['uom'] = uomOf(data);
        saved['maxOrderQty'] = maxQtyFor(data);
        merged.add(saved);
        continue;
      }
      final suggestedReorderQty = ReplenishmentPrefill.take(
        retailerId: widget.retailerId,
        productId: productId,
      );

      merged.add({
        "retailerName": widget.retailerName,
        "retailerId": widget.retailerId,
        "visitId": widget.visitId,

        "productId": productId,
        "name": data['itemName'] ?? data['productName'] ?? '',
        "packingSize": data['packingSize'] ?? data['packagingSize'] ?? '',
        "barcode": data['itemBarcode'] ?? data['barcode'] ?? '',
        "price": currentPrice!.unitPrice,
        "priceSource": currentPrice.source,
        "department": data['departmentName'] ?? 'Other',
        if (uomOf(data) != null) "uom": uomOf(data),
        "maxOrderQty": maxQtyFor(data),

        "qty": 1,
        "stock": 0,

        "expiry": '',

        "suggestedReorderQty": suggestedReorderQty,

        "shelfBatches": [
          {
            "qty": 0,
            "expiry": '',
            "controller": TextEditingController(text: '0'),
            "focusNode": FocusNode(),
          },
        ],

        "stockController": TextEditingController(text: '0'),
      });
    }

    if (mounted) {
      setState(() {
        cartItems = merged;
        _isLoadingItems = false;
        _isSaved = draft != null && merged.length == draft.items.length;
      });
    }
  }

  Future<void> _pickShelfDate(
    BuildContext context,
    int itemIndex,
    int batchIndex,
  ) async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime(2035),
      initialDate: DateTime.now(),
    );

    if (picked != null) {
      setState(() {
        cartItems[itemIndex]["shelfBatches"][batchIndex]["expiry"] =
            "${picked.day}/${picked.month}/${picked.year}";
      });
      _scheduleDraftAutosave();
    }
  }

  void addShelfBatch(int itemIndex) {
    setState(() {
      cartItems[itemIndex]["shelfBatches"].add({
        "qty": 0,
        "expiry": '',
        "controller": TextEditingController(text: '0'),
        "focusNode": FocusNode(),
      });
    });
    _scheduleDraftAutosave();
  }

  void removeShelfBatch(int itemIndex, int batchIndex) {
    setState(() {
      cartItems[itemIndex]["shelfBatches"].removeAt(batchIndex);
    });
    _scheduleDraftAutosave();
  }

  Future<void> _confirmRemoveItem(Map<String, dynamic> item) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove item?'),
        content: Text('Remove "${item["name"]}" from this count?'),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ScootColors.of(dialogContext).danger.foreground,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final int realIndex = cartItems.indexOf(item);
    if (realIndex < 0) return;
    setState(() => cartItems.removeAt(realIndex));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final batch in (item["shelfBatches"] as List)) {
        (batch["controller"] as TextEditingController?)?.dispose();
        (batch["focusNode"] as FocusNode?)?.dispose();
      }
    });
    _scheduleDraftAutosave();
  }

  List<Map<String, dynamic>> get _filteredCartItems {
    if (_searchQuery.isEmpty) return cartItems;
    final query = _searchQuery.toLowerCase();
    return cartItems.where((item) {
      if (_scannedProductId != null) {
        return item['productId'] == _scannedProductId;
      }
      final name = (item['name'] as String? ?? '').toLowerCase();
      return name.contains(query) ||
          barcodeMatchesQuery(item['barcode'], _searchQuery);
    }).toList();
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

    final matches = cartItems
        .where((item) => barcodesMatch(item['barcode'], scanned))
        .toList();
    final found = await chooseBarcodeProduct(
      context,
      matches: matches,
      label: (item) =>
          '${item['name']} · ${item['packingSize']} · ${item['productId']} · RM ${item['price']}',
    );
    if (!mounted || (matches.isNotEmpty && found == null)) return;
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Barcode $scanned not found in cart.')),
      );
      return;
    }
    final idx = cartItems.indexOf(found);
    final String shownBarcode = cartItems[idx]['barcode'].toString().trim();
    _searchController.text = shownBarcode;
    setState(() {
      _searchQuery = shownBarcode;
      _scannedProductId = found['productId']?.toString();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.qr_code, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text('Found: ${cartItems[idx]['name']}')),
          ],
        ),
        backgroundColor: AppColors.greenSolid,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        controller: _searchController,
        onChanged: (val) => setState(() {
          _searchQuery = val.trim();
          _scannedProductId = null;
        }),
        style: const TextStyle(fontSize: 13, color: Colors.black87),
        decoration: InputDecoration(
          hintText: 'Search SKU or product...',
          hintStyle: const TextStyle(fontSize: 13, color: AppColors.textGrey),
          prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? GestureDetector(
                  onTap: () {
                    _searchController.clear();
                    setState(() {
                      _searchQuery = '';
                      _scannedProductId = null;
                    });
                  },
                  child: const Icon(Icons.close, color: Colors.grey, size: 18),
                )
              : null,
          filled: true,
          fillColor: Colors.grey[100],
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 0,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _snapshotCartItems() {
    return cartItems.map((item) {
      final stockCtrl = item["stockController"] as TextEditingController?;
      final stockInt =
          int.tryParse(stockCtrl?.text ?? '') ?? (item["stock"] as int? ?? 0);

      return {
        ...item,
        "qty": item["qty"] as int,
        "stock": stockInt,
        "shelfBatches": (item["shelfBatches"] as List)
            .map(
              (b) => {
                "qty": b["qty"] as int,
                "expiry": b["expiry"] as String,
                "controller": TextEditingController(text: b["qty"].toString()),
                "focusNode": FocusNode(),
              },
            )
            .toList(),
        "stockController": TextEditingController(text: stockInt.toString()),
        "visitId": item["visitId"] ?? widget.visitId,
      };
    }).toList();
  }

  List<Map<String, dynamic>> _serialiseCartItems() {
    return CartDraftCache.removeEmptyShelfBatches(_snapshotCartItems()).map((
      item,
    ) {
      return <String, dynamic>{
        'name': item['name'],
        'productId': item['productId'],
        'packingSize': item['packingSize'] ?? '',
        'barcode': item['barcode'] ?? '',
        'price': item['price'] ?? 0,
        if (item['priceSource'] is String) 'priceSource': item['priceSource'],
        'department': item['department'] ?? 'Other',
        if (uomOf(item) != null) 'uom': uomOf(item),
        'maxOrderQty': maxQtyFor(item),
        'qty': item['qty'] as int? ?? 0,
        'stock': item['stock'] as int? ?? 0,
        'expiry': item['expiry'] ?? '',
        'retailerId': item['retailerId'] ?? widget.retailerId,
        'retailerName': item['retailerName'] ?? widget.retailerName,
        'visitId': item['visitId'] ?? widget.visitId,
        'shelfBatches': (item['shelfBatches'] as List<dynamic>? ?? [])
            .map(
              (batch) => <String, dynamic>{
                'qty': batch['qty'] as int? ?? 0,
                'expiry': batch['expiry'] as String? ?? '',
              },
            )
            .toList(),
      };
    }).toList();
  }

  CartDraftSnapshot _cartDraft({int progress = 2}) => CartDraftSnapshot(
    salesmanUid: _salesmanUid,
    retailerId: widget.retailerId,
    visitId: widget.visitId,
    progress: progress,
    pendingOrderId: _draft?.pendingOrderId ?? '',
    items: _snapshotCartItems(),
    signatures: _draft?.signatures,
  );

  void _snapshotCartDraft({int progress = 2}) {
    CartDraftCache.save(_draftKey, _cartDraft(progress: progress));
  }

  bool _maxQuantityDialogVisible = false;

  void _showMaxQuantityDialog(Map<String, dynamic> item) {
    if (_maxQuantityDialogVisible) return;
    _maxQuantityDialogVisible = true;
    showDialog(
      context: context,
      builder: (dialogContext) {
        final ScootColors c = ScootColors.of(dialogContext);
        return AlertDialog(
          title: Row(
            children: [
              Icon(ScootIcons.warning, color: c.warning.noteText),
              const SizedBox(width: 8),
              const Expanded(child: Text('Limit reached')),
            ],
          ),
          content: Text(
            'Maximum quantity is '
            '${quantityLabel(_WholeNumberFormatter.max, uomOf(item))}.',
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(ScootSize.primaryButton),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    ).then((_) => _maxQuantityDialogVisible = false);
  }

  Future<void> _saveCart() async {
    final CartDraftPersistenceResult saved = await CartDraftCache.saveAndWait(
      _draftKey,
      _cartDraft(),
    );
    if (!mounted) return;
    if (!saved.isSaved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'The draft could not be saved on this device. Free some storage and try again.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }
    unawaited(_persistVisitDraft());
    setState(() => _isSaved = true);

    final draftSnapshot = cartItems
        .map(
          (item) => {
            'name': item['name'],
            'packingSize': item['packingSize'] ?? '',
            'department': item['department'] ?? 'Other',
            if (uomOf(item) != null) 'uom': uomOf(item),
            'qty': item['qty'] as int? ?? 0,
            'expiry': item['expiry'] ?? '',
          },
        )
        .toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DraftSavedScreen(
          retailerName: retailerName,
          retailerId: retailerId,
          visitId: widget.visitId,
          guidedVisitContext: widget.guidedVisitContext,
          source: DraftSource.count,
          items: draftSnapshot,
          onResume: () => Navigator.pop(context),
        ),
      ),
    );
  }

  void _scheduleDraftAutosave() {
    _snapshotCartDraft();
    if (mounted) {
      setState(() => _isSaved = false);
    }
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(
      const Duration(milliseconds: 500),
      _persistVisitDraft,
    );
  }

  Future<void> _persistVisitDraft() async {
    final visitId = widget.visitId?.trim() ?? '';
    if (visitId.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('visits')
          .doc(visitId)
          .update({
            'draftStage': 2,
            'cartDraftItems': _serialiseCartItems(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
      if (mounted) {
        setState(() => _isSaved = true);
      }
    } catch (error) {
      debugPrint('Failed to autosave count draft: $error');
    }
  }

  void _openAddItems() {
    _snapshotCartDraft();
    unawaited(_persistVisitDraft());
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => AddToCartPage(
          retailerId: widget.retailerId,
          retailerName: widget.retailerName,
          visitId: widget.visitId,
          initialSelectedItems: cartItems,
          guidedVisitContext: widget.guidedVisitContext,
        ),
      ),
    );
  }

  Widget _buildShelfBatch(int itemIndex, int batchIndex) {
    final Map<String, dynamic> item = cartItems[itemIndex];
    final batch = item["shelfBatches"][batchIndex];
    final String unit = quantityLabel(0, uomOf(item)).substring(2);
    final FocusNode focusNode = batch["focusNode"] as FocusNode;

    void onFocusChange() {
      if (focusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Scrollable.ensureVisible(
            focusNode.context!,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: 0.5,
          );
        });
      }
    }

    if (batch["scrollListenerAdded"] != true) {
      focusNode.addListener(onFocusChange);
      batch["scrollListenerAdded"] = true;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
        color: Colors.grey.shade50,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                "Batch Qty (${unit[0].toUpperCase()}${unit.substring(1)})",
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),

              const Spacer(),

              IconButton(
                onPressed: () {
                  if (batch["qty"] > 0) {
                    setState(() {
                      batch["qty"]--;

                      batch["controller"].text = batch["qty"].toString();
                    });
                    _scheduleDraftAutosave();
                  }
                },
                icon: const Icon(Icons.remove),
              ),

              SizedBox(
                width: 55,
                child: TextField(
                  controller: batch["controller"],
                  focusNode: focusNode,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  inputFormatters: [
                    _WholeNumberFormatter(
                      onInvalid: () => _showMaxQuantityDialog(item),
                    ),
                  ],
                  onChanged: (v) {
                    batch["qty"] = int.tryParse(v) ?? 0;
                    _scheduleDraftAutosave();
                  },
                ),
              ),

              IconButton(
                onPressed: () {
                  if (batch["qty"] >= _WholeNumberFormatter.max) {
                    _showMaxQuantityDialog(item);
                    return;
                  }
                  setState(() {
                    batch["qty"]++;

                    batch["controller"].text = batch["qty"].toString();
                  });
                  _scheduleDraftAutosave();
                },
                icon: const Icon(Icons.add),
              ),

              IconButton(
                onPressed: () => removeShelfBatch(itemIndex, batchIndex),
                icon: const Icon(Icons.delete_outline, color: Colors.red),
              ),
            ],
          ),

          const SizedBox(height: 8),

          InkWell(
            onTap: () => _pickShelfDate(context, itemIndex, batchIndex),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    batch["expiry"] == ''
                        ? "Select Shelf Batch Expiry"
                        : batch["expiry"],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get retailerName {
    if (cartItems.isEmpty) return widget.retailerName;
    return cartItems.first["retailerName"] as String? ?? widget.retailerName;
  }

  String get retailerId {
    if (cartItems.isEmpty) return widget.retailerId;
    return cartItems.first["retailerId"] as String? ?? widget.retailerId;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScootColors.of(context).page,
      resizeToAvoidBottomInset: true,
      appBar: ScootPhoneAppBar(
        title: retailerName,
        subtitle: retailerCodeLabel(retailerId, retailerName: retailerName),
        onBack: () {
          _snapshotCartDraft();
          unawaited(_persistVisitDraft());
          Navigator.pop(context);
        },
        actions: <Widget>[
          const CopilotEntryButton(),
          ScootPhoneAction(
            icon: ScootIcons.scanBarcode,
            label: 'Scan barcode',
            onPressed: _openBarcodeScanner,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const ScootStepBar(
              current: 1,
              steps: <String>['Select', 'Count', 'Sign-off'],
            ),

            _buildSearchBar(),

            for (final message in [..._identityErrors, ..._identityWarnings])
              Padding(padding: const EdgeInsets.all(12), child: Text(message)),
            Expanded(
              child: _isLoadingItems
                  ? const Center(child: CircularProgressIndicator())
                  : cartItems.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No items selected for this count.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textGrey,
                          ),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: _scrollController,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          if (_filteredCartItems.isEmpty &&
                              _searchQuery.isNotEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 16, bottom: 12),
                              child: Center(
                                child: Text(
                                  'No matching items.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textGrey,
                                  ),
                                ),
                              ),
                            ),
                          ...List.generate(_filteredCartItems.length, (
                            filteredIndex,
                          ) {
                            final item = _filteredCartItems[filteredIndex];
                            final int index = cartItems.indexOf(item);

                            return Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.grey.shade300,
                                  width: 1.2,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item["name"],
                                              style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),

                                            const SizedBox(height: 4),

                                            if ((item["packingSize"] ?? '')
                                                .toString()
                                                .trim()
                                                .isNotEmpty)
                                              Text(
                                                "Pack Size: ${item["packingSize"]}",
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),

                                            if ((item["productId"] ?? '')
                                                .toString()
                                                .trim()
                                                .isNotEmpty)
                                              Text(
                                                "Product ID: ${item["productId"]}",
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),

                                            if ((item["barcode"] ?? '')
                                                .toString()
                                                .trim()
                                                .isNotEmpty)
                                              Text(
                                                "Barcode: ${item["barcode"]}",
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),

                                            Text(
                                              "Unit Price: RM ${item["price"].toStringAsFixed(2)}",
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        key: Key('remove_item_$index'),
                                        tooltip: 'Remove item',
                                        onPressed: () =>
                                            _confirmRemoveItem(item),
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: Colors.red,
                                        ),
                                      ),
                                    ],
                                  ),

                                  if (item["suggestedReorderQty"] is int) ...[
                                    const SizedBox(height: 8),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEDE9FE),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.auto_awesome,
                                            size: 16,
                                            color: Color(0xFF4C1D95),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Suggested reorder: ${item["suggestedReorderQty"]} '
                                              '(count the shelf below as usual)',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFF4C1D95),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],

                                  const Divider(height: 24),

                                  const Text(
                                    "Stock On Shelf",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),

                                  const SizedBox(height: 10),

                                  ...List.generate(
                                    item["shelfBatches"].length,
                                    (batchIndex) =>
                                        _buildShelfBatch(index, batchIndex),
                                  ),

                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () => addShelfBatch(index),
                                      icon: const Icon(Icons.add),
                                      label: const Text("Add Expiry Batch"),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),

                          const SizedBox(height: 100),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),

      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          color: Colors.white,
          child: CountStepActions(
            isSaved: _isSaved,
            onSave: cartItems.isEmpty || _identityErrors.isNotEmpty
                ? null
                : _saveCart,
            onAddItems: _openAddItems,
            onContinue: cartItems.isEmpty || _identityErrors.isNotEmpty
                ? null
                : () {
                    _snapshotCartDraft();
                    unawaited(_persistVisitDraft());
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => OrderSignatureScreen(
                          cartItems: cartItems,
                          visitId: widget.visitId,
                          guidedVisitContext: widget.guidedVisitContext,
                        ),
                      ),
                    );
                  },
          ),
        ),
      ),
    );
  }
}
