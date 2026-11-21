import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'order_confirmation_screen.dart';
import 'draft_saved_screen.dart';
import '../copilot/mobile_copilot_commands.dart';
import '../copilot/mobile_copilot_page.dart';
import '../models/assigned_route_plan.dart' show RetailerCoordinateSnapshot;
import '../models/guided_visit_context.dart';
import '../providers/auth_provider.dart';
import '../providers/gps_provider.dart';
import '../services/assigned_visit_order_recovery.dart';
import '../services/cart_draft_cache.dart';
import '../services/company_lifecycle_monitor.dart';
import '../services/firestore_service.dart';
import 'company_paused_screen.dart';
import '../services/held_work.dart';
import '../services/held_work_sync.dart';
import '../services/guided_visit_session_store.dart';
import '../services/order_line_prices.dart';
import '../services/visit_submission.dart';
import '../utils/order_reference.dart';
import '../utils/order_submission_id.dart';
import '../utils/order_submission_contract.dart';
import '../utils/quantity_unit.dart';
import '../utils/remarks_validator.dart';
import '../utils/special_request_payload.dart';
import '../utils/tenten_catalogue.dart';
import 'add_to_cart.dart' show ProductItem;
import '../utils/location_evidence.dart';
import '../utils/location_fix.dart';
import '../voice/core/action_registry.dart';
import '../voice/core/voice_binding.dart';
import '../voice/core/voice_dispatcher.dart';
import '../voice/core/voice_engine.dart';
import '../voice/core/voice_types.dart';
import '../voice/voice_registry_factory.dart';
import '../theme/app_theme.dart';

const kPrimaryGreen = AppColors.greenSolid;
const kBannerGreen = Color(0xFF3C685E);
const kButtonGreen = AppColors.greenSolid;

const kVisitedText = Color(0xFF006338);
const kVisitedFill = Color(0xFFCBEBD7);
const kPendingText = AppColors.textAmber;
const kPendingFill = Color(0xFFEBE3CB);
const kMissedText = Color(0xFFB52F2F);
const kMissedFill = Color(0xFFFFCACA);

enum _PendingOrderRecovery { absent, pending, confirmed, conflict }

const List<String> kDepartmentOrder = [
  'Baby Products',
  'Beverage',
  'Confectionary',
  'Grocery',
  'Snacks',
];

class SignatureOrderItem {
  final int no;
  final String productName;

  final String productId;
  final String barcode;
  final String packingSize;

  String? uom;

  int maxOrderQty;
  double unitPrice;
  String priceSource;
  int orderQty;
  final int stockOnShelf;
  final String department;
  final List<Map<String, dynamic>> shelfBatches;
  String orderedExpiry;
  String remarks;

  SignatureOrderItem({
    required this.no,
    required this.productName,
    this.productId = '',
    this.barcode = '',
    required this.packingSize,
    this.uom,
    this.maxOrderQty = defaultMaxQtyPerLine,
    required this.unitPrice,
    this.priceSource = '',
    required this.orderQty,
    required this.stockOnShelf,
    required this.department,
    required this.shelfBatches,
    required this.orderedExpiry,
    this.remarks = '',
  });

  double get subtotal => orderQty * unitPrice;
}

Map<String, dynamic> submittedOrderLine(SignatureOrderItem item) =>
    <String, dynamic>{
      'name': item.productName,
      'productName': item.productName,
      if (item.productId.isNotEmpty) 'productId': item.productId,
      if (item.barcode.isNotEmpty) 'barcode': item.barcode,
      'packingSize': item.packingSize,
      if (item.uom != null) 'uom': item.uom,
      'maxOrderQty': item.maxOrderQty,
      'price': item.unitPrice,
      if (item.priceSource.isNotEmpty) 'priceSource': item.priceSource,
      'qty': item.orderQty,
      'expiry': item.orderedExpiry,
      'department': item.department,
      'departmentName': item.department,
      'shelfBatches': item.shelfBatches
          .where((batch) => (batch['qty'] as int? ?? 0) > 0)
          .map((b) => {'qty': b['qty'], 'expiry': b['expiry']})
          .toList(),
      'remarks': item.remarks.trimRight(),
    };

const Set<String> submittedFieldsTheShopDoesNotSign = <String>{
  'maxOrderQty',
  'priceSource',
};

String signedLinesRecord(Iterable<SignatureOrderItem> departmentItems) {
  final List<String> lines = <String>[
    for (final SignatureOrderItem item in departmentItems)
      if (item.orderQty > 0)
        jsonEncode(<String, dynamic>{
          for (final MapEntry<String, dynamic> field in submittedOrderLine(
            item,
          ).entries)
            if (!submittedFieldsTheShopDoesNotSign.contains(field.key))
              field.key: field.key == 'price'
                  ? unitPriceCents(item.unitPrice)
                  : field.value,
        }),
  ]..sort();
  return jsonEncode(lines);
}

bool isOfflineFailure(Object error) =>
    error is TimeoutException ||
    (error is FirebaseException && error.code == 'unavailable');

String unavailableEarlierSubmissionMessage(
  AssignedVisitOrderRecoveryCause cause,
) => switch (cause) {
  AssignedVisitOrderRecoveryCause.timeout =>
    'The check of the earlier submission took too long. Try again in a moment.',
  AssignedVisitOrderRecoveryCause.offline =>
    'The earlier submission cannot be checked while offline. Reconnect before retrying it.',
  AssignedVisitOrderRecoveryCause.unknown =>
    'The earlier submission could not be checked. Try again in a moment.',
};

String unsentOrderMessage({
  required bool saved,
  required bool earlierSendWaiting,
  required bool timedOut,
  bool causeUnknown = false,
}) {
  final String lead = timedOut
      ? 'The check took too long.'
      : causeUnknown
      ? 'The order could not be checked.'
      : 'You are offline.';
  if (!saved) {
    return '$lead This order could not be saved on this device. Keep this screen open and try again.';
  }
  if (earlierSendWaiting) {
    return '$lead The earlier send is still waiting for signal and may already be sent. Tap Check Submission when you are online.';
  }
  return timedOut || causeUnknown
      ? '$lead This order was saved on this device and was not sent. Submit it again when the connection is better.'
      : '$lead This order was saved on this device and was not sent. Submit it again when you are online.';
}

class _PriceChange {
  const _PriceChange(this.item, this.newPrice, this.source);

  final SignatureOrderItem item;
  final double? newPrice;
  final String source;
}

class _ProductLookupResult {
  const _ProductLookupResult({this.data, this.confirmedMissing = false});

  final Map<String, dynamic>? data;
  final bool confirmedMissing;
}

class OrderSignatureScreen extends StatefulWidget {
  final List<Map<String, dynamic>> cartItems;
  final String? visitId;
  final GuidedVisitContext? guidedVisitContext;

  const OrderSignatureScreen({
    super.key,
    required this.cartItems,
    this.visitId,
    this.guidedVisitContext,
  });

  @override
  State<OrderSignatureScreen> createState() => _OrderSignatureScreenState();
}

