import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:provider/provider.dart';

import '../copilot/mobile_copilot_commands.dart';
import '../copilot/mobile_copilot_page.dart';
import '../providers/auth_provider.dart';
import '../models/user_model.dart';
import '../services/cart_draft_cache.dart';
import '../utils/order_pdf.dart';
import '../utils/order_status.dart';
import '../utils/order_submission_contract.dart';
import '../utils/order_submission_id.dart';
import '../utils/quantity_unit.dart';
import '../voice/core/action_registry.dart';
import '../voice/core/voice_binding.dart';
import '../voice/core/voice_dispatcher.dart';
import '../voice/core/voice_engine.dart';
import '../voice/core/voice_types.dart';
import '../widgets/rejected_order_banner.dart';
import '../voice/voice_registry_factory.dart';
import 'overview_screen.dart';
import 'order_cart_screen.dart';
import '../utils/order_reference.dart';
import '../widgets/long_name_text.dart';
import '../widgets/phone_card.dart';
import '../widgets/phone_status_strip.dart';

class QuickDateOption {
  final String label;
  final String? displayLabel;
  final DateTimeRange Function() getDateRange;

  QuickDateOption({
    required this.label,
    this.displayLabel,
    required this.getDateRange,
  });

  String getDisplayText() {
    final range = getDateRange();
    if (range.start == range.end) {
      return _formatDate(range.start);
    }
    return '${_formatDate(range.start)} - ${_formatDate(range.end)}';
  }
}

class OrderHistoryItem {
  final String name;
  final String productId;
  final String barcode;
  final String packingSize;
  final String department;
  final int qty;
  final double unitPrice;
  final String expiry;
  final List<Map<String, dynamic>> shelfBatches;
  final String remarks;

  final String? uom;

  final int maxOrderQty;

  OrderHistoryItem({
    required this.name,
    required this.productId,
    required this.barcode,
    required this.packingSize,
    required this.department,
    required this.qty,
    required this.unitPrice,
    required this.expiry,
    required this.shelfBatches,
    required this.remarks,
    this.uom,
    this.maxOrderQty = defaultMaxQtyPerLine,
  });

  double get subtotal => unitPrice * qty;

  factory OrderHistoryItem.fromMap(Map<String, dynamic> data) {
    return OrderHistoryItem(
      name: _asString(
        data['name'] ?? data['productName'],
        fallback: 'Unknown Item',
      ),
      productId: _asString(data['productId']),
      barcode: _asString(data['barcode'] ?? data['itemBarcode']),
      packingSize: _asString(data['packingSize']),
      department: _asString(data['department'], fallback: 'Others'),
      qty: _asInt(data['qty'] ?? data['orderQty'] ?? data['quantity']),
      unitPrice: _asDouble(data['price'] ?? data['unitPrice']),
      expiry: _asString(data['expiry'] ?? data['orderedExpiry']),
      shelfBatches: _asMapList(data['shelfBatches']),
      remarks: _asString(data['remarks']),
      uom: uomOf(data),
      maxOrderQty: maxQtyFor(data),
    );
  }
}

class OrderHistoryRecord {
  final String id;
  final String retailerId;
  final String retailerName;
  final String salesmanId;
  final DateTime submittedAt;

  final bool hasKnownDate;
  final String status;

  final String rejectionRemark;
  final String rejectedByName;
  final DateTime? rejectedAt;
  final int totalProducts;
  final int totalBoxes;
  final double totalPrice;
  final List<OrderHistoryItem> items;
  final String locationMode;

  static String locationLabelFor(String mode) => switch (mode) {
    'location_verified' => 'GPS verified at the shop',
    'device_captured' => 'Location recorded',
    _ => 'No location recorded',
  };

  static bool hasLocationFor(String mode) =>
      mode == 'location_verified' || mode == 'device_captured';

  String get totalQuantityText => items.isEmpty
      ? quantityLabel(totalBoxes, null)
      : totalQuantityLabel(
          items.map((OrderHistoryItem item) => (item.qty, item.uom)),
        );

  OrderHistoryRecord({
    required this.id,
    required this.retailerId,
    required this.retailerName,
    required this.salesmanId,
    required this.submittedAt,
    this.hasKnownDate = true,
    required this.status,
    this.rejectionRemark = '',
    this.rejectedByName = '',
    this.rejectedAt,
    required this.totalProducts,
    required this.totalBoxes,
    required this.totalPrice,
    required this.items,
    this.locationMode = '',
  });

  static DateTime? _readTimestamp(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    final String text = value?.toString().trim() ?? '';
    if (text.isEmpty || text == 'null') return null;
    return DateTime.tryParse(text);
  }

