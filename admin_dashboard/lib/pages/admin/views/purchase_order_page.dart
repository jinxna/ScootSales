import 'dart:async';

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
  late (DateTime, DateTime) _week = _weekBounds(_anchor);
  bool _autoAnchored = false;
  bool _presenceCheckFailed = false;
  final Set<String> _issuing = <String>{};
  final Set<String> _changingStatus = <String>{};
  final Map<String, bool> _hasPurchaseOrder = <String, bool>{};
  final Set<String> _checkingPresence = <String>{};
  Set<String> _watchedMissing = <String>{};
  StreamSubscription<Set<String>>? _missingWatch;
  late Stream<List<Map<String, dynamic>>> _posStream = _openPurchaseOrders();
  late Stream<DateTime?> _latestStream = _openLatest();
  late Stream<List<Map<String, dynamic>>> _ordersStream = _openOrders();

  Stream<List<Map<String, dynamic>>> _openPurchaseOrders() =>
      _repository.watchPurchaseOrders(
        currentUser: widget.currentUser,
        from: _week.$1,
        before: _week.$2,
      );

  Stream<DateTime?> _openLatest() => _repository
      .watchLatestPurchaseOrderIssuedAt(currentUser: widget.currentUser);

  Stream<List<Map<String, dynamic>>> _openOrders() => _repository
      .watchCollectionRaw('orders', orderBy: 'submittedAt', descending: true);

  @override
  void dispose() {
    unawaited(_missingWatch?.cancel());
    super.dispose();
  }

  void _watchMissing(Set<String> missing) {
    if (_watchedMissing.length == missing.length &&
        _watchedMissing.containsAll(missing)) {
      return;
    }
    _watchedMissing = missing;
    unawaited(_missingWatch?.cancel());
    _missingWatch = null;
    if (missing.isEmpty) return;
    _missingWatch = _repository
        .watchPurchaseOrderIdsAmong(missing)
        .listen(
          (Set<String> existing) {
            if (!mounted) return;
            setState(() {
              for (final String id in existing) {
                _hasPurchaseOrder[id] = true;
              }
            });
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error(
              'purchase_order_presence_watch_failed',
              error: error,
              stackTrace: stackTrace,
              fields: <String, Object?>{'orderCount': missing.length},
            );
            if (mounted) setState(() => _presenceCheckFailed = true);
          },
        );
  }

  void _retry() {
    unawaited(_missingWatch?.cancel());
    _missingWatch = null;
    _watchedMissing = <String>{};
    setState(() {
      _presenceCheckFailed = false;
      _posStream = _openPurchaseOrders();
      _latestStream = _openLatest();
      _ordersStream = _openOrders();
    });
  }

  void _showWeekOf(DateTime anchor) {
    setState(() {
      _anchor = anchor;
      final (DateTime, DateTime) week = _weekBounds(anchor);
      if (week != _week) {
        _week = week;
        _posStream = _openPurchaseOrders();
      }
    });
  }

  bool _inWeek(DateTime? date) =>
      date != null && !date.isBefore(_week.$1) && date.isBefore(_week.$2);

  Future<void> _checkPresence(Set<String> orderIds) async {
    _checkingPresence.addAll(orderIds);
    try {
      final Set<String> existing = await _repository.purchaseOrderIdsAmong(
        orderIds,
      );
      if (!mounted) return;
      setState(() {
        for (final String id in orderIds) {
          _hasPurchaseOrder[id] = existing.contains(id);
        }
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'purchase_order_presence_check_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{'orderCount': orderIds.length},
      );
      if (mounted) setState(() => _presenceCheckFailed = true);
    } finally {
      _checkingPresence.removeAll(orderIds);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DateTime?>(
      stream: _latestStream,
      builder: (BuildContext context, AsyncSnapshot<DateTime?> latest) {
        return StreamBuilder<List<Map<String, dynamic>>>(
          key: ValueKey<DateTime>(_week.$1),
          stream: _posStream,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<Map<String, dynamic>>> pos,
              ) {
                if (_presenceCheckFailed || pos.hasError || latest.hasError) {
                  return _view(phase: ScootLoadPhase.error);
                }
                if (!pos.hasData ||
                    latest.connectionState == ConnectionState.waiting) {
                  return _view(phase: ScootLoadPhase.loading);
                }
                final List<Map<String, dynamic>> issued = pos.data!
                    .where((Map<String, dynamic> po) => !isDemoRow(po))
                    .toList(growable: false);
                final DateTime? latestIssuedAt = latest.data?.toLocal();
                if (!widget.currentUser.isAdmin) {
                  return _ready(issued, latestActivity: latestIssuedAt);
                }
                return StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _ordersStream,
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<List<Map<String, dynamic>>> orders,
                      ) {
                        if (orders.hasError) {
                          return _view(phase: ScootLoadPhase.error);
                        }
                        if (!orders.hasData) {
                          return _view(phase: ScootLoadPhase.loading);
                        }
                        return _readyForAdmin(
                          issued,
                          orders.data!,
                          latestIssuedAt,
                        );
                      },
                );
              },
        );
      },
    );
  }

  Widget _readyForAdmin(
    List<Map<String, dynamic>> issued,
    List<Map<String, dynamic>> orders,
    DateTime? latestIssuedAt,
  ) {
    final Set<String> issuedIds = issued
        .map((Map<String, dynamic> po) => '${po['docId']}')
        .toSet();
    final List<Map<String, dynamic>> approved = orders
        .where(
          (Map<String, dynamic> o) =>
              !isDemoRow(o) &&
              orderStatus(o) == 'approved' &&
              !issuedIds.contains('${o['docId']}'),
        )
        .toList(growable: false);
    final List<Map<String, dynamic>> approvedInWeek = approved
        .where((Map<String, dynamic> o) => _inWeek(orderDateFromRow(o)))
        .toList(growable: false);
    if (latestIssuedAt == null) {
      _scheduleWatch(<String>{});
      DateTime? latestWithoutPo;
      for (final Map<String, dynamic> order in approved) {
        final DateTime? date = orderDateFromRow(order);
        if (date != null &&
            (latestWithoutPo == null || date.isAfter(latestWithoutPo))) {
          latestWithoutPo = date;
        }
      }
      return _ready(
        issued,
        withoutPurchaseOrder: approvedInWeek,
        orders: orders,
        latestActivity: latestWithoutPo,
      );
    }
    final Set<String> unchecked = <String>{
      for (final Map<String, dynamic> order in approvedInWeek)
        if (!_hasPurchaseOrder.containsKey('${order['docId']}'))
          '${order['docId']}',
    };
    final Set<String> toCheck = unchecked.difference(_checkingPresence);
    if (toCheck.isNotEmpty) unawaited(_checkPresence(toCheck));
    if (unchecked.isNotEmpty && !_autoAnchored) {
      return _view(phase: ScootLoadPhase.loading);
    }
    final List<Map<String, dynamic>> withoutPurchaseOrder = approvedInWeek
        .where(
          (Map<String, dynamic> order) =>
              _hasPurchaseOrder['${order['docId']}'] == false,
        )
        .toList(growable: false);
    _scheduleWatch(<String>{
      for (final Map<String, dynamic> order in withoutPurchaseOrder)
        '${order['docId']}',
    });
    return _ready(
      issued,
      withoutPurchaseOrder: withoutPurchaseOrder,
      orders: orders,
      latestActivity: latestIssuedAt,
    );
  }

  void _scheduleWatch(Set<String> missing) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _watchMissing(missing);
    });
  }

  String get _weekLabel =>
      '${purchaseOrderDate(_week.$1)} – ${purchaseOrderDate(_week.$2.subtract(const Duration(days: 1)))}';

  Widget _ready(
    List<Map<String, dynamic>> issued, {
    List<Map<String, dynamic>> withoutPurchaseOrder =
        const <Map<String, dynamic>>[],
    List<Map<String, dynamic>> orders = const <Map<String, dynamic>>[],
    DateTime? latestActivity,
  }) {
    if (!_autoAnchored) {
      _autoAnchored = true;
      if (latestActivity != null &&
          issued.isEmpty &&
          withoutPurchaseOrder.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showWeekOf(latestActivity);
        });
      }
    }
    final Map<String, String> names = <String, String>{
      for (final Map<String, dynamic> order in orders)
        if (dataText(order['salesmanName']).isNotEmpty)
          dataText(order['docId']): dataText(order['salesmanName']),
    };
    return _view(
      phase: ScootLoadPhase.ready,
      weekPos: issued,
      weekLegacy: withoutPurchaseOrder,
      names: names,
      hasAny: latestActivity != null || withoutPurchaseOrder.isNotEmpty,
      onJump: latestActivity == null ? null : () => _showWeekOf(latestActivity),
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
          _showWeekOf(_anchor.subtract(const Duration(days: 7))),
      onNextWeek: () => _showWeekOf(_anchor.add(const Duration(days: 7))),
      onThisWeek: () => _showWeekOf(DateTime.now()),
      weekPos: weekPos,
      weekLegacy: weekLegacy,
      hasAnyActivity: hasAny,
      isAdmin: widget.currentUser.isAdmin,
      issuing: _issuing,
      changing: _changingStatus,
      onIssue: _issue,
      onChangeStatus: _changeStatus,
      loadOrderLines: _loadOrderLines,
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

  Future<List<Map<String, dynamic>>> _loadOrderLines(String docId) async {
    try {
      return await _repository.purchaseOrderLines(docId);
    } catch (error, stackTrace) {
      AppLogger.error(
        'purchase_order_lines_load_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{'orderDocumentId': docId},
      );
      rethrow;
    }
  }

  Future<void> _issue(String docId) async {
    if (docId.isEmpty) return;
    setState(() => _issuing.add(docId));
    bool hasPurchaseOrder = false;
    try {
      final PurchaseOrderIssueResult? result = await _repository
          .issuePurchaseOrder(
            orderDocumentId: docId,
            currentUser: widget.currentUser,
          );
      hasPurchaseOrder = result != null;
      if (result == PurchaseOrderIssueResult.alreadyIssued) {
        if (mounted) {
          showCmsToast(
            context,
            'A purchase order already exists for this order.',
          );
        }
      }
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
      if (mounted) {
        setState(() {
          _issuing.remove(docId);
          if (hasPurchaseOrder) {
            _hasPurchaseOrder[docId] = true;
          } else {
            _hasPurchaseOrder.remove(docId);
          }
        });
      }
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
