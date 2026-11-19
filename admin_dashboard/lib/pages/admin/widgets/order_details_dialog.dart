import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../security/order_authorization.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/order_limit_warnings.dart';
import '../../../utils/money_format.dart';
import '../../../utils/quantity_unit.dart';
import '../../../utils/server_price_check.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/gps_accuracy.dart';
import '../../../utils/user_facing_error.dart';

class OrderDetailsDialog extends StatefulWidget {
  const OrderDetailsDialog({
    super.key,
    required this.orderDocumentId,
    required this.repository,
    this.initialOrder,
    this.currentUser,
    this.showActions = false,
  });

  final String orderDocumentId;

  final CmsRepository repository;

  final UserProfile? currentUser;

  final Map<String, dynamic>? initialOrder;

  final bool showActions;

  static Future<String?> show(
    BuildContext context, {
    required String orderDocumentId,
    CmsRepository? repository,
    Map<String, dynamic>? initialOrder,
    UserProfile? currentUser,
    bool showActions = false,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => OrderDetailsDialog(
        orderDocumentId: orderDocumentId,
        repository: repository ?? CmsRepository(),
        initialOrder: initialOrder,
        currentUser: currentUser,
        showActions: showActions,
      ),
    );
  }

  @override
  State<OrderDetailsDialog> createState() => _OrderDetailsDialogState();
}

class _OrderDetailsDialogState extends State<OrderDetailsDialog> {
  bool _busy = false;
  late final Future<Map<String, dynamic>?> _specialRequest =
      _loadSpecialRequest();

  Future<Map<String, dynamic>?> _loadSpecialRequest() async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> doc = await FirebaseFirestore
          .instance
          .collection('special_requests')
          .doc(widget.orderDocumentId)
          .get();
      return doc.exists ? doc.data() : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>>? _limitWarnings;
  String _limitKey = '';

  Future<List<String>> _limitWarningsFor(List<Map<String, dynamic>> items) {
    final String key = items
        .map(
          (Map<String, dynamic> it) =>
              '${it['productId']}:${orderLineQuantity(it)}',
        )
        .join(',');
    if (_limitWarnings != null && key == _limitKey) return _limitWarnings!;
    _limitKey = key;
    return _limitWarnings = readOrderLimitWarnings(items);
  }