  factory OrderHistoryRecord.fromSnapshot(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final rawItems = data['items'] as List<dynamic>? ?? const [];
    final legacyItems = rawItems
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .toList();
    final List<CommercialOrderLine>? canonical =
        OrderSubmissionContract.readCommercialLines(data);
    final itemMaps = canonical == null
        ? legacyItems
        : List<Map<String, dynamic>>.generate(canonical.length, (int index) {
            final CommercialOrderLine line = canonical[index];
            return <String, dynamic>{
              if (index < legacyItems.length) ...legacyItems[index],
              'name': line.productName,
              'productName': line.productName,
              'productId': line.productId,
              'qty': line.quantity,
              'price': line.unitPrice,
            };
          });
    final items = itemMaps.map(OrderHistoryItem.fromMap).toList();

    final DateTime? resolvedSubmittedAt =
        _readTimestamp(data['submittedAt']) ??
        _readTimestamp(data['createdAt']) ??
        _readTimestamp(data['created_at']) ??
        legacyOrderIdTimestamp(_asString(data['orderId'], fallback: doc.id)) ??
        legacyOrderIdTimestamp(doc.id);
    final bool hasKnownDate = resolvedSubmittedAt != null;
    final DateTime submittedAt =
        resolvedSubmittedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

    final firstItem = rawItems.whereType<Map>().isNotEmpty
        ? Map<String, dynamic>.from(rawItems.whereType<Map>().first)
        : <String, dynamic>{};

    final int canonicalBoxes =
        canonical?.fold<int>(
          0,
          (int total, CommercialOrderLine line) => total + line.quantity,
        ) ??
        0;
    final double canonicalPrice =
        (canonical?.fold<int>(
              0,
              (int total, CommercialOrderLine line) =>
                  total + line.lineTotalCents,
            ) ??
            0) /
        100;
    final totalPrice = canonical == null
        ? _asDouble(data['totalPrice'])
        : canonicalPrice;

    return OrderHistoryRecord(
      id: _asString(data['orderId'], fallback: doc.id),
      retailerId: _asString(data['retailerId'] ?? firstItem['retailerId']),
      retailerName: _asString(
        data['retailerName'] ?? data['outlet'] ?? firstItem['retailerName'],
        fallback: 'Unknown Outlet',
      ),
      salesmanId: _asString(data['salesmanId'], fallback: 'Unknown'),
      submittedAt: submittedAt,
      hasKnownDate: hasKnownDate,
      status: resolveMobileOrderStatus(data),
      rejectionRemark: _asString(data['rejectionRemark']),
      rejectedByName: _asString(data['rejectedByName']),
      rejectedAt: _readTimestamp(data['rejectedAt']),
      totalProducts:
          canonical?.length ??
          _asInt(data['totalProducts'], fallback: items.length),
      totalBoxes: canonical == null
          ? _asInt(
              data['totalBoxes'],
              fallback: items.fold<int>(0, (total, item) => total + item.qty),
            )
          : canonicalBoxes,
      totalPrice: totalPrice > 0
          ? totalPrice
          : items.fold<double>(0, (total, item) => total + item.subtotal),
      items: items,
      locationMode: _asString(
        data['locationVerification'] ??
            (data['locationEvidence'] is Map
                ? (data['locationEvidence'] as Map)['mode']
                : null),
      ),
    );
  }
}

enum ReorderDraftCase { sentWaiting, unsentWithItems, free }

ReorderDraftCase saveReorderDraft({
  required String salesmanUid,
  required String retailerId,
  required List<Map<String, dynamic>> items,
  bool replaceUnsent = false,
}) {
  final String key = CartDraftCache.keyFor(
    salesmanUid: salesmanUid,
    retailerId: retailerId,
  );
  final CartDraftSnapshot? existing = CartDraftCache.read(key);
  if (existing != null && existing.pendingOrderId.trim().isNotEmpty) {
    return ReorderDraftCase.sentWaiting;
  }
  if (existing != null && existing.items.isNotEmpty && !replaceUnsent) {
    return ReorderDraftCase.unsentWithItems;
  }
  CartDraftCache.save(
    key,
    CartDraftSnapshot(
      salesmanUid: salesmanUid,
      retailerId: retailerId,
      progress: 2,
      items: items,
    ),
  );
  return ReorderDraftCase.free;
}

