import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../utils/app_logger.dart';
import '../../../services/audit_log_service.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../../../widgets/confirm_destructive_dialog.dart';
import 'purchase_orders_view.dart';

class PurchaseOrderPage extends StatefulWidget {
  const PurchaseOrderPage({
    super.key,
    required this.currentUser,
    this.onNavigateRequested,
  });

  final UserProfile currentUser;
  final ValueChanged<String>? onNavigateRequested;

  @override
  State<PurchaseOrderPage> createState() => _PurchaseOrderPageState();
}

class _PurchaseOrderPageState extends State<PurchaseOrderPage> {
  final CmsRepository _repository = CmsRepository();

  DateTime _anchor = DateTime.now();
  bool _autoAnchored = false;
  final Set<String> _issuing = <String>{};
  final Set<String> _changingStatus = <String>{};
  late Stream<List<Map<String, dynamic>>> _posStream = _openPurchaseOrders();
  late Stream<List<Map<String, dynamic>>> _ordersStream = _openOrders();

  Stream<List<Map<String, dynamic>>> _openPurchaseOrders() =>
      _repository.watchPurchaseOrders(currentUser: widget.currentUser);

  Stream<List<Map<String, dynamic>>> _openOrders() => _repository
      .watchCollectionRaw('orders', orderBy: 'submittedAt', descending: true);