  Widget _limitWarningSection(List<Map<String, dynamic>> items) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<String>>(
      future: _limitWarningsFor(items),
      builder: (BuildContext context, AsyncSnapshot<List<String>> snap) {
        final List<String> warnings = snap.data ?? const <String>[];
        if (warnings.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.warning_amber_outlined, color: scheme.error, size: 19),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Quantity above the product limit:\n${warnings.join('\n')}',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _specialRequestSection() {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _specialRequest,
      builder:
          (BuildContext context, AsyncSnapshot<Map<String, dynamic>?> snap) {
            final Map<String, dynamic>? request = snap.data;
            if (request == null) return const SizedBox.shrink();
            final String status = _text(
              request['status'],
              fallback: '—',
            ).replaceAll('_', ' ');
            return Padding(
              padding: const EdgeInsets.only(top: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _sectionTitle('Special request'),
                  const SizedBox(height: 8),
                  Wrap(
                    runSpacing: 12,
                    spacing: 16,
                    children: <Widget>[
                      _kv(
                        'Type',
                        _text(
                          request['requestedItem'] ?? request['requestType'],
                          fallback: '—',
                        ),
                        icon: Icons.flag_outlined,
                      ),
                      _kv('Status', status, icon: ScootIcons.clock),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _text(request['reason'], fallback: 'No reason given.'),
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ],
              ),
            );
          },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 720),
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: widget.repository.watchOrder(widget.orderDocumentId),
          builder: (context, snap) {
            final DocumentSnapshot<Map<String, dynamic>>? doc = snap.data;
            final bool deleted =
                doc != null && !doc.exists && !doc.metadata.isFromCache;
            final data = deleted ? null : doc?.data() ?? widget.initialOrder;
            if (data == null) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                  height: 240,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return _missingOrderView();
            }
            return _buildContent(data);
          },
        ),
      ),
    );
  }

  Widget _missingOrderView() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 38, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'Order ${widget.orderDocumentId} could not be found.',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'It may have been deleted. Reload the list and try again.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(Map<String, dynamic> order) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final items = authoritativeOrderItems(order);
    final totalBoxes = orderQuantity(order);
    final totalPrice = orderRevenue(order);
    final Object? rawStatus = order['status'];
    final String status = rawStatus is String && rawStatus.trim().isNotEmpty
        ? rawStatus
        : 'submitted';
    final String? completenessIssue = orderCompletenessIssue(order);
    final signatureTimestamps =
        (order['signatureTimestamps'] as Map<String, dynamic>? ?? const {});

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(order, status),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _summaryRow(
                  order,
                  items.length,
                  items.isEmpty
                      ? quantityLabel(totalBoxes, null)
                      : totalQuantityLabel(
                          items.map((it) => (orderLineQuantity(it), uomOf(it))),
                        ),
                  totalPrice,
                ),
                _limitWarningSection(items),
                _lateArrivalSection(order),
                _heldForReviewSection(order),
                _priceMismatchSection(order, items),
                if (status.trim().toLowerCase() == 'submitted' &&
                    completenessIssue != null) ...[
                  const SizedBox(height: 14),
                  _incompleteOrderNotice(completenessIssue),
                ],
                const SizedBox(height: 18),
                _sectionTitle('Items (${items.length})'),
                const SizedBox(height: 8),
                items.isEmpty
                    ? Text(
                        'No items recorded on this order.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      )
                    : OrderItemsTable(items: items),
                if (signatureTimestamps.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  _sectionTitle('Department sign-off'),
                  const SizedBox(height: 8),
                  ...signatureTimestamps.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.draw_outlined,
                            size: 16,
                            color: Color(0xFF27AE60),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${e.key} • ${e.value}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_text(
                  order['rejectionRemark'],
                  fallback: '',
                ).isNotEmpty) ...[
                  const SizedBox(height: 22),
                  _sectionTitle('Rejection remark'),
                  const SizedBox(height: 6),
                  Text(
                    _text(order['rejectionRemark'], fallback: ''),
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ],
                _specialRequestSection(),
                const SizedBox(height: 22),
                _locationSection(order),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        _actions(order, status),
      ],
    );
  }

  Widget _header(Map<String, dynamic> order, String status) =>
      OrderDetailsHeader(
        title: _text(order['orderId'] ?? widget.orderDocumentId, fallback: '—'),
        subtitle: _text(
          order['retailerName'] ?? order['outlet'],
          fallback: 'Retailer unknown',
        ),
        status: status,
        priceCheck: ServerPriceCheck.fromOrder(order),
        onClose: _busy ? null : () => Navigator.of(context).pop(),
      );

  Widget _heldForReviewSection(Map<String, dynamic> order) {
    final String note = _text(order['reviewNote'], fallback: '');
    if (note.isEmpty ||
        _text(order['status'], fallback: '') != 'held_for_review') {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.pause_circle_outline,
            size: 16,
            color: Color(0xFFB45309),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              note,
              style: const TextStyle(fontSize: 12, color: Color(0xFF92400E)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lateArrivalSection(Map<String, dynamic> order) {
    final String? notice = lateArrivalNotice(order);
    if (notice == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.schedule_send, size: 16, color: Color(0xFFB45309)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              notice,
              style: const TextStyle(fontSize: 12, color: Color(0xFF92400E)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(
    Map<String, dynamic> order,
    int itemCount,
    String totalQuantity,
    double totalPrice,
  ) {
    final submittedAt = _formatDateTime(
      order['submittedAt'] ?? order['createdAt'],
    );
    final salesman = _text(
      order['salesmanName'] ??
          order['salesman_name'] ??
          order['submittedByName'],
      fallback: 'Unknown',
    );
    return Wrap(
      runSpacing: 12,
      spacing: 16,
      children: [
        _kv('Salesman', salesman, icon: ScootIcons.person),
        _kv('Submitted', submittedAt, icon: Icons.schedule_outlined),
        _kv('Items', '$itemCount', icon: ScootIcons.products),
        _kv('Total quantity', totalQuantity, icon: Icons.dynamic_feed_outlined),
        _kv('Total value', formatRm(totalPrice), icon: ScootIcons.pricing),
      ],
    );
  }

  String _mismatchLineName(
    Map<String, String> names,
    ServerPriceCheckLine line,
  ) {
    final String name = names[line.productId] ?? '';
    if (name.isNotEmpty) return name;
    return line.productId.isEmpty ? 'Unknown product' : line.productId;
  }

  Widget _priceMismatchSection(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> items,
  ) {
    final ServerPriceCheck? check = ServerPriceCheck.fromOrder(order);
    if (check == null || check.status != ServerPriceCheckStatus.mismatch) {
      return const SizedBox.shrink();
    }
    final DsoColors dso = context.dso;
    final Map<String, String> names = <String, String>{
      for (final Map<String, dynamic> item in items)
        _text(item['productId'], fallback: ''): _text(
          item['productName'] ?? item['name'],
          fallback: '',
        ),
    };
    final TextStyle style = TextStyle(color: dso.dangerText, fontSize: 12);
    final TextStyle strong = style.copyWith(fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: dso.dangerSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: dso.danger.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              check.names.isEmpty
                  ? 'Prices differ from the price list'
                  : check.mismatchedLines.isEmpty
                  ? 'Names differ from the current records'
                  : 'Prices and names differ from the current records',
              style: strong,
            ),
            if (check.reasonText != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(check.reasonText!, style: style),
            ],
            for (final ServerPriceCheckName name in check.names)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${name.label} · order shows "${name.submitted}"'
                  ' · current record says "${name.expected}"',
                  style: style,
                ),
              ),
            for (final ServerPriceCheckLine line in check.mismatchedLines)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${_mismatchLineName(names, line)}'
                  ' · quantity ${line.quantity ?? '—'}'
                  ' · submitted ${formatSenAsRm(line.submittedUnitSen)} each'
                  ' · expected ${formatSenAsRm(line.expectedUnitSen)} each',
                  style: style,
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Submitted total ${formatSenAsRm(check.submittedTotalSen)}'
              ' · Expected total ${formatSenAsRm(check.expectedTotalSen)}',
              style: strong,
            ),
          ],
        ),
      ),
    );
  }

  Widget _incompleteOrderNotice(String issue) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_outlined, color: scheme.error, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Incomplete order — approval is disabled. $issue Reject it or close this window.',
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static bool _hasCoordinates(Map<String, dynamic> data) {
    final Object? lat = data['latitude'] ?? data['gpsLatitude'];
    final Object? lng = data['longitude'] ?? data['gpsLongitude'];
    return lat is num && lng is num;
  }

  Widget _locationSection(Map<String, dynamic> order) {
    if (_hasCoordinates(order)) return _locationBlock(order);
    return FutureBuilder<Map<String, dynamic>?>(
      future: _trackingLocation(order),
      builder:
          (BuildContext context, AsyncSnapshot<Map<String, dynamic>?> snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 16,
                child: LinearProgressIndicator(minHeight: 2),
              );
            }
            final Map<String, dynamic>? fix = snap.data;
            return _locationBlock(
              fix == null ? order : <String, dynamic>{...order, ...fix},
            );
          },
    );
  }

  Future<Map<String, dynamic>?> _trackingLocation(
    Map<String, dynamic> order,
  ) async {
    final Object? explicitId = order['orderId'];
    final String orderId = explicitId is String && explicitId.isNotEmpty
        ? explicitId
        : widget.orderDocumentId;
    try {
      final DocumentSnapshot<Map<String, dynamic>> snapshot =
          await FirebaseFirestore.instance
              .collection('gps_tracking')
              .doc('order_$orderId')
              .get();
      final Map<String, dynamic>? data = snapshot.data();
      if (data == null ||
          !_hasCoordinates(data) ||
          !trackingFixBelongsToOrder(order, data)) {
        return null;
      }
      final Object? storedEvidence = data['locationEvidence'];
      return <String, dynamic>{
        'latitude': data['latitude'],
        'longitude': data['longitude'],
        'locationVerification': data['locationVerification'],
        'locationEvidence': storedEvidence is Map
            ? Map<String, dynamic>.from(storedEvidence)
            : <String, dynamic>{
                'mode': data['locationVerification'],
                'accuracyMeters': data['accuracyMeters'],
              },
      };
    } catch (error) {
      AppLogger.error('order_details_tracking_read', error: error);
      return null;
    }
  }

  Widget _locationBlock(Map<String, dynamic> order) {
    final double? lat = dataNumberOrNull(
      order['latitude'] ?? order['gpsLatitude'],
    );
    final double? lng = dataNumberOrNull(
      order['longitude'] ?? order['gpsLongitude'],
    );
    final Object? rawEvidence = order['locationEvidence'];
    final Map<String, dynamic> evidence = rawEvidence is Map
        ? Map<String, dynamic>.from(rawEvidence)
        : <String, dynamic>{};
    final String mode = _text(
      evidence['mode'] ?? order['locationVerification'],
      fallback: '',
    );
    final String failureCode = _text(evidence['failureCode'], fallback: '');
    if (lat == null || lng == null) {
      return Row(
        children: [
          const Icon(
            ScootIcons.locationOff,
            size: 16,
            color: Color(0xFFB45309),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Location: no GPS captured'
              '${failureCode.isEmpty ? '' : ' (${failureCode.replaceAll('_', ' ')})'}',
              style: const TextStyle(fontSize: 13, color: Color(0xFF92400E)),
            ),
          ),
        ],
      );
    }
    final bool verified = mode == 'location_verified';
    final num? accuracy = evidence['accuracyMeters'] as num?;
    final num? distance = evidence['distanceMeters'] as num?;
    final List<String> parts = <String>[
      if (accuracy != null)
        '${accuracy.round()} m accuracy${isLowAccuracy(accuracy) ? ' (low)' : ''}',
      verified
          ? 'at the verified shop location'
          : failureCode == 'outside_radius'
          ? 'away from the shop pin'
          : 'not checked against the shop pin',
      if (distance != null) '${distance.round()} m from the shop',
    ];
    final Color tone = verified
        ? const Color(0xFF166534)
        : const Color(0xFF92400E);
    final String coordinates =
        '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    return Row(
      children: [
        Icon(
          verified ? Icons.verified_outlined : Icons.warning_amber_outlined,
          size: 16,
          color: verified ? const Color(0xFF15803D) : const Color(0xFFB45309),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'Location: ${parts.join(', ')}',
            style: TextStyle(fontSize: 13, color: tone),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: coordinates,
          child: TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
              textStyle: const TextStyle(fontSize: 12),
            ),
            onPressed: () => unawaited(
              launchUrl(
                Uri.https('www.openstreetmap.org', '/', <String, String>{
                  'mlat': lat.toStringAsFixed(5),
                  'mlon': lng.toStringAsFixed(5),
                  'zoom': '18',
                }),
                mode: LaunchMode.externalApplication,
              ),
            ),
            child: const Text('Open map'),
          ),
        ),
      ],
    );
  }

  Widget _actions(Map<String, dynamic> order, String status) {
    final UserProfile? currentUser = widget.currentUser;
    final bool canManage =
        widget.showActions &&
        currentUser != null &&
        OrderAuthorization.canManageOrder(currentUser, order);
    final bool canDecide =
        canManage && OrderAuthorization.canDecideOrder(currentUser, order);
    final canApprove =
        canDecide && OrderAuthorization.canApproveOrder(currentUser, order);
    final canReject = canDecide;
    final bool canDelete =
        widget.showActions &&
        currentUser != null &&
        currentUser.isDeveloper &&
        status.toLowerCase() == 'draft' &&
        OrderAuthorization.canDeleteOrder(currentUser);
    return OrderDetailsActions(
      busy: _busy,
      onClose: () => Navigator.of(context).pop(),
      onDelete: canDelete ? () => _runAction(order, 'delete') : null,
      onReject: canReject ? () => _runAction(order, 'reject') : null,
      onApprove: canApprove ? () => _runAction(order, 'approve') : null,
    );
  }

  Future<void> _runAction(Map<String, dynamic> order, String kind) async {
    String? rejectionRemark;
    if (kind == 'reject') {
      rejectionRemark = await _askRejectionRemark();
      if (rejectionRemark == null) return;
    } else if (kind == 'approve') {
      final List<String> warnings = await _limitWarningsFor(
        authoritativeOrderItems(order),
      );
      if (!mounted) return;
      if (warnings.isNotEmpty) {
        final bool? confirm = await _confirm(
          title: 'Quantity above the product limit',
          message: '${warnings.join('\n')}\n\nApprove this order anyway?',
          confirmLabel: 'Approve anyway',
        );
        if (confirm != true) return;
      }
    } else if (kind == 'delete') {
      final bool? confirm = await _confirm(
        title: 'Delete order?',
        message:
            'This permanently removes this order. The action cannot be undone.',
        confirmLabel: 'Delete',
        destructive: true,
      );
      if (confirm != true) return;
    }
    setState(() => _busy = true);
    try {
      switch (kind) {
        case 'approve':
          await widget.repository.approveOrder(
            orderDocumentId: widget.orderDocumentId,
            currentUser: widget.currentUser!,
            order: order,
          );
          break;
        case 'reject':
          await widget.repository.rejectOrder(
            orderDocumentId: widget.orderDocumentId,
            currentUser: widget.currentUser!,
            order: order,
            remark: rejectionRemark,
          );
          break;
        case 'delete':
          await widget.repository.deleteOrder(
            orderDocumentId: widget.orderDocumentId,
            currentUser: widget.currentUser!,
            order: order,
          );
          break;
      }
      if (mounted) Navigator.of(context).pop(kind);
    } catch (error, stackTrace) {
      AppLogger.error(
        'order_detail_action_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{
          'orderDocumentId': widget.orderDocumentId,
          'action': kind,
          'status': _text(order['status'], fallback: ''),
        },
      );
      if (mounted) {
        final String message = switch (error) {
          OrderDecisionConflictException(message: final String reason) =>
            reason,
          FirebaseException(code: 'permission-denied') =>
            'The database refused this action. The order is unchanged.',
          StateError(message: final String reason) => reason,
          _ => userFacingError(error, action: '$kind this order'),
        };
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        setState(() => _busy = false);
      }
    }
  }

  Future<String?> _askRejectionRemark() {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          title: const Text('Reject order?'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Rejecting is final. Tell the salesman why so they can fix and resubmit.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 3,
                  maxLength: 500,
                  onChanged: (_) => setLocal(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Rejection remark (required)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB42318),
              ),
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Reject'),
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB42318),
                  )
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  Widget _kv(String label, String value, {required IconData icon}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 200,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class OrderDetailsActions extends StatelessWidget {
  const OrderDetailsActions({
    super.key,
    required this.busy,
    required this.onClose,
    this.onDelete,
    this.onReject,
    this.onApprove,
  });

  final bool busy;
  final VoidCallback onClose;
  final VoidCallback? onDelete;
  final VoidCallback? onReject;
  final VoidCallback? onApprove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool narrow =
              constraints.maxWidth < OrderDetailsHeader.narrowWidth;
          final Size? touchSize = narrow ? const Size(64, 44) : null;
          final Widget? delete = onDelete == null
              ? null
              : TextButton.icon(
                  onPressed: busy ? null : onDelete,
                  style: TextButton.styleFrom(minimumSize: touchSize),
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Color(0xFFB42318),
                  ),
                  label: const Text(
                    'Delete',
                    style: TextStyle(color: Color(0xFFB42318)),
                  ),
                );
          final Widget close = TextButton(
            onPressed: busy ? null : onClose,
            style: TextButton.styleFrom(minimumSize: touchSize),
            child: const Text('Close'),
          );
          final Widget? reject = onReject == null
              ? null
              : OutlinedButton.icon(
                  onPressed: busy ? null : onReject,
                  style: OutlinedButton.styleFrom(minimumSize: touchSize),
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Reject'),
                );
          final Widget? approve = onApprove == null
              ? null
              : FilledButton.icon(
                  onPressed: busy ? null : onApprove,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF27AE60),
                    minimumSize: touchSize,
                  ),
                  icon: const Icon(ScootIcons.success),
                  label: const Text('Approve'),
                );
          if (narrow) {
            return SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 8,
                children: <Widget>[?delete, close, ?reject, ?approve],
              ),
            );
          }
          return Row(
            children: [
              ?delete,
              const Spacer(),
              close,
              if (reject != null) ...[const SizedBox(width: 6), reject],
              if (approve != null) ...[const SizedBox(width: 6), approve],
            ],
          );
        },
      ),
    );
  }
}