class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  String selectedStatus = 'All';
  String selectedMonth = 'All';
  DateTimeRange? selectedDateRange;
  String? selectedQuickDate;
  bool showOlderOrders = false;
  int _retentionMonths = 3;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _retentionSubscription;

  static const int _pageSize = 50;
  int _pageLimit = _pageSize;
  bool _hasMoreOrders = false;
  Stream<List<OrderHistoryRecord>>? _ordersStream;
  String _ordersStreamKey = '';
  String _ordersWindowKey = '';
  List<OrderHistoryRecord>? _lastOrders;
  late final VoiceScreenBinding _voiceBinding;
  late final VoiceCommandEngine _voiceEngine;

  @override
  void initState() {
    super.initState();
    _retentionSubscription = FirebaseFirestore.instance
        .collection('system_settings')
        .doc('order_purge')
        .snapshots()
        .listen((snapshot) {
          final value = snapshot.data()?['retentionMonths'];
          final months = value is int && const [3, 6, 12, 84].contains(value)
              ? value
              : 84;
          if (mounted && months != _retentionMonths) {
            setState(() => _retentionMonths = months);
          }
        }, onError: (Object error) {});
    _voiceBinding = VoiceScreenBinding(surfaceId: VoiceSurfaceIds.orderHistory);
    _voiceBinding.registerHandler(
      VoiceActionId.openOrderHistory,
      _handleVoiceOpenOrderHistory,
    );
    _voiceEngine = VoiceCommandEngine(
      sessionId: 'order-history-${DateTime.now().microsecondsSinceEpoch}',
      binding: _voiceBinding,
      dispatcher: VoiceActionDispatcher(
        registry: buildVoiceActionRegistry(),
        binding: _voiceBinding,
      ),
    );
  }

  @override
  void dispose() {
    _retentionSubscription?.cancel();
    RejectedOrderBanner.markSeen();
    _voiceBinding.dispose();
    super.dispose();
  }

  Future<VoiceActionResult> _handleVoiceOpenOrderHistory(
    VoiceCommandEnvelope envelope,
  ) async => const VoiceActionResult.opened();

  List<String> get statuses => const [
    'All',
    'Submitted',
    'Held for review',
    'Approved',
    'Rejected',
    'Completed',
    'Queued',
    'In Progress',
    'Cancelled',
  ];

  List<String> get months => const [
    'All',
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  List<QuickDateOption> get quickDateOptions {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    final startOfMonth = DateTime(now.year, now.month, 1);
    final last7Days = today.subtract(const Duration(days: 7));
    final last30Days = today.subtract(const Duration(days: 30));

    return [
      QuickDateOption(
        label: 'Today',
        getDateRange: () => DateTimeRange(start: today, end: today),
      ),
      QuickDateOption(
        label: 'Yesterday',
        getDateRange: () => DateTimeRange(start: yesterday, end: yesterday),
      ),
      QuickDateOption(
        label: 'This Week',
        getDateRange: () => DateTimeRange(start: startOfWeek, end: today),
      ),
      QuickDateOption(
        label: 'This Month',
        getDateRange: () => DateTimeRange(start: startOfMonth, end: today),
      ),
      QuickDateOption(
        label: 'Last 7 Days',
        getDateRange: () => DateTimeRange(start: last7Days, end: today),
      ),
      QuickDateOption(
        label: 'Last 30 Days',
        getDateRange: () => DateTimeRange(start: last30Days, end: today),
      ),
    ];
  }

  void _goBack() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const OverviewScreen()),
    );
  }

  DateTime _retentionCutoff() {
    final DateTime now = DateTime.now().toUtc().add(const Duration(hours: 8));
    final DateTime targetMonth = DateTime.utc(
      now.year,
      now.month - _retentionMonths,
    );
    final int lastDay = DateTime.utc(
      targetMonth.year,
      targetMonth.month + 1,
      0,
    ).day;
    return DateTime.utc(
      targetMonth.year,
      targetMonth.month,
      now.day > lastDay ? lastDay : now.day,
      now.hour,
      now.minute,
      now.second,
      now.millisecond,
      now.microsecond,
    ).subtract(const Duration(hours: 8));
  }

  ({DateTime? start, DateTime? end}) _historyWindow() {
    DateTimeRange? range;
    if (selectedQuickDate != null) {
      range = quickDateOptions
          .firstWhere((opt) => opt.label == selectedQuickDate)
          .getDateRange();
    } else if (selectedDateRange != null) {
      range = selectedDateRange;
    }
    if (range != null) {
      return (start: range.start, end: range.end.add(const Duration(days: 1)));
    }
    if (selectedMonth != 'All') {
      final int monthNumber = months.indexOf(selectedMonth);
      final DateTime now = DateTime.now();
      final int year = monthNumber > now.month ? now.year - 1 : now.year;
      return (
        start: DateTime(year, monthNumber),
        end: DateTime(year, monthNumber + 1),
      );
    }
    if (!showOlderOrders) {
      final DateTime cutoff = _retentionCutoff();
      return (
        start: DateTime.utc(cutoff.year, cutoff.month, cutoff.day),
        end: null,
      );
    }
    return (start: null, end: null);
  }

  Stream<List<OrderHistoryRecord>> _ordersStreamCached(UserModel? user) {
    final String uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final String code = user?.identityCode ?? '';
    final window = _historyWindow();
    final String windowKey = '$uid|$code|${window.start}|${window.end}';
    if (windowKey != _ordersWindowKey) {
      _ordersWindowKey = windowKey;
      _pageLimit = _pageSize;
      _lastOrders = null;
    }
    final String key = '$windowKey|$_pageLimit';
    if (key != _ordersStreamKey || _ordersStream == null) {
      _ordersStreamKey = key;
      _ordersStream = _ordersStreamFor(user, window.start, window.end);
    }
    return _ordersStream!;
  }

  Stream<List<OrderHistoryRecord>> _ordersStreamFor(
    UserModel? user,
    DateTime? windowStart,
    DateTime? windowEnd,
  ) {
    final String uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final String salesmanCode = user?.identityCode ?? '';
    if (uid.isEmpty) return Stream<List<OrderHistoryRecord>>.value(const []);
    final int limit = _pageLimit;
    Query<Map<String, dynamic>> page(Query<Map<String, dynamic>> query) {
      if (windowStart != null) {
        query = query.where(
          'submittedAt',
          isGreaterThanOrEqualTo: Timestamp.fromDate(windowStart),
        );
      }
      if (windowEnd != null) {
        query = query.where(
          'submittedAt',
          isLessThan: Timestamp.fromDate(windowEnd),
        );
      }
      return query.orderBy('submittedAt', descending: true).limit(limit);
    }

    final List<Query<Map<String, dynamic>>> queries =
        <Query<Map<String, dynamic>>>[
          page(
            FirebaseFirestore.instance
                .collection('orders')
                .where('salesmanUid', isEqualTo: uid),
          ),
          if (salesmanCode.isNotEmpty) ...<Query<Map<String, dynamic>>>[
            page(
              FirebaseFirestore.instance
                  .collection('orders')
                  .where('salesmanCode', isEqualTo: salesmanCode),
            ),
            page(
              FirebaseFirestore.instance
                  .collection('orders')
                  .where('salesman_code', isEqualTo: salesmanCode),
            ),
          ],
        ];
    return Stream<List<OrderHistoryRecord>>.multi((listener) {
      final Map<int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      rowsByQuery = <int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
      final Set<int> failedQueries = <int>{};

      void emit() {
        final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> unique =
            <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
        for (final List<QueryDocumentSnapshot<Map<String, dynamic>>> rows
            in rowsByQuery.values) {
          for (final QueryDocumentSnapshot<Map<String, dynamic>> row in rows) {
            final Object? owner = row.data()['salesmanUid'];
            if (owner is String && owner.isNotEmpty && owner != uid) continue;
            unique[row.id] = row;
          }
        }
        var orders = unique.values
            .map(OrderHistoryRecord.fromSnapshot)
            .toList();
        orders.sort(
          (OrderHistoryRecord a, OrderHistoryRecord b) =>
              b.submittedAt.compareTo(a.submittedAt),
        );
        _hasMoreOrders = rowsByQuery.values.any(
          (List<QueryDocumentSnapshot<Map<String, dynamic>>> rows) =>
              rows.length >= limit,
        );
        if (orders.length > limit) orders = orders.sublist(0, limit);
        _lastOrders = orders;
        listener.add(orders);
      }

      final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      subscriptions = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[
        for (int index = 0; index < queries.length; index++)
          queries[index].snapshots().listen(
            (snapshot) {
              failedQueries.remove(index);
              rowsByQuery[index] = snapshot.docs;
              emit();
            },
            onError: (Object error, StackTrace stack) {
              rowsByQuery[index] =
                  const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
              failedQueries.add(index);
              if (failedQueries.length == queries.length) {
                listener.addError(error, stack);
              } else {
                emit();
              }
            },
          ),
      ];
      listener.onCancel = () async {
        for (final StreamSubscription<QuerySnapshot<Map<String, dynamic>>>
            subscription
            in subscriptions) {
          await subscription.cancel();
        }
      };
    });
  }

  List<OrderHistoryRecord> _applyFilters(List<OrderHistoryRecord> loaded) {
    var orders = loaded;
    if (selectedMonth != 'All') {
      final monthNumber = months.indexOf(selectedMonth);
      final DateTime nowForMonth = DateTime.now();
      final int year = monthNumber > nowForMonth.month
          ? nowForMonth.year - 1
          : nowForMonth.year;
      orders = orders
          .where(
            (order) =>
                order.submittedAt.month == monthNumber &&
                order.submittedAt.year == year,
          )
          .toList();
    }

    DateTimeRange? effectiveDateRange;

    if (selectedQuickDate != null) {
      final quickOption = quickDateOptions.firstWhere(
        (opt) => opt.label == selectedQuickDate,
      );
      effectiveDateRange = quickOption.getDateRange();
    } else if (selectedDateRange != null) {
      effectiveDateRange = selectedDateRange;
    }

    if (effectiveDateRange != null) {
      orders = orders
          .where(
            (order) =>
                order.submittedAt.isAfter(effectiveDateRange!.start) &&
                order.submittedAt.isBefore(
                  effectiveDateRange.end.add(const Duration(days: 1)),
                ),
          )
          .toList();
    }

    if (selectedStatus != 'All') {
      orders = orders.where((order) => order.status == selectedStatus).toList();
    }
    return orders;
  }

  Future<void> _selectDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: selectedDateRange,
    );
    if (picked != null) {
      setState(() {
        selectedDateRange = picked;
        selectedQuickDate = null;
      });
    }
  }

  void _selectQuickDate(String label) {
    setState(() {
      if (selectedQuickDate == label) {
        selectedQuickDate = null;
        selectedDateRange = null;
      } else {
        selectedQuickDate = label;
        selectedDateRange = null;
      }
    });
  }

  void _resetFilters() {
    setState(() {
      selectedStatus = 'All';
      selectedMonth = 'All';
      selectedDateRange = null;
      selectedQuickDate = null;
      showOlderOrders = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    _voiceBinding.updateContext(
      uid: auth.user?.uid ?? '',
      role: auth.user?.role ?? '',
    );
    final Stream<List<OrderHistoryRecord>> ordersStream = _ordersStreamCached(
      auth.user,
    );
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: 'Order History',
        onBack: _goBack,
        actions: <Widget>[
          CopilotEntryButton(
            screen: CopilotScreenContext(engine: _voiceEngine),
          ),
        ],
      ),
      statusStrip: const PhoneStatusStrip(),
      body: Column(
        children: [
          _buildFiltersSection(),
          RejectedOrderBanner(
            onTap: () => setState(() => selectedStatus = 'Rejected'),
          ),
          Expanded(
            child: StreamBuilder<List<OrderHistoryRecord>>(
              stream: ordersStream,
              builder: (context, snapshot) {
                final bool loading =
                    snapshot.connectionState == ConnectionState.waiting &&
                    _lastOrders == null;
                final allOrders = _applyFilters(
                  snapshot.data ?? _lastOrders ?? const <OrderHistoryRecord>[],
                );
                final bool limitToRecent =
                    !showOlderOrders &&
                    selectedMonth == 'All' &&
                    selectedDateRange == null &&
                    selectedQuickDate == null;
                final DateTime cutoff = _retentionCutoff();
                final orders = limitToRecent
                    ? allOrders
                          .where(
                            (o) =>
                                !o.hasKnownDate ||
                                !o.submittedAt.isBefore(cutoff),
                          )
                          .toList()
                    : allOrders;
                final bool hasFooter = _hasMoreOrders || limitToRecent;
                return PhoneStateBody(
                  error:
                      snapshot.hasError &&
                      snapshot.connectionState != ConnectionState.waiting,
                  errorTitle: 'Order history did not load',
                  loading: loading,
                  onRetry: _retryLoad,
                  empty: orders.isEmpty && !hasFooter,
                  emptyIcon: ScootIcons.orders,
                  emptyTitle: _hasActiveFilters
                      ? 'No orders match'
                      : 'No orders yet',
                  emptyMessage: _getEmptyMessage(),
                  emptyAction: _hasActiveFilters
                      ? OutlinedButton(
                          onPressed: _resetFilters,
                          child: const Text('Clear all filters'),
                        )
                      : null,
                  child: OrderHistoryList(
                    orders: orders,
                    footerLabel: !hasFooter
                        ? null
                        : _hasMoreOrders
                        ? 'Load older orders'
                        : 'Show older orders',
                    emptyTitle: orderHistoryEmptyTitle(
                      hasActiveFilters: _hasActiveFilters,
                      limitedToRecent: limitToRecent,
                      retentionMonths: _retentionMonths,
                    ),
                    emptyMessage: _getEmptyMessage(),
                    onFooter: () => setState(() {
                      if (_hasMoreOrders) {
                        _pageLimit += _pageSize;
                      } else {
                        showOlderOrders = true;
                      }
                    }),
                    onOpen: (OrderHistoryRecord order) =>
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => _buildDetailsView(order),
                          ),
                        ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNav: const AppBottomNav(currentIndex: 2),
    );
  }

  void _retryLoad() => setState(() => _ordersStream = null);

  bool get _hasActiveFilters =>
      selectedStatus != 'All' ||
      selectedMonth != 'All' ||
      selectedDateRange != null ||
      selectedQuickDate != null;

  String get _dateChipLabel {
    if (selectedQuickDate != null) return selectedQuickDate!;
    if (selectedDateRange != null) {
      return '${_formatDate(selectedDateRange!.start)} - ${_formatDate(selectedDateRange!.end)}';
    }
    return 'Any date';
  }

  Future<void> _openDateSheet() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final QuickDateOption option in quickDateOptions)
                ListTile(
                  title: Text(option.label),
                  subtitle: Text(option.getDisplayText()),
                  selected: selectedQuickDate == option.label,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _selectQuickDate(option.label);
                  },
                ),
              ListTile(
                leading: const Icon(ScootIcons.calendar),
                title: const Text('Custom range'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _selectDateRange();
                },
              ),
              if (selectedQuickDate != null || selectedDateRange != null)
                ListTile(
                  title: const Text('Any date'),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    setState(() {
                      selectedQuickDate = null;
                      selectedDateRange = null;
                    });
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFiltersSection() {
    final ScootColors c = ScootColors.of(context);
    return Container(
      color: c.card,
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: ScootSpace.phoneGutter,
          vertical: 6,
        ),
        children: <Widget>[
          Center(
            child: ChoiceChip(
              key: const Key('order_history_date_chip'),
              avatar: const Icon(ScootIcons.calendar, size: 16),
              label: Text(_dateChipLabel),
              selected: selectedQuickDate != null || selectedDateRange != null,
              onSelected: (_) => _openDateSheet(),
            ),
          ),
          for (final String status in statuses)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Center(
                child: ChoiceChip(
                  label: Text(status),
                  selected: selectedStatus == status,
                  onSelected: (_) => setState(() => selectedStatus = status),
                ),
              ),
            ),
          if (_hasActiveFilters)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Center(
                child: TextButton(
                  onPressed: _resetFilters,
                  child: const Text('Clear filters'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getEmptyMessage() {
    if (selectedQuickDate != null) {
      final option = quickDateOptions.firstWhere(
        (opt) => opt.label == selectedQuickDate,
      );
      return 'No orders found for ${option.label.toLowerCase()}.';
    }
    if (selectedDateRange != null) {
      return 'No orders found in the selected date range.';
    }
    if (selectedMonth != 'All') {
      return 'No orders found in $selectedMonth.';
    }
    if (selectedStatus != 'All') {
      return 'No orders with "$selectedStatus" status found.';
    }
    return 'Orders you send will show here.';
  }

  Future<void> _reuseOrder(OrderHistoryRecord order) async {
    if (order.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This order has no items to reuse.')),
      );
      return;
    }

    if (order.retailerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This order is missing retailer information.'),
        ),
      );
      return;
    }

    final salesmanUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final draftItems = order.items.map((item) {
      final shelfBatches = item.shelfBatches.map((batch) {
        final qty = _asInt(batch['qty']);
        return {
          'qty': qty,
          'expiry': _asString(batch['expiry']),
          'controller': TextEditingController(text: qty.toString()),
          'focusNode': FocusNode(),
        };
      }).toList();

      return <String, dynamic>{
        'retailerName': order.retailerName,
        'retailerId': order.retailerId,
        'name': item.name,
        'productId': item.productId,
        'packingSize': item.packingSize,
        'barcode': item.barcode,
        'price': item.unitPrice,
        'department': item.department,
        if (item.uom != null) 'uom': item.uom,
        'maxOrderQty': item.maxOrderQty,
        'qty': item.qty,
        'stock': shelfBatches.fold<int>(
          0,
          (total, batch) => total + _asInt(batch['qty']),
        ),
        'expiry': item.expiry,
        'remarks': item.remarks,
        'shelfBatches': shelfBatches.isEmpty
            ? [
                {
                  'qty': 0,
                  'expiry': '',
                  'controller': TextEditingController(text: '0'),
                  'focusNode': FocusNode(),
                },
              ]
            : shelfBatches,
        'stockController': TextEditingController(text: '0'),
      };
    }).toList();

    ReorderDraftCase outcome = saveReorderDraft(
      salesmanUid: salesmanUid,
      retailerId: order.retailerId,
      items: draftItems,
    );
    if (outcome == ReorderDraftCase.unsentWithItems) {
      final bool? replace = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('Replace the unsent order?'),
          content: const Text(
            'This shop already has an unsent order. '
            'Order again replaces it.',
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep it'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
      outcome = saveReorderDraft(
        salesmanUid: salesmanUid,
        retailerId: order.retailerId,
        items: draftItems,
        replaceUnsent: true,
      );
    }
    if (outcome == ReorderDraftCase.sentWaiting) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'An order for this shop is still waiting to send. '
            "Open this shop's order to check it first.",
          ),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OrderCartScreen(
          selectedItems: draftItems,
          retailerId: order.retailerId,
          retailerName: order.retailerName,
        ),
      ),
    );
  }

  Widget _buildDetailsView(OrderHistoryRecord order) {
    return OrderDetailsView(
      order: order,
      onBack: () => Navigator.of(context).pop(),
      onReuse: () => _reuseOrder(order),
      onExport: () => _exportPdf(order),
    );
  }

  Future<void> _exportPdf(OrderHistoryRecord order) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await OrderPdf.share(
        orderId: order.id,
        totalProducts: order.totalProducts,
        totalBoxes: order.totalBoxes,
        submittedAt: order.submittedAt,
        cartItems: [
          for (final OrderHistoryItem i in order.items)
            <String, dynamic>{
              'name': i.name,
              'packingSize': i.packingSize,
              'department': i.department,
              if (i.uom != null) 'uom': i.uom,
              'orderQty': i.qty,
              'expiry': i.expiry,
              'shelfBatches': i.shelfBatches,
              'remarks': i.remarks,
            },
        ],
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not create the PDF.')),
      );
    }
  }
}

String orderDayLabel(DateTime date) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[date.weekday - 1]} ${date.day} ${months[date.month - 1]}';
}