class _OrderSignatureScreenState extends State<OrderSignatureScreen>
    with SingleTickerProviderStateMixin {
  String get _visitId {
    final fromWidget = widget.visitId?.trim() ?? '';
    if (fromWidget.isNotEmpty) return fromWidget;
    if (widget.cartItems.isEmpty) return '';
    return (widget.cartItems.first['visitId'] as String? ?? '').trim();
  }

  String get _salesmanUid =>
      FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

  String get _retailerId {
    if (widget.cartItems.isEmpty) return '';
    return (widget.cartItems.first['retailerId'] as String? ?? '').trim();
  }

  String get _retailerName {
    if (widget.cartItems.isEmpty) return '';
    return (widget.cartItems.first['retailerName'] as String? ?? '').trim();
  }

  String get _draftKey => CartDraftCache.keyFor(
    salesmanUid: _salesmanUid,
    retailerId: _retailerId,
    visitId: _visitId,
    routePlanId: widget.guidedVisitContext?.planId,
    routeStopId: widget.guidedVisitContext?.stopId,
  );

  CartDraftSnapshot? get _draft => CartDraftCache.read(_draftKey);

  late final Map<String, List<Offset?>> _deptPoints;
  late final Map<String, bool> _deptSigned;
  late final Map<String, DateTime?> _deptSignedAt;
  late final Map<String, String?> _deptSignedLines;
  final Set<String> _deptChangedAfterSigning = <String>{};

  late final List<SignatureOrderItem> _orderItems;
  late final List<String> _activeDepartments;
  late final Map<String, List<SignatureOrderItem>> _byDepartment;

  late final TabController _tabController;

  late final Map<int, TextEditingController> _remarksControllers;

  late final Map<int, FocusNode> _remarksFocusNodes;

  final Map<int, String?> _remarksErrors = {};

  late final Map<int, TextEditingController> _qtyControllers;

  late final VoiceScreenBinding _voiceBinding;
  late final VoiceCommandEngine _voiceEngine;

  Timer? _autosaveTimer;
  bool _signatureCacheDirty = false;

  String? _specialRequestType;
  String _specialRequestText = '';
  String _specialRequestProductId = '';
  String _specialRequestIssuedFor = '';

  bool _submitting = false;
  String _pendingOrderId = '';
  Set<String> _unavailableProductIds = <String>{};
  Future<void>? _pendingOrderCommit;
  late final Future<void> _productLimitsRefresh;
  DateTime? _limitsConfirmedAt;
  List<_PriceChange> _priceChanges = <_PriceChange>[];

  RetailerCoordinateSnapshot? _plannerShopPin;

  Future<void> _loadPlannerShopPin() async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> retailer =
          await FirebaseFirestore.instance
              .collection('retailers')
              .doc(_retailerId)
              .get()
              .timeout(const Duration(seconds: 6));
      final Map<String, dynamic>? data = retailer.data();
      if (data == null) return;
      final RetailerCoordinateSnapshot? snapshot =
          RetailerCoordinateSnapshot.fromRetailerRecord(_retailerId, data);
      if (snapshot != null && snapshot.isVerified) _plannerShopPin = snapshot;
    } catch (error) {
      debugPrint('order_shop_pin_read failed: $error');
    }
  }

  @override
  void initState() {
    super.initState();
    _pendingOrderId = _draft?.pendingOrderId.trim() ?? '';
    final Map<String, dynamic>? savedSpecialRequest = _draft?.specialRequest;
    if (savedSpecialRequest != null) {
      _specialRequestType = savedSpecialRequest['type']?.toString();
      _specialRequestText =
          savedSpecialRequest['description']?.toString() ?? '';
      _specialRequestProductId =
          savedSpecialRequest['selectedProductId']?.toString() ?? '';
    }
    _buildItems();
    if (widget.guidedVisitContext == null && _retailerId.isNotEmpty) {
      unawaited(_loadPlannerShopPin());
    }
    _productLimitsRefresh = _refreshProductLimits();
    unawaited(_reviewPricesOnOpen());
    _buildDepartments();

    _tabController = TabController(
      length: _activeDepartments.length,
      vsync: this,
    );

    _remarksControllers = {
      for (final item in _orderItems)
        item.no: TextEditingController(text: item.remarks),
    };

    _remarksFocusNodes = {for (final item in _orderItems) item.no: FocusNode()};
    for (final item in _orderItems) {
      _remarksFocusNodes[item.no]!.addListener(() {
        if (!_remarksFocusNodes[item.no]!.hasFocus) {
          final trimmed = _remarksControllers[item.no]!.text.trimRight();
          if (trimmed != _remarksControllers[item.no]!.text) {
            _remarksControllers[item.no]!.text = trimmed;
            item.remarks = trimmed;
            _scheduleSignatureAutosave();
          }
          setState(
            () => _remarksErrors[item.no] = RemarksValidator.validate(trimmed),
          );
        }
      });
    }

    for (final item in _orderItems) {
      _remarksErrors[item.no] = RemarksValidator.validate(item.remarks);
    }

    _qtyControllers = {
      for (final item in _orderItems)
        item.no: TextEditingController(text: item.orderQty.toString()),
    };

    _voiceBinding = VoiceScreenBinding(
      surfaceId: VoiceSurfaceIds.orderSignature,
    );
    _voiceBinding.registerHandler(
      VoiceActionId.setDraftOrderQuantity,
      _handleVoiceSetDraftOrderQuantity,
    );
    _voiceEngine = VoiceCommandEngine(
      sessionId: 'order-signature-${DateTime.now().microsecondsSinceEpoch}',
      binding: _voiceBinding,
      dispatcher: VoiceActionDispatcher(
        registry: buildVoiceActionRegistry(),
        binding: _voiceBinding,
      ),
    );

    _deptPoints = {for (final d in _activeDepartments) d: <Offset?>[]};
    _deptSigned = {for (final d in _activeDepartments) d: false};
    _deptSignedAt = {for (final d in _activeDepartments) d: null};
    _deptSignedLines = {for (final d in _activeDepartments) d: null};

    final savedSigs = _draft?.signatures;
    if (savedSigs != null) {
      for (final dept in _activeDepartments) {
        final entry = savedSigs[dept];
        if (entry == null) continue;

        final rawPoints = entry['points'] as List<dynamic>? ?? [];
        _deptPoints[dept] = rawPoints.map<Offset?>((p) {
          if (p == null) return null;
          return Offset(
            (p['dx'] as num).toDouble(),
            (p['dy'] as num).toDouble(),
          );
        }).toList();

        _deptSigned[dept] = entry['signed'] as bool? ?? false;
        final signedAtMs = entry['signedAt'] as int?;
        _deptSignedAt[dept] = signedAtMs != null
            ? DateTime.fromMillisecondsSinceEpoch(signedAtMs)
            : null;
        final Object? signedLines = entry['lines'];
        _deptSignedLines[dept] = signedLines is String ? signedLines : null;
        if (entry['changedAfterSigning'] == true) {
          _deptChangedAfterSigning.add(dept);
        }
      }
      if (_unsignChangedDepartments()) _persistSignOffState();
    }
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(() {
      fn();
      _unsignChangedDepartments();
    });
  }

  String _signedLinesKey(String dept) => signedLinesRecord(
    _byDepartment[dept] ?? const <SignatureOrderItem>[],
  );

  bool _unsignChangedDepartments() {
    bool changed = false;
    for (final String dept in _activeDepartments) {
      if (_deptSigned[dept] != true) continue;
      if (_deptSignedLines[dept] == null) {
        _deptSignedLines[dept] = _signedLinesKey(dept);
        changed = true;
        continue;
      }
      if (_deptSignedLines[dept] == _signedLinesKey(dept)) continue;
      _deptPoints[dept]!.clear();
      _deptSigned[dept] = false;
      _deptSignedAt[dept] = null;
      _deptSignedLines[dept] = null;
      _deptChangedAfterSigning.add(dept);
      changed = true;
    }
    return changed;
  }

  void _buildItems() {
    final Map<String, Map<String, dynamic>> savedByProductId = {};
    final Map<String, List<Map<String, dynamic>>> legacySavedByName = {};
    final draft = _draft;
    final saved = draft?.items;
    if (saved != null && draft?.progress == 4) {
      for (final item in saved) {
        final productId = item['productId']?.toString().trim() ?? '';
        if (productId.isNotEmpty) {
          savedByProductId[productId] = item;
          continue;
        }
        final name = item['name']?.toString() ?? '';
        if (name.isNotEmpty) {
          legacySavedByName
              .putIfAbsent(name, () => <Map<String, dynamic>>[])
              .add(item);
        }
      }
    }
    final Map<String, int> cartNameCounts = <String, int>{};
    for (final raw in widget.cartItems) {
      final name = raw['name']?.toString() ?? '';
      if (name.isNotEmpty) {
        cartNameCounts.update(
          name,
          (int count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }

    int counter = 1;
    _orderItems = widget.cartItems.map((raw) {
      final name = raw['name']?.toString() ?? '';
      final productId = raw['productId']?.toString().trim() ?? '';
      final legacyMatches = legacySavedByName[name] ?? const [];
      final prior = productId.isNotEmpty
          ? savedByProductId[productId] ??
                (cartNameCounts[name] == 1 && legacyMatches.length == 1
                    ? legacyMatches.single
                    : null)
          : (cartNameCounts[name] == 1 && legacyMatches.length == 1
                ? legacyMatches.single
                : null);

      final batches = (raw['shelfBatches'] as List<dynamic>? ?? []).map((b) {
        return <String, dynamic>{
          'qty': b['qty'] as int? ?? 0,
          'expiry': b['expiry'] as String? ?? '',
        };
      }).toList();

      final totalShelf = batches.fold<int>(
        0,
        (s, b) => s + ((b['qty'] as int?) ?? 0),
      );

      final dept = (raw['department'] as String?)?.trim() ?? '';
      final resolvedDept = dept.isNotEmpty ? dept : 'Other';

      return SignatureOrderItem(
        no: counter++,
        productName: name,
        productId: productId,
        barcode: raw['barcode']?.toString().trim() ?? '',
        packingSize: raw['packingSize'] as String? ?? '',
        uom:
            uomOf(prior ?? const <String, dynamic>{}) ?? uomOf(raw) ?? 'ctn',
        maxOrderQty: maxQtyFor(raw),
        unitPrice:
            (prior?['price'] as num?)?.toDouble() ??
            (raw['price'] as num?)?.toDouble() ??
            0.0,
        priceSource:
            (prior?['priceSource'] ?? raw['priceSource'])?.toString() ?? '',
        orderQty: prior != null
            ? (prior['qty'] as int? ?? raw['qty'] as int? ?? 1)
            : (raw['qty'] as int? ?? 1),
        stockOnShelf: totalShelf,
        department: resolvedDept,
        shelfBatches: batches,
        orderedExpiry: prior != null
            ? (prior['expiry'] as String? ?? raw['expiry'] as String? ?? '')
            : (raw['expiry'] as String? ?? ''),
        remarks: prior != null
            ? (prior['remarks'] as String? ?? raw['remarks'] as String? ?? '')
            : (raw['remarks'] as String? ?? ''),
      );
    }).toList();
  }

  Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>
  _readProductsFromServer() {
    final CollectionReference<Map<String, dynamic>> products = FirebaseFirestore
        .instance
        .collection('products');
    final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>> reads =
        <String, Future<DocumentSnapshot<Map<String, dynamic>>>>{
          for (final String id
              in _orderItems
                  .map((SignatureOrderItem item) => item.productId)
                  .where((String id) => id.isNotEmpty)
                  .toSet())
            id: products.doc(id).get(const GetOptions(source: Source.server)),
        };
    for (final Future<DocumentSnapshot<Map<String, dynamic>>> read
        in reads.values) {
      read.ignore();
    }
    return reads;
  }

  Future<void> _refreshProductLimits({
    bool showLimitNotice = true,
    Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>? serverReads,
  }) async {
    final CollectionReference<Map<String, dynamic>> products = FirebaseFirestore
        .instance
        .collection('products');
    bool allConfirmedByServer = true;
    Future<_ProductLookupResult> read(String productId) async {
      try {
        final Future<DocumentSnapshot<Map<String, dynamic>>>? shared =
            serverReads?[productId];
        final DocumentSnapshot<Map<String, dynamic>> snapshot =
            await (shared ?? products.doc(productId).get()).timeout(
              const Duration(seconds: 5),
            );
        if (snapshot.metadata.isFromCache) allConfirmedByServer = false;
        return _ProductLookupResult(
          data: snapshot.data(),
          confirmedMissing: !snapshot.exists && !snapshot.metadata.isFromCache,
        );
      } catch (_) {
        allConfirmedByServer = false;
        try {
          final DocumentSnapshot<Map<String, dynamic>> snapshot = await products
              .doc(productId)
              .get(const GetOptions(source: Source.cache));
          return _ProductLookupResult(data: snapshot.data());
        } catch (_) {
          return const _ProductLookupResult();
        }
      }
    }

    final List<SignatureOrderItem> lines = _orderItems
        .where((SignatureOrderItem item) => item.productId.isNotEmpty)
        .toList(growable: false);
    final List<_ProductLookupResult> found = await Future.wait(
      lines.map((SignatureOrderItem item) => read(item.productId)),
    );
    if (!mounted) return;
    final Set<String> unavailableProductIds = <String>{};
    setState(() {
      for (int i = 0; i < lines.length; i++) {
        final _ProductLookupResult result = found[i];
        final Map<String, dynamic>? data = result.data;
        if (result.confirmedMissing) {
          unavailableProductIds.add(lines[i].productId);
        }
        if (data == null) continue;
        if (!isOrderableCatalogueProduct(data)) {
          unavailableProductIds.add(lines[i].productId);
        }
        lines[i].uom = uomOf(data) ?? 'ctn';
        lines[i].maxOrderQty = maxQtyFor(data);
      }
      _unavailableProductIds = unavailableProductIds;
    });
    if (allConfirmedByServer) _limitsConfirmedAt = DateTime.now();
    final List<String> overLimit = _orderItems
        .where((SignatureOrderItem item) => item.orderQty > item.maxOrderQty)
        .map(
          (SignatureOrderItem item) =>
              '${item.productName} exceeds the maximum of '
              '${quantityLabel(item.maxOrderQty, item.uom)}.',
        )
        .toList(growable: false);
    if (!showLimitNotice || overLimit.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showMaxQuantityDialog(overLimit.join('\n'));
    });
  }

  void _buildDepartments() {
    _byDepartment = <String, List<SignatureOrderItem>>{};
    for (final item in _orderItems) {
      _byDepartment.putIfAbsent(item.department, () => []).add(item);
    }

    final ordered = <String>[];
    for (final dept in kDepartmentOrder) {
      if (_byDepartment.containsKey(dept)) {
        ordered.add(dept);
      }
    }
    for (final dept in _byDepartment.keys) {
      if (!ordered.contains(dept)) {
        ordered.add(dept);
      }
    }
    _activeDepartments = ordered;
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _tabController.dispose();
    for (final c in _remarksControllers.values) {
      c.dispose();
    }
    for (final fn in _remarksFocusNodes.values) {
      fn.dispose();
    }
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    _voiceBinding.dispose();
    super.dispose();
  }

  void _clearSignature(String dept) {
    setState(() {
      _deptPoints[dept]!.clear();
      _deptSigned[dept] = false;
      _deptSignedAt[dept] = null;
      _deptSignedLines[dept] = null;
    });
    _scheduleSignatureAutosave();
  }

  void _onPanUpdate(String dept, DragUpdateDetails d, RenderBox box) {
    setState(() {
      _deptPoints[dept]!.add(box.globalToLocal(d.globalPosition));
      _deptSigned[dept] = true;
      _deptSignedAt[dept] ??= DateTime.now();
      _deptSignedLines[dept] = _signedLinesKey(dept);
      _deptChangedAfterSigning.remove(dept);
    });
    _signatureCacheDirty = true;
    _restartAutosaveTimer();
  }

  void _onPanEnd(String dept, DragEndDetails _) {
    setState(() => _deptPoints[dept]!.add(null));
    _scheduleSignatureAutosave();
  }

  bool get _allSigned =>
      _activeDepartments.every((d) => _deptSigned[d] == true);

  bool get _hasAnyRemarksError => _remarksErrors.values.any((e) => e != null);

  int get _remarksErrorCount =>
      _remarksErrors.values.where((e) => e != null).length;

  String get _totalQuantityLabel => totalQuantityLabel(
    _orderItems.map((SignatureOrderItem i) => (i.orderQty, i.uom)),
  );

  double get _totalPrice => _orderItems.fold(0.0, (s, i) => s + i.subtotal);

  List<String> get _unsignedDepartments =>
      _activeDepartments.where((d) => _deptSigned[d] != true).toList();

  List<Map<String, dynamic>> _snapshotSignOffItems() {
    return _orderItems
        .map(
          (item) => {
            'name': item.productName,
            if (item.productId.isNotEmpty) 'productId': item.productId,
            if (item.barcode.isNotEmpty) 'barcode': item.barcode,
            'packingSize': item.packingSize,
            if (item.uom != null) 'uom': item.uom,
            'maxOrderQty': item.maxOrderQty,
            'department': item.department,
            'qty': item.orderQty,
            'expiry': item.orderedExpiry,
            'price': item.unitPrice,
            if (item.priceSource.isNotEmpty) 'priceSource': item.priceSource,
            'remarks': item.remarks,
            'shelfBatches': item.shelfBatches,
            'retailerId': _retailerId,
            'retailerName': _retailerName,
            'visitId': _visitId,
          },
        )
        .toList();
  }

  Map<String, Map<String, dynamic>> _snapshotSignatures() {
    return {
      for (final dept in _activeDepartments)
        dept: {
          'points': (_deptPoints[dept] ?? []).map((o) {
            if (o == null) return null;
            return {'dx': o.dx, 'dy': o.dy};
          }).toList(),
          'signed': _deptSigned[dept] ?? false,
          'signedAt': _deptSignedAt[dept]?.millisecondsSinceEpoch,
          'lines': _deptSignedLines[dept] ?? '',
          if (_deptChangedAfterSigning.contains(dept))
            'changedAfterSigning': true,
        },
    };
  }

  bool _maxQuantityDialogVisible = false;

  void _showMaxQuantityDialog(String message) {
    if (_maxQuantityDialogVisible) return;
    _maxQuantityDialogVisible = true;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: Row(
            children: [
              Icon(Icons.error_outline, color: Colors.orange[700]),
              const SizedBox(width: 8),
              const Text('Limit reached'),
            ],
          ),
          content: Text(message),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimaryGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ),
          ],
        );
      },
    ).then((_) => _maxQuantityDialogVisible = false);
  }

  void _increaseQty(SignatureOrderItem item) {
    if (item.orderQty >= item.maxOrderQty) {
      _showMaxQuantityDialog(
        'The maximum order quantity is ${item.maxOrderQty}.',
      );
      return;
    }

    setState(() {
      item.orderQty++;
      _qtyControllers[item.no]?.text = item.orderQty.toString();
    });
    _scheduleSignatureAutosave();
  }

  void _decreaseQty(SignatureOrderItem item) {
    if (item.orderQty <= 0) return;
    setState(() {
      item.orderQty--;
      _qtyControllers[item.no]?.text = item.orderQty.toString();
    });
    _scheduleSignatureAutosave();
  }

  Future<VoiceActionResult> _handleVoiceSetDraftOrderQuantity(
    VoiceCommandEnvelope envelope,
  ) async {
    if (_submitting || _orderItems.isEmpty) {
      return const VoiceActionResult(code: VoiceResultCode.unavailable);
    }

    final Object? rawQuery = envelope.interpretation.parameters['productQuery'];
    final Object? rawQuantity = envelope.interpretation.parameters['quantity'];
    final Object? rawUnit = envelope.interpretation.parameters['unit'];
    if (rawQuery is! String || rawQuery.trim().isEmpty) {
      return const VoiceActionResult(code: VoiceResultCode.invalidParameters);
    }
    if (rawQuantity is! int || rawQuantity < 1) {
      return const VoiceActionResult(code: VoiceResultCode.invalidParameters);
    }
    if (rawUnit is! String || !kVoiceQuantityUnits.contains(rawUnit)) {
      return const VoiceActionResult(code: VoiceResultCode.invalidParameters);
    }

    final List<SignatureOrderItem> matches = _matchVoiceOrderItems(rawQuery);
    if (matches.length != 1) {
      return const VoiceActionResult(code: VoiceResultCode.ambiguousEntity);
    }

    final SignatureOrderItem item = matches.single;
    if (rawQuantity > item.maxOrderQty) {
      return const VoiceActionResult(code: VoiceResultCode.invalidParameters);
    }
    setState(() {
      item.orderQty = rawQuantity;
      _qtyControllers[item.no]?.text = rawQuantity.toString();
    });
    _revealVoiceOrderItem(item);
    _scheduleSignatureAutosave();
    return const VoiceActionResult.applied();
  }

  void _revealVoiceOrderItem(SignatureOrderItem item) {
    final int index = _activeDepartments.indexOf(item.department);
    if (index < 0 || index >= _tabController.length) return;
    if (_tabController.index == index) return;
    _tabController.animateTo(index);
  }

  List<SignatureOrderItem> _matchVoiceOrderItems(String query) {
    final String normalizedQuery = _normalizeVoiceOrderToken(query);
    if (normalizedQuery.isEmpty) return const <SignatureOrderItem>[];

    final List<SignatureOrderItem> exact = _orderItems
        .where(
          (SignatureOrderItem item) =>
              _normalizeVoiceOrderToken(item.productName) == normalizedQuery ||
              (item.barcode.isNotEmpty &&
                  _normalizeVoiceOrderToken(item.barcode) == normalizedQuery) ||
              (item.productId.isNotEmpty &&
                  _normalizeVoiceOrderToken(item.productId) == normalizedQuery),
        )
        .toList(growable: false);
    if (exact.isNotEmpty) return exact;

    return _orderItems
        .where(
          (SignatureOrderItem item) => _normalizeVoiceOrderToken(
            item.productName,
          ).contains(normalizedQuery),
        )
        .toList(growable: false);
  }

  String _normalizeVoiceOrderToken(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  Future<void> _pickOrderExpiry(
    BuildContext context,
    SignatureOrderItem item,
  ) async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime(2035),
      initialDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: kPrimaryGreen),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        item.orderedExpiry = '${picked.day}/${picked.month}/${picked.year}';
      });
      _scheduleSignatureAutosave();
    }
  }

  String _formatTimestamp(DateTime instant) {
    final DateTime dt = instant.toUtc().add(const Duration(hours: 8));
    final date =
        '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year}';
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$date  $hour:$minute:$second';
  }

  String _asCleanString(dynamic value, {String fallback = ''}) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? fallback : text;
  }

  bool _isGenericIdentity(dynamic value) {
    final v = (value ?? '').toString().trim().toLowerCase();
    return v.isEmpty ||
        v == 'n/a' ||
        v == 'na' ||
        v == 'null' ||
        v == 'unknown' ||
        v == 'unknown salesman' ||
        v == 'salesman' ||
        v == 'salesman not linked';
  }

  String _firstRealValue(List<dynamic> values, {String fallback = ''}) {
    for (final value in values) {
      if (!_isGenericIdentity(value)) return value.toString().trim();
    }
    return fallback;
  }

  Future<Map<String, dynamic>?> _resolveSalesmanSnapshot() async {
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null) return null;

    final ResolvedUserProfile? profile = await FirestoreService()
        .resolveUserProfile(
          authUser.uid,
          email: authUser.email,
          timeout: const Duration(seconds: 8),
        );
    if (profile == null || profile.id.isEmpty) {
      return null;
    }
    final Map<String, dynamic> userData = profile.data;
    final String userDocId = profile.id;

    final email = _firstRealValue([
      userData['email'],
      userData['salesmanEmail'],
      authUser.email,
    ]);

    final salesmanName = _firstRealValue([
      userData['name'],
      userData['displayName'],
      userData['fullName'],
      userData['employeeName'],
      userData['salesmanName'],
      authUser.displayName,
      email.contains('@') ? email.split('@').first : email,
    ], fallback: 'Unknown Salesman');

    final salesmanId = _firstRealValue([
      userData['staffId'],
      userData['staffID'],
      userData['employeeCode'],
      userData['salesmanCode'],
      userData['salesman_code'],
      userData['userId'],
      userData['salesmanId'],
      userDocId,
      authUser.uid,
    ], fallback: authUser.uid);

    return {
      'uid': authUser.uid,
      'userDocId': userDocId,
      'salesmanUid': authUser.uid,
      'salesmanEmail': email,
      'salesmanId': salesmanId,
      'salesmanName': salesmanName,
      'salesmanRole': _asCleanString(
        userData['role'],
        fallback: 'Sales Representative',
      ),
      'staffId': _firstRealValue([
        userData['staffId'],
        userData['staffID'],
        userData['employeeCode'],
        salesmanId,
      ], fallback: salesmanId),
      'employeeCode': _firstRealValue([
        userData['employeeCode'],
        userData['staffId'],
        userData['staffID'],
        salesmanId,
      ], fallback: salesmanId),
      'displayName': _firstRealValue([
        userData['displayName'],
        userData['name'],
        salesmanName,
      ], fallback: salesmanName),
      'branchId': _asCleanString(userData['branchId'] ?? userData['branch_id']),
      'ruleSalesmanCode': _firstRealValue([
        userData['employeeCode'],
        userData['staffId'],
        userData['salesmanCode'],
        userData['salesman_code'],
      ]),
      'supervisorId': _asCleanString(
        userData['supervisorId'] ?? userData['supervisor_id'],
      ),
    };
  }

  Map<String, dynamic> _salesmanIdentityFields(Map<String, dynamic> snap) {
    final String salesmanCode = _firstRealValue([
      snap['employeeCode'],
      snap['staffId'],
      snap['salesmanId'],
    ], fallback: '');
    return {
      'uid': snap['salesmanUid'],
      'userUid': snap['salesmanUid'],
      'userDocId': snap['userDocId'],
      'userId': snap['salesmanId'],
      'salesmanUid': snap['salesmanUid'],
      'salesmanEmail': snap['salesmanEmail'],
      'salesmanId': snap['salesmanId'],
      'salesmanName': snap['salesmanName'],
      'salesmanRole': snap['salesmanRole'],
      'submittedByUid': snap['salesmanUid'],
      'submittedByEmail': snap['salesmanEmail'],
      'submittedByName': snap['salesmanName'],
      'createdByUid': snap['salesmanUid'],
      'createdByEmail': snap['salesmanEmail'],
      'createdByName': snap['salesmanName'],
      'staffId': snap['staffId'],
      'employeeCode': snap['employeeCode'],
      'salesmanCode': salesmanCode,
      'salesman_code': salesmanCode,
      'displayName': snap['displayName'],
      'branchId': snap['branchId'],
      'supervisorId': snap['supervisorId'],
    };
  }

  Future<void> _writeOrderTrackingAfter(
    Future<void> orderCommit,
    FirebaseFirestore firestore,
    String orderId,
    Map<String, dynamic> trackingData,
  ) async {
    try {
      await orderCommit;
    } catch (error) {
      debugPrint('Order tracking skipped, the order was not saved: $error');
      return;
    }
    try {
      await firestore.collection('gps_tracking').doc('order_$orderId').set(
        <String, dynamic>{
          ...trackingData,
          'timestamp': FieldValue.serverTimestamp(),
        },
      );
    } catch (error) {
      debugPrint('Order tracking write failed: $error');
    }
  }

  Future<Position?> _tryGetSubmitPosition() async {
    final Position? tracked = context
        .read<GpsProvider>()
        .reliableCurrentPosition;
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      if (tracked != null &&
          DateTime.now().difference(tracked.timestamp).abs() <=
              const Duration(seconds: 30)) {
        return tracked;
      }
      return await acquireLocationFix(
        isUsable: (Position p) =>
            isReliableForegroundFix(_fixFromPosition(p), now: DateTime.now()),
        preciseWait: const Duration(seconds: 4),
        coarseWait: const Duration(seconds: 3),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _orderLocationFields(
    Position? position, {
    required DateTime now,
    bool disabledByUser = false,
  }) {
    if (position == null) {
      return <String, dynamic>{
        'locationEvidence': <String, dynamic>{
          'mode': 'not_verified',
          'failureCode': disabledByUser
              ? LocationEvidenceFailure.disabledByUser.code
              : LocationEvidenceFailure.unavailable.code,
        },
      };
    }

    final DeviceLocationFix fix = _fixFromPosition(position);
    final GuidedVisitContext? visit = widget.guidedVisitContext;
    final RetailerCoordinateSnapshot? pin = _plannerShopPin;
    final ({double latitude, double longitude})? shop = visit != null
        ? (latitude: visit.retailerLatitude, longitude: visit.retailerLongitude)
        : pin == null
        ? null
        : (latitude: pin.latitude!, longitude: pin.longitude!);
    final ArrivalLocationAssessment? assessment = shop == null
        ? null
        : ArrivalLocationAssessment.assess(
            fix: fix,
            retailerLatitude: shop.latitude,
            retailerLongitude: shop.longitude,
            now: now,
          );
    final bool usable = isReliableForegroundFix(fix, now: now);
    final String mode = assessment?.isVerified == true
        ? 'location_verified'
        : usable
        ? 'device_captured'
        : 'not_verified';
    final bool evidenceFixInRange = isFixWithinOrderEvidenceRange(
      fix,
      now: now,
    );
    final Map<String, dynamic> evidence = <String, dynamic>{
      'mode': mode,
      if (evidenceFixInRange) ...<String, dynamic>{
        'latitude': fix.latitude,
        'longitude': fix.longitude,
        'accuracyMeters': fix.accuracyMeters,
        'deviceCapturedAt': fix.capturedAt.toUtc(),
        'isMocked': fix.isMocked,
      },
      if (evidenceFixInRange && assessment?.distanceMeters != null)
        'distanceMeters': assessment!.distanceMeters,
      if (assessment?.failure != null) 'failureCode': assessment!.failure!.code,
      if (assessment == null && !usable) 'failureCode': 'unreliable_fix',
    };
    if (!usable) return <String, dynamic>{'locationEvidence': evidence};
    return <String, dynamic>{
      'latitude': fix.latitude,
      'longitude': fix.longitude,
      'gpsLatitude': fix.latitude,
      'gpsLongitude': fix.longitude,
      'location': GeoPoint(fix.latitude, fix.longitude),
      'locationCapturedAt': FieldValue.serverTimestamp(),
      'accuracy': fix.accuracyMeters,
      'accuracyMeters': fix.accuracyMeters,
      'deviceCapturedAt': fix.capturedAt.toUtc(),
      'isMocked': fix.isMocked,
      'locationVerification': mode,
      'locationEvidence': evidence,
    };
  }

  Future<_PendingOrderRecovery> _recoverPendingOrder(
    DocumentReference<Map<String, dynamic>> orderRef, {
    required String salesmanUid,
    required String retailerId,
    String? routePlanId,
    String? routeStopId,
  }) async {
    try {
      final cached = await orderRef.get(const GetOptions(source: Source.cache));
      if (cached.exists) {
        final data = cached.data() ?? <String, dynamic>{};
        if (!matchesOrderSubmissionIdentity(
          data,
          orderId: orderRef.id,
          salesmanUid: salesmanUid,
          retailerId: retailerId,
          routePlanId: routePlanId,
          routeStopId: routeStopId,
        )) {
          return _PendingOrderRecovery.conflict;
        }
        if (cached.metadata.hasPendingWrites) {
          return _PendingOrderRecovery.pending;
        }
      }
    } catch (_) {}

    try {
      final server = await FirebaseFirestore.instance
          .collection('orders')
          .where('salesmanUid', isEqualTo: salesmanUid)
          .where('orderId', isEqualTo: orderRef.id)
          .limit(1)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      if (server.docs.isEmpty) return _PendingOrderRecovery.absent;
      final recovered = server.docs.single;
      final data = recovered.data();
      return matchesOrderSubmissionIdentity(
                data,
                orderId: orderRef.id,
                salesmanUid: salesmanUid,
                retailerId: retailerId,
                routePlanId: routePlanId,
                routeStopId: routeStopId,
              ) &&
              recovered.id == orderRef.id
          ? _PendingOrderRecovery.confirmed
          : _PendingOrderRecovery.conflict;
    } catch (_) {
      return _PendingOrderRecovery.pending;
    }
  }

  Future<bool> _specialRequestExists(
    FirebaseFirestore firestore,
    String orderId,
  ) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> request = await firestore
          .collection('special_requests')
          .doc(SpecialRequestPayload.docId(orderId))
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      return request.exists;
    } catch (_) {
      return false;
    }
  }

  Future<List<_PriceChange>> _currentPriceChanges(
    Source source, {
    Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>? productReads,
  }) async {
    final Map<String, EffectiveLinePrice> current =
        await CurrentLinePrices.load(
          retailerId: _retailerId,
          productIds: _orderItems.map(
            (SignatureOrderItem item) => item.productId,
          ),
          source: source,
          productReads: productReads,
        );
    final List<_PriceChange> changes = <_PriceChange>[];
    for (final SignatureOrderItem item in _orderItems) {
      final EffectiveLinePrice? price = current[item.productId];
      if (price == null) continue;
      if (!price.isValid) {
        changes.add(_PriceChange(item, null, price.source));
      } else if (unitPriceCents(price.unitPrice!) !=
          unitPriceCents(item.unitPrice)) {
        changes.add(_PriceChange(item, price.unitPrice, price.source));
      } else if (item.priceSource.isEmpty) {
        item.priceSource = price.source;
      }
    }
    return changes;
  }

  Future<void> _reviewPricesOnOpen() async {
    if (_pendingOrderId.trim().isNotEmpty) return;
    try {
      final List<_PriceChange> changes = await _currentPriceChanges(
        Source.serverAndCache,
      ).timeout(const Duration(seconds: 10));
      if (mounted && changes.isNotEmpty) {
        setState(() => _priceChanges = changes);
      }
    } catch (error) {
      debugPrint('Price review on open skipped: $error');
    }
  }

  Future<void> _acceptNewPrices() async {
    if (_priceChanges.any((_PriceChange change) => change.newPrice == null)) {
      return;
    }
    setState(() {
      for (final _PriceChange change in _priceChanges) {
        change.item.unitPrice = change.newPrice!;
        change.item.priceSource = change.source;
      }
      _priceChanges = <_PriceChange>[];
    });
    final CartDraftPersistenceResult saved = await CartDraftCache.saveAndWait(
      _draftKey,
      _signOffDraft(),
    );
    unawaited(_persistSignatureDraft());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved.isSaved
              ? 'New prices accepted. Ask the retailer to sign again.'
              : 'New prices accepted, but the draft could not be saved on this device.',
        ),
      ),
    );
  }

  Future<void> _keepUnsentDraft({
    bool timedOut = false,
    bool causeUnknown = false,
  }) async {
    final bool earlierSendWaiting =
        _pendingOrderId.trim().isNotEmpty || _pendingOrderCommit != null;
    final CartDraftPersistenceResult saved = await CartDraftCache.saveAndWait(
      _draftKey,
      _signOffDraft(),
    );
    unawaited(_persistSignatureDraft());
    if (causeUnknown) unawaited(CompanyLifecycleMonitor.instance.refresh());
    if (!mounted) return;
    setState(() => _submitting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(
          unsentOrderMessage(
            saved: saved.isSaved,
            earlierSendWaiting: earlierSendWaiting,
            timedOut: timedOut,
            causeUnknown: causeUnknown,
          ),
        ),
      ),
    );
  }

  Future<void> _submitOrder() async {
    if (_submitting) return;
    final bool locationAllowed = context.read<GpsProvider>().trackingEnabled;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    setState(() => _submitting = true);
    final hasInFlightOrderCommit = _pendingOrderCommit != null;

    for (final item in _orderItems) {
      item.remarks = _remarksControllers[item.no]?.text ?? '';
    }
    final invalidItems = _orderItems.where((item) {
      return RemarksValidator.validate(item.remarks) != null;
    }).toList();
    final List<SignatureOrderItem> missingProductIds = _orderItems
        .where((item) => item.orderQty > 0 && item.productId.isEmpty)
        .toList(growable: false);
    final bool localChecksFail =
        (!hasInFlightOrderCommit && invalidItems.isNotEmpty) ||
        missingProductIds.isNotEmpty;

    final String retailerName = widget.cartItems.isNotEmpty
        ? (widget.cartItems.first['retailerName'] as String? ?? 'Retailer')
        : 'Retailer';
    final String retailerId = widget.cartItems.isNotEmpty
        ? (widget.cartItems.first['retailerId'] as String? ?? '')
        : '';
    final GuidedVisitContext? guidedContext = widget.guidedVisitContext;
    final bool needsPriceReads =
        !hasInFlightOrderCommit && _pendingOrderId.trim().isEmpty;

    final Future<Map<String, dynamic>?> profileRead =
        _resolveSalesmanSnapshot();
    profileRead.ignore();
    Future<void>? limitsRead;
    Future<List<_PriceChange>>? priceRead;
    Future<AssignedVisitOrderRecoveryResult>? recoveryRead;
    if (!localChecksFail) {
      final bool limitsFresh =
          _limitsConfirmedAt != null &&
          DateTime.now().difference(_limitsConfirmedAt!) <
              const Duration(seconds: 60);
      final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>?
      serverProducts = needsPriceReads ? _readProductsFromServer() : null;
      limitsRead = () async {
        await _productLimitsRefresh;
        if (!mounted || limitsFresh) return;
        await _refreshProductLimits(
          showLimitNotice: false,
          serverReads: serverProducts,
        );
      }();
      limitsRead.ignore();
      if (needsPriceReads) {
        priceRead = _currentPriceChanges(
          Source.server,
          productReads: serverProducts,
        ).timeout(const Duration(seconds: 10));
        priceRead.ignore();
      }
      final String? authUid = FirebaseAuth.instance.currentUser?.uid;
      if (_pendingOrderCommit == null &&
          guidedContext != null &&
          authUid != null) {
        recoveryRead = AssignedVisitOrderRecovery().resolve(
          salesmanUid: authUid,
          retailerId: retailerId,
          routePlanId: guidedContext.planId,
          routeStopId: guidedContext.stopId,
        );
        recoveryRead.ignore();
      }
    }

    final Map<String, dynamic>? salesmanSnapshot;
    try {
      salesmanSnapshot = await profileRead;
    } catch (error) {
      debugPrint('Order not sent, profile unreachable: $error');
      await _keepUnsentDraft(
        timedOut: error is TimeoutException,
        causeUnknown: !isOfflineFailure(error),
      );
      return;
    }

    if (salesmanSnapshot == null) {
      if (!mounted) return;
      setState(() => _submitting = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Login session expired. Please log in again before submitting.',
          ),
        ),
      );

      return;
    }

    if (!hasInFlightOrderCommit && invalidItems.isNotEmpty) {
      setState(() {
        _submitting = false;
        for (final item in invalidItems) {
          _remarksErrors[item.no] = RemarksValidator.validate(item.remarks);
        }
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please fix the remarks for: '
            '${invalidItems.map((i) => i.productName).join(', ')}',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    if (missingProductIds.isNotEmpty) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Product identity is missing for: ${missingProductIds.map((item) => item.productName).join(', ')}. Return to the cart to resolve it.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    await limitsRead;
    if (!mounted) return;
    final List<SignatureOrderItem> unavailableItems = _orderItems
        .where(
          (item) =>
              item.orderQty > 0 &&
              _unavailableProductIds.contains(item.productId),
        )
        .toList(growable: false);
    if (unavailableItems.isNotEmpty) {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'These products are no longer available to order: ${unavailableItems.map((item) => item.productName).join(', ')}.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }
    final invalidItem = _orderItems.firstWhere(
      (item) => item.orderQty > item.maxOrderQty,
      orElse: () => SignatureOrderItem(
        no: -1,
        productName: '',
        packingSize: '',
        unitPrice: 0,
        orderQty: 0,
        stockOnShelf: 0,
        department: '',
        shelfBatches: [],
        orderedExpiry: '',
      ),
    );

    if (!hasInFlightOrderCommit && invalidItem.no != -1) {
      if (!mounted) return;
      setState(() => _submitting = false);

      _showMaxQuantityDialog(
        '${invalidItem.productName} exceeds the maximum of '
        '${quantityLabel(invalidItem.maxOrderQty, invalidItem.uom)}.',
      );

      return;
    }

    if (priceRead != null) {
      final List<_PriceChange> changes;
      try {
        changes = await priceRead;
      } catch (error) {
        debugPrint('Order not sent, server unreachable: $error');
        await _keepUnsentDraft(
          timedOut: error is TimeoutException,
          causeUnknown: !isOfflineFailure(error),
        );
        return;
      }
      if (!mounted) return;
      if (changes.isNotEmpty) {
        setState(() {
          _priceChanges = changes;
          _submitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Prices changed. Review them before submitting.'),
          ),
        );
        return;
      }
    }

    final String specialRequestSalesmanCode =
        salesmanSnapshot['ruleSalesmanCode'] as String? ?? '';
    final String specialRequestBranchId =
        salesmanSnapshot['branchId'] as String? ?? '';
    if (!hasInFlightOrderCommit &&
        _specialRequestType != null &&
        (_specialRequestText.trim().isEmpty ||
            specialRequestSalesmanCode.isEmpty ||
            specialRequestBranchId.isEmpty)) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _specialRequestText.trim().isEmpty
                ? 'Describe the special request or remove it before submitting.'
                : 'Your profile has no salesman code or branch, so a special request cannot be sent. Remove it or contact an administrator.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    for (final item in _orderItems) {
      item.remarks = _remarksControllers[item.no]?.text ?? '';
    }
    final identity = _salesmanIdentityFields(salesmanSnapshot);
    final salesmanId = salesmanSnapshot['salesmanId'] as String;
    final salesmanName = salesmanSnapshot['salesmanName'] as String;
    final salesmanUid = salesmanSnapshot['salesmanUid'] as String;
    final salesmanEmail = salesmanSnapshot['salesmanEmail'] as String;

    final submittedAt = DateTime.now();
    final position = locationAllowed ? await _tryGetSubmitPosition() : null;
    if (!hasInFlightOrderCommit &&
        (_unsignChangedDepartments() || !_allSigned)) {
      _persistSignOffState();
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Changed after signing. Ask the shop to sign again.'),
        ),
      );
      return;
    }
    final Map<String, dynamic> positionFields = _orderLocationFields(
      position,
      now: DateTime.now(),
      disabledByUser: !locationAllowed,
    );
    final bool usablePosition = positionFields.containsKey('location');
    final Map<String, dynamic> trackingLocationFields = usablePosition
        ? positionFields
        : const <String, dynamic>{};
    final Map<String, dynamic> orderLocationFields = usablePosition
        ? const <String, dynamic>{}
        : positionFields;

    final signatureTimestamps = <String, String>{
      for (final dept in _activeDepartments)
        if (_deptSignedAt[dept] != null)
          dept: _formatTimestamp(_deptSignedAt[dept]!),
    };

    final activeItems = _orderItems.where((item) => item.orderQty > 0).toList();
    final List<Map<String, dynamic>> serialisedItems = activeItems
        .map<Map<String, dynamic>>(submittedOrderLine)
        .toList();

    final String? orderValidationError = OrderSubmissionContract.validateItems(
      serialisedItems,
    );
    if (!hasInFlightOrderCommit && orderValidationError != null) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(orderValidationError),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }
    final List<String> commercialLines =
        OrderSubmissionContract.commercialLines(serialisedItems);

    final String previousPendingOrderId = _pendingOrderId.trim();
    var orderId = guidedContext == null
        ? resolveOrderSubmissionId(previousPendingOrderId, submittedAt)
        : assignedVisitOrderId(
            salesmanUid: salesmanUid,
            routePlanId: guidedContext.planId,
            routeStopId: guidedContext.stopId,
          );
    var orderConfirmed = false;

    if (_pendingOrderCommit == null && guidedContext != null) {
      final AssignedVisitOrderRecoveryResult recovery =
          await (recoveryRead ??
              AssignedVisitOrderRecovery().resolve(
                salesmanUid: salesmanUid,
                retailerId: retailerId,
                routePlanId: guidedContext.planId,
                routeStopId: guidedContext.stopId,
              ));
      switch (recovery.status) {
        case AssignedVisitOrderRecoveryStatus.submitted:
          orderId = recovery.orderId;
          orderConfirmed = true;
        case AssignedVisitOrderRecoveryStatus.pending:
          _pendingOrderId = recovery.orderId.isEmpty
              ? orderId
              : recovery.orderId;
          _persistSignOffState();
          if (!mounted) return;
          setState(() => _submitting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Submission is still pending. This visit will reuse the same order identity.',
              ),
            ),
          );
          return;
        case AssignedVisitOrderRecoveryStatus.conflict:
          if (!mounted) return;
          setState(() => _submitting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Existing order data for this stop does not match the retailer. Ask a manager to review it.',
              ),
            ),
          );
          return;
        case AssignedVisitOrderRecoveryStatus.unavailable:
          if (previousPendingOrderId.isNotEmpty) {
            _pendingOrderId = previousPendingOrderId;
            _persistSignOffState();
            if (!mounted) return;
            setState(() => _submitting = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  unavailableEarlierSubmissionMessage(recovery.cause),
                ),
              ),
            );
            return;
          }
          await _keepUnsentDraft(
            timedOut: recovery.cause == AssignedVisitOrderRecoveryCause.timeout,
            causeUnknown:
                recovery.cause == AssignedVisitOrderRecoveryCause.unknown,
          );
          return;
        case AssignedVisitOrderRecoveryStatus.absent:
          break;
      }
    }

    final bool isRetry = previousPendingOrderId == orderId;
    _pendingOrderId = orderId;
    final CartDraftPersistenceResult pendingIdSaved =
        await CartDraftCache.saveAndWait(_draftKey, _signOffDraft());
    if (!pendingIdSaved.isSaved) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Order was not queued because its retry identity could not be saved. Try again.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }
    unawaited(_persistSignatureDraft());

    final activeTotalBoxes = activeItems.fold(0, (s, i) => s + i.orderQty);
    final activeTotalPrice = activeItems.fold(0.0, (s, i) => s + i.subtotal);
    final Map<String, dynamic> orderIdentity = <String, dynamic>{
      'uid': salesmanUid,
      'userUid': salesmanUid,
      'salesmanUid': salesmanUid,
      'salesmanEmail': salesmanEmail,
      'salesmanId': salesmanId,
      'salesmanCode': specialRequestSalesmanCode.isNotEmpty
          ? specialRequestSalesmanCode
          : salesmanId,
      'salesmanName': salesmanName,
      'submittedByUid': salesmanUid,
      'createdByUid': salesmanUid,
      if ((identity['branchId'] as String? ?? '').isNotEmpty)
        'branchId': identity['branchId'],
      if ((identity['supervisorId'] as String? ?? '').isNotEmpty)
        'supervisorId': identity['supervisorId'],
    };

    final orderData = <String, dynamic>{
      'orderId': orderId,
      if (_visitId.isNotEmpty) 'visitId': _visitId,
      if (widget.guidedVisitContext == null) 'visitSource': 'personal_planner',
      ...?widget.guidedVisitContext?.orderFields,
      'retailerId': retailerId,
      'retailerName': retailerName,
      'outlet': retailerName,
      ...orderIdentity,
      ...orderLocationFields,
      'totalProducts': activeItems.length,
      'totalBoxes': activeTotalBoxes,
      'totalPrice': activeTotalPrice,
      'submittedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'status': 'submitted',
      'items': serialisedItems,
      'commercialSchemaVersion': OrderSubmissionContract.schemaVersion,
      'commercialLines': commercialLines,
      'signatureTimestamps': signatureTimestamps,
    };

    final trackingData = <String, dynamic>{
      ...identity,
      ...trackingLocationFields,
      'salesmanUid': salesmanUid,
      'salesmanId': salesmanId,
      'salesmanName': salesmanName,
      'salesmanEmail': salesmanEmail,
      'lastOrderId': orderId,
      'lastRetailerId': retailerId,
      'lastRetailerName': retailerName,
      'timestamp': FieldValue.serverTimestamp(),
      'lastSeen': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'status': 'active',
    };
    final firestore = FirebaseFirestore.instance;
    final userDocId = salesmanSnapshot['userDocId'] as String? ?? salesmanUid;
    final orderRef = firestore.collection('orders').doc(orderId);
    if (!orderConfirmed && _pendingOrderCommit == null && isRetry) {
      final recovery = await _recoverPendingOrder(
        orderRef,
        salesmanUid: salesmanUid,
        retailerId: retailerId,
        routePlanId: guidedContext?.planId,
        routeStopId: guidedContext?.stopId,
      );
      if (recovery == _PendingOrderRecovery.confirmed) {
        orderConfirmed = true;
      } else if (recovery == _PendingOrderRecovery.pending) {
        if (!mounted) return;
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _specialRequestType == null
                  ? 'Submission is still pending. Your draft was kept on this device.'
                  : 'Submission is still pending. Your draft was kept on this device. Special request will be sent when the order syncs.',
            ),
          ),
        );
        return;
      } else if (recovery == _PendingOrderRecovery.conflict) {
        if (!mounted) return;
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The pending order identity does not match this draft. Check Order History before retrying.',
            ),
          ),
        );
        return;
      }
    }

    void notify(SnackBar bar) {
      if (messenger?.mounted ?? false) messenger!.showSnackBar(bar);
    }

    Future<void> sendSpecialRequest() async {
      final String? type = _specialRequestType;
      if (type == null || _specialRequestIssuedFor == orderId) return;
      final Map<String, dynamic>? payload = SpecialRequestPayload.build(
        orderId: orderId,
        typeCode: type,
        description: _specialRequestText,
        retailerName: retailerName,
        salesmanCode: specialRequestSalesmanCode,
        branchId: specialRequestBranchId,
        salesmanUid: salesmanUid,
        retailerId: _retailerId,
        selectedProductId: _specialRequestProductId,
      );
      if (payload == null) return;
      try {
        await firestore
            .collection('special_requests')
            .doc(SpecialRequestPayload.docId(orderId))
            .set(payload)
            .timeout(const Duration(seconds: 10));
        _specialRequestIssuedFor = orderId;
      } on TimeoutException {
        _specialRequestIssuedFor = orderId;
        notify(
          const SnackBar(
            content: Text('Special request will be sent when online.'),
          ),
        );
      } catch (error) {
        if (error is FirebaseException &&
            error.code == 'permission-denied' &&
            await _specialRequestExists(firestore, orderId)) {
          _specialRequestIssuedFor = orderId;
          return;
        }
        debugPrint('Special request write failed: $error');
        notify(
          SnackBar(
            duration: const Duration(seconds: 8),
            content: const Text(
              'Special request was not sent. Check your connection.',
            ),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => unawaited(sendSpecialRequest()),
            ),
          ),
        );
      }
    }

    Future<void>? specialRequestInFlight;
    Future<void> issueSpecialRequest() {
      return specialRequestInFlight ??= sendSpecialRequest().whenComplete(
        () => specialRequestInFlight = null,
      );
    }

    if (!orderConfirmed) {
      await HeldWorkSync().recordOrder(
        uid: salesmanUid,
        orderId: orderId,
        orderData: orderData,
        trackingData: trackingLocationFields.isEmpty ? null : trackingData,
      );
      final commit =
          _pendingOrderCommit ??
          () {
            return orderRef.set(orderData);
          }();
      _pendingOrderCommit = commit;
      unawaited(issueSpecialRequest());
      if (trackingLocationFields.isNotEmpty) {
        unawaited(
          _writeOrderTrackingAfter(commit, firestore, orderId, trackingData),
        );
      }

      try {
        await commit.timeout(const Duration(seconds: 10));
        if (identical(_pendingOrderCommit, commit)) {
          _pendingOrderCommit = null;
        }
      } on TimeoutException {
        unawaited(
          _finishWhenOrderLands(
            commit,
            orderId: orderId,
            salesmanUid: salesmanUid,
            guidedContext: guidedContext,
          ),
        );
        _persistSignOffState();
        if (!mounted) return;
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Submission is still pending. Your draft was kept on this device.',
            ),
          ),
        );
        return;
      } catch (error) {
        if (identical(_pendingOrderCommit, commit)) {
          _pendingOrderCommit = null;
        }
        if (guidedContext != null) {
          final AssignedVisitOrderRecoveryResult recovery =
              await AssignedVisitOrderRecovery().resolve(
                salesmanUid: salesmanUid,
                retailerId: retailerId,
                routePlanId: guidedContext.planId,
                routeStopId: guidedContext.stopId,
              );
          if (recovery.status == AssignedVisitOrderRecoveryStatus.submitted) {
            orderConfirmed = true;
          }
        }
        if (orderConfirmed) {
        } else {
          debugPrint('Order commit failed: $error');
          final lifecycle = await CompanyLifecycleMonitor.instance.refresh(
            upload: false,
          );
          if (HeldWorkPolicy.classify(error, lifecycle?.access) ==
                  WriteFailure.held &&
              await HeldWorkSync().holdOrder(salesmanUid, orderId)) {
            unawaited(CompanyLifecycleMonitor.instance.refresh());
            if (!mounted) return;
            setState(() => _submitting = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'The company is paused. ${companyPausedKeptText(lifecycle?.state)}',
                ),
              ),
            );
            return;
          }
          if (!mounted) return;
          setState(() => _submitting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not submit the order. Check your connection and retry.',
              ),
            ),
          );
          return;
        }
      }
    }

    await issueSpecialRequest();
    unawaited(HeldWorkSync().forgetOrder(salesmanUid, orderId));

    var confirmedItems = serialisedItems;
    var confirmedTotalProducts = activeItems.length;
    var confirmedTotalBoxes = activeTotalBoxes;
    var confirmedTotalPrice = activeTotalPrice;
    var confirmedSubmittedAt = submittedAt;
    try {
      final confirmed = await orderRef.get(
        const GetOptions(source: Source.cache),
      );
      final data = confirmed.data();
      if (confirmed.exists &&
          data != null &&
          matchesOrderSubmissionIdentity(
            data,
            orderId: orderId,
            salesmanUid: salesmanUid,
            retailerId: retailerId,
          )) {
        final rawItems = data['items'];
        final recoveredItems = rawItems is List
            ? rawItems
                  .whereType<Map>()
                  .map((item) => Map<String, dynamic>.from(item))
                  .toList()
            : <Map<String, dynamic>>[];
        final List<CommercialOrderLine>? recoveredCommercial =
            OrderSubmissionContract.readCommercialLines(data);
        if (recoveredCommercial != null) {
          confirmedItems = List<Map<String, dynamic>>.generate(
            recoveredCommercial.length,
            (int index) => <String, dynamic>{
              if (index < recoveredItems.length) ...recoveredItems[index],
              'name': recoveredCommercial[index].productName,
              'productName': recoveredCommercial[index].productName,
              'productId': recoveredCommercial[index].productId,
              'qty': recoveredCommercial[index].quantity,
              'price': recoveredCommercial[index].unitPrice,
            },
          );
          confirmedTotalProducts = recoveredCommercial.length;
          confirmedTotalBoxes = recoveredCommercial.fold<int>(
            0,
            (int total, CommercialOrderLine line) => total + line.quantity,
          );
          confirmedTotalPrice =
              recoveredCommercial.fold<int>(
                0,
                (int total, CommercialOrderLine line) =>
                    total + line.lineTotalCents,
              ) /
              100;
        } else if (recoveredItems.isNotEmpty) {
          confirmedItems = recoveredItems;
          confirmedTotalProducts =
              (data['totalProducts'] as num?)?.toInt() ?? confirmedItems.length;
          confirmedTotalBoxes =
              (data['totalBoxes'] as num?)?.toInt() ?? confirmedTotalBoxes;
          confirmedTotalPrice =
              (data['totalPrice'] as num?)?.toDouble() ?? confirmedTotalPrice;
        }
        final rawSubmittedAt = data['submittedAt'];
        if (rawSubmittedAt is Timestamp) {
          confirmedSubmittedAt = rawSubmittedAt.toDate();
        } else if (rawSubmittedAt is DateTime) {
          confirmedSubmittedAt = rawSubmittedAt;
        }
      }
    } catch (_) {}

    final WriteBatch sideEffectBatch = firestore.batch();
    sideEffectBatch.set(firestore.collection('users').doc(userDocId), {
      'uid': salesmanUid,
      'lastOrderId': orderId,
      'lastOrderAt': FieldValue.serverTimestamp(),
      if (trackingLocationFields.isNotEmpty) ...{
        'lastLatitude': trackingLocationFields['latitude'],
        'lastLongitude': trackingLocationFields['longitude'],
        'lastSeen': FieldValue.serverTimestamp(),
        'lastLocationCapturedAt': trackingLocationFields['deviceCapturedAt'],
      },
    }, SetOptions(merge: true));
    unawaited(
      sideEffectBatch.commit().timeout(const Duration(seconds: 10)).catchError((
        Object error,
      ) {
        debugPrint('Order side-effect writes failed: $error');
      }),
    );

    final visitId = _visitId;
    if (visitId.isNotEmpty) {
      unawaited(
        markVisitSubmitted(
          firestore,
          visitId: visitId,
          orderId: orderId,
        ).catchError((Object error) {
          debugPrint('Failed to update planned visit progress: $error');
        }),
      );
    }

    CartDraftCache.clear(_draftKey);
    if (guidedContext != null) {
      await GuidedVisitSessionStore.markOrderSubmitted(
        salesmanUid: salesmanUid,
        routePlanId: guidedContext.planId,
        routeStopId: guidedContext.stopId,
      );
    }

    if (!mounted) return;

    if (orderLocationFields.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 6),
          content: Text(
            'The order was sent without a verified location. '
            'Your manager will see it as not verified.',
          ),
        ),
      );
    }

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => OrderConfirmationScreen(
          orderId: orderId,
          salesmanId: salesmanId,
          salesmanName: salesmanName,
          totalProducts: confirmedTotalProducts,
          totalBoxes: confirmedTotalBoxes,
          submittedAt: confirmedSubmittedAt,
          cartItems: confirmedItems,
          retailerName: retailerName,
          locationMode:
              positionFields['locationVerification'] as String? ??
              'not_verified',
          locationReason: locationAllowed
              ? 'The phone had no reliable fix.'
              : 'Location sharing is off in Profile.',
          onGoBackHome: () {},
          onCreateNewOrder: () {},
          onGoToScheduler: () {},
          returnToVisitLabel: guidedContext == null ? null : 'Continue visit',
          onReturnToVisit: guidedContext == null ? null : () {},
        ),
      ),
      (route) =>
          route.isFirst ||
          (guidedContext != null &&
              route.settings.name == guidedContext.routeName),
    );
  }

  Future<void> _finishWhenOrderLands(
    Future<void> commit, {
    required String orderId,
    required String salesmanUid,
    required GuidedVisitContext? guidedContext,
  }) async {
    final String draftKey = _draftKey;
    final String visitId = _visitId;
    try {
      await commit;
    } catch (_) {
      return;
    }
    unawaited(HeldWorkSync().forgetOrder(salesmanUid, orderId));
    if (CartDraftCache.read(draftKey)?.pendingOrderId.trim() != orderId) {
      return;
    }
    if (visitId.isNotEmpty) {
      unawaited(
        markVisitSubmitted(
          FirebaseFirestore.instance,
          visitId: visitId,
          orderId: orderId,
        ).catchError((Object error) {
          debugPrint('Failed to update planned visit progress: $error');
        }),
      );
    }
    CartDraftCache.clear(draftKey);
    if (guidedContext != null) {
      await GuidedVisitSessionStore.markOrderSubmitted(
        salesmanUid: salesmanUid,
        routePlanId: guidedContext.planId,
        routeStopId: guidedContext.stopId,
      );
    }
  }

  void _persistSignOffState() {
    _signatureCacheDirty = false;
    CartDraftCache.save(_draftKey, _signOffDraft());
  }

  CartDraftSnapshot _signOffDraft() {
    for (final item in _orderItems) {
      item.remarks = _remarksControllers[item.no]?.text ?? '';
    }

    return CartDraftSnapshot(
      salesmanUid: _salesmanUid,
      retailerId: _retailerId,
      visitId: _visitId,
      progress: 4,
      pendingOrderId: _pendingOrderId,
      items: _snapshotSignOffItems(),
      signatures: _snapshotSignatures(),
      specialRequest: _specialRequestType == null
          ? null
          : <String, dynamic>{
              'type': _specialRequestType,
              'description': _specialRequestText,
              'selectedProductId': _specialRequestProductId,
            },
    );
  }

  void _scheduleSignatureAutosave() {
    _persistSignOffState();
    _restartAutosaveTimer();
  }

  void _restartAutosaveTimer() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 500), () {
      if (_signatureCacheDirty) _persistSignOffState();
      unawaited(_persistSignatureDraft());
    });
  }

  Future<void> _persistSignatureDraft() async {
    final visitId = _visitId;
    if (visitId.isEmpty) return;

    try {
      await FirebaseFirestore.instance.collection('visits').doc(visitId).update(
        {
          'draftStage': 4,
          'signatureDraft': {
            if (_pendingOrderId.isNotEmpty) 'pendingOrderId': _pendingOrderId,
            'items': _snapshotSignOffItems(),
            'signatures': _snapshotSignatures(),
          },
          'pendingSignatures': _unsignedDepartments,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );
    } catch (error) {
      debugPrint('Failed to autosave sign-off draft: $error');
    }
  }

  Future<void> _saveDraft() async {
    if (_submitting) return;
    final CartDraftPersistenceResult saved = await CartDraftCache.saveAndWait(
      _draftKey,
      _signOffDraft(),
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
    unawaited(_persistSignatureDraft());

    final retailerName = widget.cartItems.isNotEmpty
        ? (widget.cartItems.first['retailerName'] as String? ?? 'Retailer')
        : 'Retailer';
    final retailerId = widget.cartItems.isNotEmpty
        ? (widget.cartItems.first['retailerId'] as String? ?? '')
        : '';

    final unsignedDepts = _unsignedDepartments;
    final visitId = _visitId;
    if (visitId.isNotEmpty) {
      FirebaseFirestore.instance.collection('visits').doc(visitId).update({
        'progress': 4,
        'status': 'pending_signature',
        'pendingSignatures': unsignedDepts,
        'signOffDraftAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    final draftSnapshot = _orderItems
        .map(
          (item) => {
            'name': item.productName,
            if (item.productId.isNotEmpty) 'productId': item.productId,
            if (item.barcode.isNotEmpty) 'barcode': item.barcode,
            'packingSize': item.packingSize,
            if (item.uom != null) 'uom': item.uom,
            'department': item.department,
            'qty': item.orderQty,
            'expiry': item.orderedExpiry,
          },
        )
        .toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DraftSavedScreen(
          retailerName: retailerName,
          retailerId: retailerId,
          visitId: visitId,
          guidedVisitContext: widget.guidedVisitContext,
          source: DraftSource.signOff,
          items: draftSnapshot,
          signedDepartments: _activeDepartments
              .where((d) => _deptSigned[d] == true)
              .toSet(),
          onResume: () => Navigator.pop(context),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    _voiceBinding.updateContext(
      uid: auth.user?.uid ?? _salesmanUid,
      role: auth.user?.role ?? '',
      retailerId: _retailerId,
      visitId: _visitId,
      routePlanId: widget.guidedVisitContext?.planId,
      routeStopId: widget.guidedVisitContext?.stopId,
      draftId: _draftKey,
    );
    return Scaffold(
      backgroundColor: ScootColors.of(context).page,
      appBar: _buildTopBar(
        CopilotEntryButton(
          screen: CopilotScreenContext(
            engine: _voiceEngine,
            suggestions: _copilotSuggestions,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const ScootStepBar(
              current: 2,
              steps: <String>['Select', 'Count', 'Sign-off'],
            ),
            if (_pendingOrderId.trim().isNotEmpty) _buildUncertainSubmission(),
            if (_priceChanges.isNotEmpty) _buildPriceReview(),
            if (_activeDepartments.isNotEmpty) ...[
              _buildTabBar(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: _activeDepartments
                      .map((dept) => _buildDeptTab(dept))
                      .toList(),
                ),
              ),
            ] else
              const Expanded(child: Center(child: Text('No items in cart.'))),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [_buildGlobalActionBar()],
        ),
      ),
    );
  }

  Future<void> _editSpecialRequest() async {
    final salesmanSnapshot = await _resolveSalesmanSnapshot();
    final salesmanCode = salesmanSnapshot?['ruleSalesmanCode'] as String? ?? '';
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> choices = [];
    bool choicesUnavailable = false;
    try {
      final products = await FirebaseFirestore.instance
          .collection('products')
          .get();
      final settings =
          (await FirebaseFirestore.instance
                  .collection('retailer_score_sheet_settings')
                  .doc(_retailerId)
                  .get()
                  .timeout(const Duration(seconds: 10)))
              .data() ??
          {};
      final visible = (settings['visibleProductIds'] as List?) ?? [];
      final hidden = (settings['hiddenProductIds'] as List?) ?? [];
      final disabled = (settings['disabledProductIds'] as List?) ?? [];
      final overrides = (settings['productOverrides'] as Map?) ?? {};
      for (final doc in products.docs) {
        final data = {...doc.data(), 'docId': doc.id};
        final product = ProductItem.fromFirestore(data);
        final override = Map<String, dynamic>.from(
          (overrides[product.productId] as Map?) ?? {},
        );
        final effective = {
          ...data,
          for (final entry in override.entries)
            if (entry.value != null) entry.key: entry.value,
        };
        final createdAt = data['createdAt'];
        final updatedAt = settings['updatedAt'];
        final newlyCreated =
            createdAt is Timestamp &&
            updatedAt is Timestamp &&
            createdAt.compareTo(updatedAt) > 0;
        final available =
            !hidden.contains(product.productId) &&
            !disabled.contains(product.productId) &&
            (visible.isEmpty ||
                visible.contains(product.productId) ||
                newlyCreated) &&
            isOrderableCatalogueProduct(effective);
        if (isOrderableCatalogueProduct(data) &&
            product.name.isNotEmpty &&
            product.name.length <= 200 &&
            !available) {
          choices.add(doc);
        }
      }
      choices.sort(
        (a, b) => ProductItem.fromFirestore(
          a.data(),
        ).name.compareTo(ProductItem.fromFirestore(b.data()).name),
      );
    } catch (_) {
      choicesUnavailable = true;
    }
    if (!mounted) return;
    String? type = _specialRequestType ?? SpecialRequestType.all.first.code;
    bool descriptionMissing = false;
    String selected = choices.any((doc) => doc.id == _specialRequestProductId)
        ? _specialRequestProductId
        : '';
    final TextEditingController controller = TextEditingController(
      text: _specialRequestText,
    );
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setLocal) => AlertDialog(
          scrollable: true,
          title: const Text('Special request'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('special_request_type'),
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final SpecialRequestType t in SpecialRequestType.all)
                    DropdownMenuItem(value: t.code, child: Text(t.label)),
                ],
                onChanged: (String? value) => setLocal(() => type = value),
              ),
              const SizedBox(height: 12),
              if (type == 'non_catalogue_item') ...[
                if (choicesUnavailable)
                  const Text(
                    'Items could not be loaded. Use Other (describe).',
                  ),
                DropdownButtonFormField<String>(
                  key: const Key('special_request_product'),
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Non-catalogue item',
                  ),
                  items: [
                    for (final doc in choices)
                      DropdownMenuItem(
                        value: doc.id,
                        child: Text(
                          '${ProductItem.fromFirestore(doc.data()).name} [${doc.id}]',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Other (describe)'),
                    ),
                  ],
                  onChanged: (value) => setLocal(() => selected = value ?? ''),
                ),
                const SizedBox(height: 12),
              ],
              if (type != 'non_catalogue_item' || selected.isEmpty)
                TextField(
                  key: const Key('special_request_description'),
                  controller: controller,
                  maxLines: type == 'non_catalogue_item' ? 1 : 3,
                  maxLength: type == 'non_catalogue_item'
                      ? 200
                      : SpecialRequestPayload.maxDescriptionLength,
                  decoration: InputDecoration(
                    errorText: descriptionMissing
                        ? 'Enter a description or choose an item.'
                        : null,
                    labelText: type == 'non_catalogue_item'
                        ? 'Other item (describe)'
                        : 'Description',
                  ),
                ),
              const SizedBox(height: 12),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('special_requests')
                    .where('salesmanCode', isEqualTo: salesmanCode)
                    .where(
                      'createdByUid',
                      isEqualTo: FirebaseAuth.instance.currentUser?.uid ?? '',
                    )
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError || salesmanCode.isEmpty) {
                    return const Text(
                      'Request status could not be loaded. Check your connection and profile.',
                    );
                  }
                  final requests =
                      (snapshot.data?.docs ?? [])
                          .where(
                            (doc) => doc.data()['retailerId'] == _retailerId,
                          )
                          .toList()
                        ..sort(
                          (a, b) =>
                              ((b.data()['createdAt'] as Timestamp?)
                                          ?.millisecondsSinceEpoch ??
                                      0)
                                  .compareTo(
                                    (a.data()['createdAt'] as Timestamp?)
                                            ?.millisecondsSinceEpoch ??
                                        0,
                                  ),
                        );
                  return Column(
                    children: [
                      for (final request in requests.take(3))
                        Text(
                          '${request.data()['requestedItem']}: ${request.data()['status'] == 'approved'
                              ? request.data()['catalogueProductId'] == null
                                    ? 'Approved - awaiting admin to add product'
                                    : 'Approved - added to catalogue'
                              : request.data()['status']}',
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
          actions: [
            if (_specialRequestType != null)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'remove'),
                child: const Text('Remove'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if ((type != 'non_catalogue_item' || selected.isEmpty) &&
                    controller.text.trim().isEmpty) {
                  setLocal(() => descriptionMissing = true);
                  return;
                }
                Navigator.pop(dialogContext, 'save');
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final String description =
        type == 'non_catalogue_item' && selected.isNotEmpty
        ? ProductItem.fromFirestore(
            choices.firstWhere((doc) => doc.id == selected).data(),
          ).name
        : controller.text.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (!mounted || action == null) return;
    setState(() {
      if (action == 'remove' || description.isEmpty) {
        _specialRequestType = null;
        _specialRequestText = '';
        _specialRequestProductId = '';
      } else {
        _specialRequestType = type;
        _specialRequestText = description;
        _specialRequestProductId = type == 'non_catalogue_item' ? selected : '';
      }
    });
    _scheduleSignatureAutosave();
  }

  Widget _buildSpecialRequestRow() {
    final SpecialRequestType? type = SpecialRequestType.byCode(
      _specialRequestType,
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        label: 'Special request',
        button: true,
        enabled: !_submitting,
        onTap: _submitting ? null : _editSpecialRequest,
        child: ExcludeSemantics(
          child: FilledButton.icon(
            key: const Key('special_request_button'),
            onPressed: _submitting ? null : _editSpecialRequest,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              minimumSize: const Size(0, 48),
              visualDensity: VisualDensity.standard,
            ),
            icon: Icon(
              type == null ? Icons.flag_outlined : Icons.flag,
              size: 18,
            ),
            label: Text(
              type == null
                  ? 'Flag a special request'
                  : 'Special request: ${type.label}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }

  List<String> get _copilotSuggestions {
    if (_orderItems.isEmpty) return const <String>[];
    final String name = _orderItems.first.productName
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String word) => RegExp(r'^[a-z]+$').hasMatch(word))
        .take(3)
        .join(' ');
    return name.isEmpty ? const <String>[] : <String>['Set $name to 2 boxes'];
  }

  PreferredSizeWidget _buildTopBar(Widget copilot) {
    final retailerName = widget.cartItems.isNotEmpty
        ? (widget.cartItems.first['retailerName'] as String? ?? 'Retailer')
        : 'Retailer';
    return ScootPhoneAppBar(
      title: retailerName,
      subtitle: retailerCodeLabel(_retailerId, retailerName: retailerName),
      onBack: () {
        _persistSignOffState();
        unawaited(_persistSignatureDraft());
        Navigator.pop(context);
      },
      actions: <Widget>[copilot],
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: Colors.white,
      child: TabBar(
        controller: _tabController,
        isScrollable: _activeDepartments.length > 3,
        labelColor: AppColors.textGreen,
        unselectedLabelColor: AppColors.textGrey,
        indicatorColor: kPrimaryGreen,
        indicatorWeight: 3,
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        tabs: _activeDepartments.map((dept) {
          final count = _byDepartment[dept]!.length;
          final signed = _deptSigned[dept] == true;
          return Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(dept),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: kPrimaryGreen.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textGreen,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (signed) ...[
                  const SizedBox(width: 4),
                  Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: kPrimaryGreen,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      color: Colors.white,
                      size: 10,
                    ),
                  ),
                ],
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDeptTab(String dept) {
    final items = _byDepartment[dept]!;
    final points = _deptPoints[dept]!;
    final signed = _deptSigned[dept] == true;
    final signedAt = _deptSignedAt[dept];

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: items.length + 2,
      separatorBuilder: (_, i) => i < items.length - 1
          ? const SizedBox(height: 10)
          : const SizedBox(height: 12),
      itemBuilder: (_, i) {
        if (i < items.length) return _buildProductCard(items[i]);
        if (i == items.length + 1) return _buildSpecialRequestRow();

        return Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: signed
                  ? kPrimaryGreen.withValues(alpha: 0.4)
                  : Colors.grey.shade200,
              width: signed ? 1.5 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '$dept Authorization',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (signed)
                      const Icon(
                        Icons.check_circle,
                        color: kPrimaryGreen,
                        size: 18,
                      ),
                  ],
                ),
                const SizedBox(height: 10),

                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    height: 110,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: signed ? kPrimaryGreen : Colors.grey.shade300,
                        width: signed ? 1.5 : 1,
                      ),
                    ),
                    child: Builder(
                      builder: (ctx) => RawGestureDetector(
                        behavior: HitTestBehavior.deferToChild,
                        gestures: <Type, GestureRecognizerFactory>{
                          _EagerPanGestureRecognizer:
                              GestureRecognizerFactoryWithHandlers<
                                _EagerPanGestureRecognizer
                              >(() => _EagerPanGestureRecognizer(), (
                                _EagerPanGestureRecognizer recognizer,
                              ) {
                                recognizer
                                  ..onUpdate = (d) {
                                    final box =
                                        ctx.findRenderObject() as RenderBox;
                                    final local = box.globalToLocal(
                                      d.globalPosition,
                                    );
                                    if (local.dx >= 0 &&
                                        local.dy >= 0 &&
                                        local.dx <= box.size.width &&
                                        local.dy <= box.size.height) {
                                      _onPanUpdate(dept, d, box);
                                    }
                                  }
                                  ..onEnd = (d) => _onPanEnd(dept, d);
                              }),
                        },
                        child: CustomPaint(
                          painter: _SignaturePainter(points),
                          child: Container(
                            color: Colors.transparent,
                            alignment: Alignment.center,
                            child: points.isEmpty
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.draw_outlined,
                                        color: Colors.grey.shade400,
                                        size: 22,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Sign here',
                                        style: TextStyle(
                                          color: AppColors.textGrey,
                                          fontSize: 12,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ],
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                if (signed && signedAt != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.access_time_filled,
                        size: 13,
                        color: kPrimaryGreen,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Signed on ${_formatTimestamp(signedAt)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: kVisitedText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 10),

                SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFCCCCCC)),
                      backgroundColor: const Color(0xFFF5F5F5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () => _clearSignature(dept),
                    icon: const Icon(
                      Icons.clear,
                      size: 15,
                      color: Colors.black54,
                    ),
                    label: const Text(
                      'Clear Signature',
                      style: TextStyle(
                        color: AppColors.textGrey,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildUncertainSubmission() {
    return Container(
      width: double.infinity,
      color: kPendingFill,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Text(
        'Submission not confirmed: ${_pendingOrderId.trim()}. '
        'Check Submission looks for this order and never sends a second one.',
        style: const TextStyle(fontSize: 12, color: kPendingText),
      ),
    );
  }

  Widget _buildPriceReview() {
    final bool canAccept = _priceChanges.every(
      (_PriceChange change) => change.newPrice != null,
    );
    return Container(
      width: double.infinity,
      color: kMissedFill,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Prices changed since this draft was saved',
            style: TextStyle(fontWeight: FontWeight.bold, color: kMissedText),
          ),
          const SizedBox(height: 4),
          for (final _PriceChange change in _priceChanges)
            Text(
              change.newPrice == null
                  ? '${change.item.productName}: was RM ${change.item.unitPrice.toStringAsFixed(2)}, now has no valid price'
                  : '${change.item.productName}: was RM ${change.item.unitPrice.toStringAsFixed(2)}, now RM ${change.newPrice!.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 12, color: kMissedText),
            ),
          const SizedBox(height: 6),
          if (canAccept)
            ElevatedButton(
              onPressed: _acceptNewPrices,
              child: const Text('Accept new prices'),
            )
          else
            const Text(
              'Ask an administrator to fix the price before submitting.',
              style: TextStyle(fontSize: 12, color: kMissedText),
            ),
        ],
      ),
    );
  }

  Widget _buildGlobalActionBar() {
    final signed = _allSigned;
    final canSubmit =
        signed && !_hasAnyRemarksError && !_submitting && _priceChanges.isEmpty;
    final bool checkingExistingSubmission = _pendingOrderId.trim().isNotEmpty;
    final String submitLabel = checkingExistingSubmission
        ? 'Check Submission'
        : 'Submit Order';
    final remaining = _activeDepartments
        .where((d) => _deptSigned[d] != true)
        .length;

    return Container(
      color: ScootColors.of(context).card,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      ScootIcons.document,
                      size: 15,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Total (${_orderItems.length} product${_orderItems.length == 1 ? '' : 's'}, $_totalQuantityLabel)',
                      style: TextStyle(fontSize: 12, color: AppColors.textGrey),
                    ),
                  ],
                ),
                Text(
                  'RM ${_totalPrice.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textGreen,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),

          if (_hasAnyRemarksError)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(ScootIcons.error, size: 13, color: Colors.red.shade700),
                  const SizedBox(width: 5),
                  Text(
                    '$_remarksErrorCount remark${_remarksErrorCount == 1 ? '' : 's'} '
                    '${_remarksErrorCount == 1 ? 'has' : 'have'} invalid input — please fix before submitting',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textRed,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

          if (_deptChangedAfterSigning.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Changed after signing. Ask the shop to sign again.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: kMissedText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

          ScootPrimaryActionBar(
            label: _submitting ? 'Sending…' : submitLabel,
            icon: _submitting
                ? ScootIcons.hourglass
                : checkingExistingSubmission
                ? ScootIcons.refresh
                : ScootIcons.upload,
            onPressed: canSubmit ? _submitOrder : null,
            disabledReason: !signed && _activeDepartments.isNotEmpty
                ? '$remaining department${remaining == 1 ? '' : 's'} still need${remaining == 1 ? 's' : ''} a signature'
                : null,
            secondaryLabel: 'Save Draft',
            onSecondary: _submitting || checkingExistingSubmission
                ? null
                : _saveDraft,
          ),
        ],
      ),
    );
  }

  Widget _buildProductCard(SignatureOrderItem item) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: kPrimaryGreen.withValues(alpha: 0.07),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: kPrimaryGreen,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${item.no}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.productName,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      if (item.packingSize.isNotEmpty)
                        Text(
                          item.packingSize,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textGrey,
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: kPrimaryGreen,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    quantityLabel(item.orderQty, item.uom),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.orderedExpiry.isNotEmpty)
                  _infoRow(
                    icon: Icons.shopping_bag_outlined,
                    label: 'Ordered Batch Expiry',
                    value: item.orderedExpiry,
                    valueColor: _expiryColor(item.orderedExpiry),
                  ),
                const SizedBox(height: 8),
                _infoRow(
                  icon: Icons.inventory_2_outlined,
                  label: 'Stock on Shelf',
                  value: quantityLabel(item.stockOnShelf, item.uom),
                  valueColor: Colors.black87,
                ),
                if (item.shelfBatches.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ...item.shelfBatches.asMap().entries.map((e) {
                    final i = e.key + 1;
                    final b = e.value;
                    final bQty = b['qty'] as int? ?? 0;
                    final bExp = b['expiry'] as String? ?? '';
                    if (bQty == 0 && bExp.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(left: 24, bottom: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: Colors.grey,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Batch $i: ${quantityLabel(bQty, item.uom)}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textGrey,
                              ),
                            ),
                          ),
                          if (bExp.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            const Text(
                              '·',
                              style: TextStyle(color: AppColors.textGrey),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _expiryBg(bExp),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                bExp,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _expiryColor(bExp),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(height: 1),
                const SizedBox(height: 10),
                const Text(
                  'Order Quantity',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textGrey,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _qtyButton(
                      icon: Icons.remove,
                      onTap: () => _decreaseQty(item),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 52,
                      child: Semantics(
                        label: 'Order quantity',
                        child: TextField(
                          controller: _qtyControllers[item.no],
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          inputFormatters: [
                            _WholeNumberFormatter(onInvalid: () {}),
                          ],
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                          decoration: InputDecoration(
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 8,
                            ),
                            filled: true,
                            fillColor: Colors.grey.shade50,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: kPrimaryGreen,
                              ),
                            ),
                          ),
                          onChanged: (v) {
                            final q = int.tryParse(v);
                            if (q != null && q >= 0 && q <= item.maxOrderQty) {
                              setState(() => item.orderQty = q);
                              _scheduleSignatureAutosave();
                            } else if (q != null && q > item.maxOrderQty) {
                              setState(() {
                                item.orderQty = item.maxOrderQty;
                                _qtyControllers[item.no]?.text = item
                                    .maxOrderQty
                                    .toString();
                              });
                              _scheduleSignatureAutosave();
                              _showMaxQuantityDialog(
                                'Maximum order quantity is '
                                '${item.maxOrderQty}.',
                              );
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _qtyButton(
                      icon: Icons.add,
                      onTap: () => _increaseQty(item),
                    ),
                    const Spacer(),
                    Text(
                      'RM ${item.subtotal.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textGreen,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () => _pickOrderExpiry(context, item),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.calendar_today,
                          size: 15,
                          color: Colors.grey.shade600,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          item.orderedExpiry.isEmpty
                              ? 'Select Ordered Batch Expiry'
                              : item.orderedExpiry,
                          style: TextStyle(
                            fontSize: 13,
                            color: item.orderedExpiry.isEmpty
                                ? AppColors.textGrey
                                : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Remarks',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textGrey,
                      ),
                    ),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _remarksControllers[item.no]!,
                      builder: (_, value, _) {
                        final used = value.text.length;
                        final remaining = RemarksValidator.maxLength - used;
                        final Color counterColor;
                        if (remaining <= 10) {
                          counterColor = AppColors.textRed;
                        } else if (remaining <= 30) {
                          counterColor = AppColors.textOrange;
                        } else {
                          counterColor = AppColors.textGrey;
                        }
                        return Text(
                          '$remaining remaining',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: remaining <= 30
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: counterColor,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _remarksControllers[item.no],
                  focusNode: _remarksFocusNodes[item.no],
                  inputFormatters: [RemarksInputFormatter()],
                  maxLength: RemarksValidator.maxLength,
                  maxLines: null,
                  minLines: 2,
                  buildCounter:
                      (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                  style: const TextStyle(fontSize: 13),
                  onChanged: (v) {
                    item.remarks = v;
                    final error = RemarksValidator.validate(v);
                    setState(() => _remarksErrors[item.no] = error);
                    _scheduleSignatureAutosave();
                  },
                  decoration: InputDecoration(
                    hintText: 'Add notes for this product…',
                    hintStyle: TextStyle(
                      fontSize: 12,
                      color: AppColors.textGrey,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    filled: true,
                    fillColor: _remarksErrors[item.no] != null
                        ? Colors.red.shade50
                        : Colors.grey.shade50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: _remarksErrors[item.no] != null
                            ? Colors.red.shade400
                            : Colors.grey.shade300,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: _remarksErrors[item.no] != null
                            ? Colors.red.shade500
                            : kPrimaryGreen,
                        width: 1.5,
                      ),
                    ),
                    errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.red.shade400),
                    ),
                    focusedErrorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: Colors.red.shade500,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                if (_remarksErrors[item.no] != null) ...[
                  const SizedBox(height: 5),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 13,
                        color: Colors.red.shade600,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _remarksErrors[item.no]!,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textRed,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _qtyButton({required IconData icon, required VoidCallback onTap}) {
    return Semantics(
      button: true,
      label: icon == Icons.add
          ? 'Increase order quantity'
          : 'Decrease order quantity',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: kPrimaryGreen.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kPrimaryGreen.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, size: 16, color: kPrimaryGreen),
        ),
      ),
    );
  }

  Widget _infoRow({
    required IconData icon,
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.grey),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
        ),
        Flexible(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
        ),
      ],
    );
  }

  Color _expiryColor(String expiry) {
    try {
      final p = expiry.split('/');
      if (p.length != 3) return Colors.black87;
      final d = DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
      final days = d.difference(DateTime.now()).inDays;
      if (days < 0) return kMissedText;
      if (days < 90) return kPendingText;
      return kVisitedText;
    } catch (_) {
      return Colors.black87;
    }
  }

  Color _expiryBg(String expiry) {
    try {
      final p = expiry.split('/');
      if (p.length != 3) return Colors.grey.shade100;
      final d = DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
      final days = d.difference(DateTime.now()).inDays;
      if (days < 0) return kMissedFill;
      if (days < 90) return kPendingFill;
      return kVisitedFill;
    } catch (_) {
      return Colors.grey.shade100;
    }
  }
}

class _SignaturePainter extends CustomPainter {
  final List<Offset?> points;
  _SignaturePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black87
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < points.length - 1; i++) {
      if (points[i] != null && points[i + 1] != null) {
        canvas.drawLine(points[i]!, points[i + 1]!, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter old) => true;
}

class _WholeNumberFormatter extends TextInputFormatter {
  final VoidCallback onInvalid;
  _WholeNumberFormatter({required this.onInvalid});

  static final _validWholeNumber = RegExp(r'^(0|[1-9]\d*)?$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (_validWholeNumber.hasMatch(newValue.text)) {
      return newValue;
    }
    onInvalid();
    return oldValue;
  }
}

DeviceLocationFix _fixFromPosition(Position position) => DeviceLocationFix(
  latitude: position.latitude,
  longitude: position.longitude,
  accuracyMeters: position.accuracy,
  capturedAt: position.timestamp,
  isMocked: position.isMocked,
);

class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