class OrderItemsTable extends StatelessWidget {
  const OrderItemsTable({super.key, required this.items});

  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            constraints.maxWidth < OrderDetailsHeader.narrowWidth
            ? _lines(scheme)
            : _table(),
      ),
    );
  }

  Widget _lines(ColorScheme scheme) {
    final TextStyle detail = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < items.length; i++) ...<Widget>[
          if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${i + 1}. ${_lineName(items[i])}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _lineAmount(items[i]),
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
                for (final String line in _lineDetails(items[i]))
                  Text(line, style: detail),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _lineAmount(Map<String, dynamic> item) {
    final int qty = orderLineQuantity(item);
    final String quantity = quantityLabel(qty, uomOf(item));
    if (!itemHasPrice(item)) return '$quantity · Price not recorded';
    final double price = _linePrice(item);
    return '$quantity × ${formatRm(price)} = ${formatRm(qty * price)}';
  }

  static List<String> _lineDetails(Map<String, dynamic> item) {
    final String department = _text(
      item['department'] ?? item['departmentName'],
      fallback: '',
    );
    final String packing = _text(item['packingSize'], fallback: '');
    final String expiry = _text(item['expiry'], fallback: '');
    final String remarks = _text(item['remarks'], fallback: '');
    final String facts = <String>[
      department,
      packing,
      if (expiry.isNotEmpty) 'Expiry $expiry',
    ].where((String part) => part.isNotEmpty).join(' · ');
    return <String>[
      if (facts.isNotEmpty) facts,
      if (remarks.isNotEmpty) 'Remarks: $remarks',
    ];
  }

  Widget _table() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 22,
        columns: const [
          DataColumn(label: Text('#')),
          DataColumn(label: Text('Product')),
          DataColumn(label: Text('Department')),
          DataColumn(label: Text('Packing')),
          DataColumn(label: Text('Qty'), numeric: true),
          DataColumn(label: Text('Price'), numeric: true),
          DataColumn(label: Text('Subtotal'), numeric: true),
          DataColumn(label: Text('Expiry')),
          DataColumn(label: Text('Remarks')),
        ],
        rows: List<DataRow>.generate(items.length, (i) {
          final it = items[i];
          final int qty = orderLineQuantity(it);
          final bool priced = itemHasPrice(it);
          final double price = _linePrice(it);
          return DataRow(
            cells: [
              DataCell(Text('${i + 1}')),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    _lineName(it),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              DataCell(
                Text(
                  _text(
                    it['department'] ?? it['departmentName'],
                    fallback: '—',
                  ),
                ),
              ),
              DataCell(Text(_text(it['packingSize'], fallback: '—'))),
              DataCell(Text(quantityLabel(qty, uomOf(it)))),
              DataCell(Text(priced ? formatRm(price) : 'Price not recorded')),
              DataCell(Text(priced ? formatRm(qty * price) : '—')),
              DataCell(Text(_text(it['expiry'], fallback: '—'))),
              DataCell(Text(_text(it['remarks'], fallback: ''))),
            ],
          );
        }),
      ),
    );
  }

  static String _lineName(Map<String, dynamic> item) => _text(
    item['productName'] ?? item['name'] ?? item['itemName'],
    fallback: '—',
  );

  static double _linePrice(Map<String, dynamic> item) =>
      dataNumberOrNull(item['price']) ??
      dataNumberOrNull(item['unitPrice']) ??
      0.0;
}