String _timeLabel(DateTime dt) {
  final h = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
  final ap = dt.hour >= 12 ? 'PM' : 'AM';
  return '$h:${dt.minute.toString().padLeft(2, '0')} $ap';
}

IconData _statusIcon(String status) {
  switch (status) {
    case 'Approved':
    case 'Completed':
      return ScootIcons.check;
    case 'Rejected':
    case 'Cancelled':
      return ScootIcons.close;
    case 'Submitted':
      return ScootIcons.clock;
    default:
      return ScootIcons.hourglass;
  }
}

class OrderStatusBadge extends StatelessWidget {
  const OrderStatusBadge(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    return ScootBadge(
      label: status,
      tone: _statusTone(status),
      icon: _statusIcon(status),
    );
  }
}

String orderHistoryEmptyTitle({
  required bool hasActiveFilters,
  required bool limitedToRecent,
  required int retentionMonths,
}) {
  if (hasActiveFilters) return 'No orders match';
  if (!limitedToRecent) return 'No orders yet';
  return 'No orders in the last ${orderHistoryPeriodLabel(retentionMonths)}';
}

String orderHistoryPeriodLabel(int months) {
  if (months >= 24 && months % 12 == 0) return '${months ~/ 12} years';
  return '$months ${months == 1 ? 'month' : 'months'}';
}