  void _retry() {
    setState(() {
      _posStream = _openPurchaseOrders();
      _ordersStream = _openOrders();
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _posStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> pos,
          ) {
            if (pos.hasError) return _view(phase: ScootLoadPhase.error);
            if (pos.connectionState == ConnectionState.waiting &&
                !pos.hasData) {
              return _view(phase: ScootLoadPhase.loading);
            }
            final List<Map<String, dynamic>> issued =
                (pos.data ?? <Map<String, dynamic>>[])
                    .where((Map<String, dynamic> po) => !isDemoRow(po))
                    .toList(growable: false);
            if (!widget.currentUser.isAdmin) {
              return _ready(issued, const <Map<String, dynamic>>[]);
            }
            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: _ordersStream,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<Map<String, dynamic>>> orders,
                  ) {
                    final Set<String> issuedIds = issued
                        .map((Map<String, dynamic> po) => '${po['docId']}')
                        .toSet();
                    final List<Map<String, dynamic>> all =
                        orders.data ?? <Map<String, dynamic>>[];
                    final List<Map<String, dynamic>> legacy = all
                        .where(
                          (Map<String, dynamic> o) =>
                              !isDemoRow(o) &&
                              orderStatus(o) == 'approved' &&
                              !issuedIds.contains('${o['docId']}'),
                        )
                        .toList(growable: false);
                    return _ready(issued, legacy, orders: all);
                  },
            );
          },
    );
  }

  String get _weekLabel {
    final (DateTime start, DateTime endExclusive) = _weekBounds(_anchor);
    return '${purchaseOrderDate(start)} – ${purchaseOrderDate(endExclusive.subtract(const Duration(days: 1)))}';
  }

  Widget _ready(
    List<Map<String, dynamic>> issued,
    List<Map<String, dynamic>> legacy, {
    List<Map<String, dynamic>> orders = const <Map<String, dynamic>>[],
  }) {
    if (!_autoAnchored) {
      _autoAnchored = true;
      _jumpToLatest(issued, legacy, initial: true);
    }
    final (DateTime start, DateTime endExclusive) = _weekBounds(_anchor);
    bool inWeek(DateTime? d) =>
        d != null && !d.isBefore(start) && d.isBefore(endExclusive);
    final Map<String, String> names = <String, String>{
      for (final Map<String, dynamic> order in orders)
        if (dataText(order['salesmanName']).isNotEmpty)
          dataText(order['docId']): dataText(order['salesmanName']),
    };
    return _view(
      phase: ScootLoadPhase.ready,
      weekPos: issued
          .where((Map<String, dynamic> po) => inWeek(purchaseOrderIssuedAt(po)))
          .toList(growable: false),
      weekLegacy: legacy
          .where((Map<String, dynamic> o) => inWeek(orderDateFromRow(o)))
          .toList(growable: false),
      names: names,
      hasAny: issued.isNotEmpty || legacy.isNotEmpty,
      onJump: () => _jumpToLatest(issued, legacy),
    );
  }

  Widget _view({
    required ScootLoadPhase phase,
    List<Map<String, dynamic>> weekPos = const <Map<String, dynamic>>[],
    List<Map<String, dynamic>> weekLegacy = const <Map<String, dynamic>>[],
    Map<String, String> names = const <String, String>{},
    bool hasAny = false,
    VoidCallback? onJump,
  }) {
    return PurchaseOrdersView(
      phase: phase,
      onRetry: _retry,
      weekLabel: _weekLabel,
      canGoNext: _anchor.isBefore(
        DateTime.now().subtract(const Duration(days: 1)),
      ),
      onPreviousWeek: () =>
          setState(() => _anchor = _anchor.subtract(const Duration(days: 7))),
      onNextWeek: () =>
          setState(() => _anchor = _anchor.add(const Duration(days: 7))),
      onThisWeek: () => setState(() => _anchor = DateTime.now()),
      weekPos: weekPos,
      weekLegacy: weekLegacy,
      hasAnyActivity: hasAny,
      isAdmin: widget.currentUser.isAdmin,
      issuing: _issuing,
      changing: _changingStatus,
      onIssue: _issue,
      onChangeStatus: _changeStatus,
      salespersonNames: names,
      onJumpToLatest: onJump,
      onOpenOrders: widget.onNavigateRequested == null
          ? null
          : () => widget.onNavigateRequested!('all_orders'),
    );
  }

  (DateTime, DateTime) _weekBounds(DateTime anchor) {
    final DateTime midnight = DateTime(anchor.year, anchor.month, anchor.day);
    final DateTime monday = midnight.subtract(
      Duration(days: midnight.weekday - 1),
    );
    return (monday, monday.add(const Duration(days: 7)));
  }

  DateTime? _latestActivity(
    List<Map<String, dynamic>> issued,
    List<Map<String, dynamic>> legacy,
  ) {
    DateTime? latest;
    void consider(DateTime? d) {
      if (d != null && (latest == null || d.isAfter(latest!))) latest = d;
    }

    for (final Map<String, dynamic> po in issued) {
      consider(purchaseOrderIssuedAt(po));
    }
    for (final Map<String, dynamic> o in legacy) {
      consider(orderDateFromRow(o));
    }
    return latest;
  }

  void _jumpToLatest(
    List<Map<String, dynamic>> issued,
    List<Map<String, dynamic>> legacy, {
    bool initial = false,
  }) {
    final DateTime? latest = _latestActivity(issued, legacy);
    if (latest == null) return;
    if (initial) {
      final (DateTime start, DateTime end) = _weekBounds(_anchor);
      final bool hasCurrent =
          issued.any((Map<String, dynamic> po) {
            final DateTime? d = purchaseOrderIssuedAt(po);
            return d != null && !d.isBefore(start) && d.isBefore(end);
          }) ||
          legacy.any((Map<String, dynamic> o) {
            final DateTime? d = orderDateFromRow(o);
            return d != null && !d.isBefore(start) && d.isBefore(end);
          });
      if (hasCurrent) return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _anchor = latest);
    });
  }

  Future<void> _issue(String docId) async {
    if (docId.isEmpty) return;
    setState(() => _issuing.add(docId));
    try {
      await _repository.issuePurchaseOrder(
        orderDocumentId: docId,
        currentUser: widget.currentUser,
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'purchase_order_issue_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{'orderDocumentId': docId},
      );
      if (mounted) {
        showCmsToast(
          context,
          userFacingError(error, action: 'issue the purchase order'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _issuing.remove(docId));
    }
  }

  Future<void> _changeStatus(Map<String, dynamic> po, String target) async {
    final String docId = dataText(po['docId']);
    if (docId.isEmpty || _changingStatus.contains(docId)) return;
    final String number = dataText(po['poNumber'], fallback: docId);
    final bool cancel = target == 'cancelled';
    final bool confirmed = await confirmDestructive(
      context,
      title: cancel ? 'Cancel purchase order?' : 'Mark as fulfilled?',
      message: cancel
          ? 'Cancel $number? A cancelled purchase order cannot be reopened.'
          : 'Mark $number as fulfilled? This cannot be undone.',
      confirmLabel: cancel ? 'Cancel PO' : 'Mark fulfilled',
      cancelLabel: 'Keep as is',
    );
    if (!confirmed || !mounted) return;
    final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    setState(() => _changingStatus.add(docId));
    try {
      await FirebaseFirestore.instance
          .collection('purchase_orders')
          .doc(docId)
          .update(<String, dynamic>{
            'status': target,
            'statusChangedAt': FieldValue.serverTimestamp(),
            'statusChangedByUid': uid,
          });
      await AuditLogService.instance.record(
        action: 'updated',
        entityType: 'purchase_orders',
        entityId: docId,
        summary: '${cancel ? 'Cancelled' : 'Fulfilled'} purchase order $number',
        actor: widget.currentUser,
      );
      if (!mounted) return;
      showCmsToast(
        context,
        cancel ? '$number cancelled.' : '$number marked fulfilled.',
      );
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(
          error,
          action: cancel
              ? 'cancel the purchase order'
              : 'update the purchase order',
        ),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _changingStatus.remove(docId));
    }
  }
}