class OrderDetailsHeader extends StatelessWidget {
  const OrderDetailsHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.priceCheck,
    required this.onClose,
  });

  final String title;
  final String subtitle;
  final String status;
  final ServerPriceCheck? priceCheck;
  final VoidCallback? onClose;

  static const double narrowWidth = 560;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      ],
    );
    final Widget pill = _orderStatusPill(context, status);
    final Widget badge = ServerPriceCheckBadge(
      check: priceCheck,
      showWhenAbsent: true,
    );
    final Widget close = IconButton(
      tooltip: 'Close',
      icon: const Icon(ScootIcons.close),
      onPressed: onClose,
    );
    const Icon leading = Icon(
      ScootIcons.orders,
      size: 24,
      color: Color(0xFF27AE60),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth >= narrowWidth) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(child: titles),
                pill,
                const SizedBox(width: 8),
                badge,
                close,
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: leading,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: titles),
                  close,
                ],
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [pill, badge]),
            ],
          );
        },
      ),
    );
  }
}

Widget _orderStatusPill(BuildContext context, String status) {
  final s = status.toLowerCase();
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  final (Color bg, Color fg) = switch (s) {
    'approved' =>
      dark
          ? (const Color(0xFF153D2C), const Color(0xFF7EE2A8))
          : (const Color(0xFFD1FADF), const Color(0xFF027A48)),
    'rejected' =>
      dark
          ? (const Color(0xFF4A1F1B), const Color(0xFFFFB4AB))
          : (const Color(0xFFFEE4E2), const Color(0xFFB42318)),
    'pending' =>
      dark
          ? (const Color(0xFF4A3004), const Color(0xFFFFD08A))
          : (const Color(0xFFFEF0C7), const Color(0xFFB54708)),
    _ =>
      dark
          ? (const Color(0xFF143A5F), const Color(0xFFA9CCFF))
          : (const Color(0xFFE0EAFF), const Color(0xFF1849A9)),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      orderStatusLabel(status),
      style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

String _text(Object? v, {required String fallback}) {
  final s = (v ?? '').toString().trim();
  if (s.isEmpty || s == 'null') return fallback;
  return s;
}

String _formatDateTime(Object? value) {
  if (value is Timestamp) {
    final d = value.toDate();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  return _text(value, fallback: '—');
}