class OrderHistoryList extends StatelessWidget {
  const OrderHistoryList({
    super.key,
    required this.orders,
    required this.onOpen,
    this.footerLabel,
    this.onFooter,
    this.emptyTitle,
    this.emptyMessage,
  });

  final List<OrderHistoryRecord> orders;
  final ValueChanged<OrderHistoryRecord> onOpen;
  final String? footerLabel;
  final VoidCallback? onFooter;
  final String? emptyTitle;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    final List<Object> entries = <Object>[];
    String? lastDay;
    final Map<String, int> perDay = <String, int>{};
    String dayOf(OrderHistoryRecord order) =>
        order.hasKnownDate ? orderDayLabel(order.submittedAt) : 'Date unknown';
    for (final OrderHistoryRecord order in orders) {
      perDay[dayOf(order)] = (perDay[dayOf(order)] ?? 0) + 1;
    }
    for (final OrderHistoryRecord order in orders) {
      final String day = dayOf(order);
      if (day != lastDay) {
        entries.add((day, perDay[day] ?? 0));
        lastDay = day;
      }
      entries.add(order);
    }
    if (orders.isEmpty && footerLabel != null && emptyTitle != null) {
      return Center(
        child: SingleChildScrollView(
          child: ScootEmptyState(
            icon: ScootIcons.orders,
            title: emptyTitle!,
            message: emptyMessage,
            action: OutlinedButton(
              onPressed: onFooter,
              child: Text(footerLabel!),
            ),
          ),
        ),
      );
    }
    if (footerLabel != null) entries.add(footerLabel!);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        ScootSpace.phoneGutter,
        4,
        ScootSpace.phoneGutter,
        16,
      ),
      itemCount: entries.length,
      itemBuilder: (BuildContext context, int index) {
        final Object entry = entries[index];
        if (entry is OrderHistoryRecord) {
          return _OrderRow(order: entry, onTap: () => onOpen(entry));
        }
        if (entry is String) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(onPressed: onFooter, child: Text(entry)),
          );
        }
        final (String, int) group = entry as (String, int);
        return PhoneSectionTitle(
          group.$1,
          trailing: Text(
            '${group.$2} ${group.$2 == 1 ? 'order' : 'orders'}',
            style: ScootType.small.copyWith(
              color: ScootColors.of(context).muted,
            ),
          ),
        );
      },
    );
  }
}

class _OrderRow extends StatelessWidget {
  final OrderHistoryRecord order;
  final VoidCallback onTap;

  const _OrderRow({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final bool specialOnly = order.items.isEmpty && order.totalProducts == 0;
    final String summary = specialOnly
        ? 'special request only'
        : '${order.totalProducts} product${order.totalProducts == 1 ? '' : 's'}'
              ' · RM ${order.totalPrice.toStringAsFixed(2)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ScootPressable(
        onTap: onTap,
        minSize: const Size.fromHeight(ScootSize.phoneTarget),
        borderRadius: ScootRadius.cardAll,
        color: c.card,
        semanticLabel:
            '${order.retailerName}, ${order.status}, ${order.id}, $summary',
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: c.line),
            borderRadius: ScootRadius.cardAll,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: LongNameText(
                      order.retailerName,
                      style: ScootType.bodyStrong.copyWith(color: c.ink),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OrderStatusBadge(order.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${shortOrderReference(order.id)}'
                '${order.hasKnownDate ? ' · ${_timeLabel(order.submittedAt)}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ScootType.mono.copyWith(color: c.muted),
              ),
              const SizedBox(height: 2),
              Text(summary, style: ScootType.small.copyWith(color: c.text2)),
              if (order.status == 'Rejected' &&
                  order.rejectionRemark.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Reason: ${order.rejectionRemark}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.smallStrong.copyWith(
                      color: c.danger.noteText,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderLocationRow extends StatefulWidget {
  const _OrderLocationRow({required this.order});

  final OrderHistoryRecord order;

  @override
  State<_OrderLocationRow> createState() => _OrderLocationRowState();
}

class _OrderLocationRowState extends State<_OrderLocationRow> {
  late String _mode = widget.order.locationMode;
  late bool _loading = _mode.isEmpty;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (_mode.isEmpty) _loadTrackedMode();
  }

  Future<void> _loadTrackedMode() async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> tracked =
          await FirebaseFirestore.instance
              .collection('gps_tracking')
              .doc('order_${widget.order.id}')
              .get();
      final Object? mode = tracked.data()?['locationVerification'];
      if (!mounted) return;
      setState(() {
        if (mode is String) _mode = mode;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = error is! FirebaseException ||
              error.code == 'unavailable';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _failed) {
      return PhoneRow(
        label: 'Location',
        value: _loading
            ? 'Checking location…'
            : 'Location not available offline',
      );
    }
    return PhoneRow(
      label: 'Location',
      value: OrderHistoryRecord.locationLabelFor(_mode),
      tone: OrderHistoryRecord.hasLocationFor(_mode) ? null : ScootTone.warning,
    );
  }
}

class OrderDetailsView extends StatelessWidget {
  const OrderDetailsView({
    super.key,
    required this.order,
    required this.onBack,
    required this.onReuse,
    required this.onExport,
  });

  final OrderHistoryRecord order;
  final VoidCallback onBack;
  final VoidCallback onReuse;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final bool specialOnly = order.items.isEmpty && order.totalProducts == 0;
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: 'Order Details',
        subtitle: '${shortOrderReference(order.id)} · ${order.retailerName}',
        onBack: onBack,
        actions: <Widget>[
          KeyedSubtree(
            key: const Key('order_history_export_pdf'),
            child: ScootPhoneAction(
              icon: ScootIcons.download,
              label: 'Export PDF',
              onPressed: onExport,
            ),
          ),
        ],
      ),
      statusStrip: const PhoneStatusStrip(),
      body: ListView(
        padding: const EdgeInsets.all(ScootSpace.phoneGutter),
        children: [
          if (order.status == 'Rejected') ...[
            _RejectionCard(order: order),
            const SizedBox(height: 12),
          ],
          PhoneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    OrderStatusBadge(order.status),
                    const Spacer(),
                    if (!specialOnly)
                      Text(
                        'RM ${order.totalPrice.toStringAsFixed(2)}',
                        style: ScootType.h2.copyWith(color: c.ink),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                LongNameText(
                  order.retailerName,
                  style: ScootType.bodyStrong.copyWith(color: c.text2),
                ),
                const SizedBox(height: 8),
                const PhoneDivider(),
                PhoneRow(
                  label: 'Reference',
                  valueWidget: _CopyReference(orderId: order.id),
                ),
                const PhoneDivider(),
                PhoneRow(
                  label: 'Sent',
                  value: order.hasKnownDate
                      ? _formatDateTime(order.submittedAt)
                      : 'Not recorded',
                ),
                const PhoneDivider(),
                PhoneRow(
                  label: 'Items',
                  value: specialOnly
                      ? 'special request only'
                      : '${order.totalProducts} product${order.totalProducts == 1 ? '' : 's'}'
                            ' · ${order.totalQuantityText}',
                ),
                const PhoneDivider(),
                _OrderLocationRow(order: order),
              ],
            ),
          ),
          PhoneSectionTitle('Products (${order.items.length})'),
          PhoneCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: order.items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      specialOnly
                          ? 'No products. This order is a special request only.'
                          : 'No items',
                      style: ScootType.small.copyWith(color: c.text2),
                    ),
                  )
                : Column(children: _productRows(context)),
          ),
        ],
      ),
      primaryAction: ScootPrimaryActionBar(
        label: 'Reuse order',
        icon: ScootIcons.refresh,
        onPressed: onReuse,
      ),
      bottomNav: const AppBottomNav(currentIndex: 2),
    );
  }

  List<Widget> _productRows(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Map<String, List<OrderHistoryItem>> grouped =
        <String, List<OrderHistoryItem>>{};
    for (final OrderHistoryItem item in order.items) {
      grouped.putIfAbsent(item.department, () => []).add(item);
    }
    final List<Widget> rows = <Widget>[];
    grouped.forEach((String dept, List<OrderHistoryItem> items) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              dept.toUpperCase(),
              style: ScootType.caption.copyWith(
                color: c.muted,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ),
      );
      for (int i = 0; i < items.length; i++) {
        if (i > 0) rows.add(const PhoneDivider());
        rows.add(_ProductRow(item: items[i]));
      }
    });
    return rows;
  }
}

class _CopyReference extends StatelessWidget {
  const _CopyReference({required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Text(
            shortOrderReference(orderId),
            overflow: TextOverflow.ellipsis,
            style: ScootType.mono.copyWith(color: c.ink),
          ),
        ),
        IconButton(
          tooltip: 'Copy reference',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.content_copy, size: 18, color: c.text2),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: orderId));
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Reference copied.')));
          },
        ),
      ],
    );
  }
}

class _RejectionCard extends StatelessWidget {
  final OrderHistoryRecord order;
  const _RejectionCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final String reason = order.rejectionRemark.isEmpty
        ? 'No reason was given.'
        : order.rejectionRemark;
    final String by = order.rejectedByName.isEmpty
        ? ''
        : '\nRejected by ${order.rejectedByName}'
              '${order.rejectedAt == null ? '' : ' on ${_formatDate(order.rejectedAt!)}'}';
    return KeyedSubtree(
      key: const Key('order_rejection_card'),
      child: ScootNotice(
        tone: ScootTone.danger,
        icon: ScootIcons.rejected,
        title: 'Reason for rejection',
        message: '$reason$by',
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  final OrderHistoryItem item;

  const _ProductRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final List<String> details = <String>[
      if (item.packingSize.isNotEmpty) item.packingSize,
      if (item.expiry.isNotEmpty) 'Expiry ${item.expiry}',
      if (item.unitPrice > 0)
        '${quantityLabel(item.qty, item.uom)} x RM ${item.unitPrice.toStringAsFixed(2)}',
    ];
    final List<String> batches = <String>[
      for (final MapEntry<int, Map<String, dynamic>> e
          in item.shelfBatches.asMap().entries)
        if (_asInt(e.value['qty']) != 0 || _asString(e.value['expiry']) != '')
          'Shelf batch ${e.key + 1}: ${quantityLabel(_asInt(e.value['qty']), item.uom)}'
              '${_asString(e.value['expiry']).isEmpty ? '' : ' · ${_asString(e.value['expiry'])}'}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LongNameText(
                  item.name,
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
                if (details.isNotEmpty)
                  Text(
                    details.join(' · '),
                    style: ScootType.small.copyWith(color: c.text2),
                  ),
                for (final String batch in batches)
                  Text(batch, style: ScootType.small.copyWith(color: c.muted)),
                if (item.remarks.trim().isNotEmpty)
                  Text(
                    item.remarks,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.small.copyWith(
                      color: c.muted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            item.unitPrice > 0
                ? 'RM ${item.subtotal.toStringAsFixed(2)}'
                : quantityLabel(item.qty, item.uom),
            style: ScootType.bodyStrong.copyWith(color: c.ink),
          ),
        ],
      ),
    );
  }
}

ScootTone _statusTone(String status) {
  switch (status) {
    case 'Cancelled':
    case 'Rejected':
      return ScootTone.danger;
    case 'Submitted':
    case 'Approved':
    case 'Completed':
      return ScootTone.success;
    default:
      return ScootTone.warning;
  }
}

String _formatDate(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${date.day.toString().padLeft(2, '0')} ${months[date.month - 1]} ${date.year}';
}

String _formatDateTime(DateTime dt) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final h = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
  final ap = dt.hour >= 12 ? 'PM' : 'AM';
  final mm = dt.minute.toString().padLeft(2, '0');
  final ss = dt.second.toString().padLeft(2, '0');
  return '${months[dt.month - 1]} ${dt.day}, ${dt.year}, $h:$mm:$ss $ap';
}

String _asString(dynamic value, {String fallback = ''}) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return fallback;
}

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double _asDouble(dynamic value, {double fallback = 0.0}) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

List<Map<String, dynamic>> _asMapList(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((raw) => Map<String, dynamic>.from(raw))
      .toList();
}
