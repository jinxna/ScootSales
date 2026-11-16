import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../widgets/filter_chip.dart';

enum SpecialRequestTab { open, finalised, all }

String specialRequestText(Object? value) {
  if (value == null) return '';
  final String text = value.toString().trim();
  return text.toLowerCase() == 'null' ? '' : text;
}

bool specialRequestAwaitsCatalogue(Map<String, dynamic> row) =>
    specialRequestText(row['requestType']) == 'non_catalogue_item' &&
    specialRequestText(row['status']) == 'approved' &&
    specialRequestText(row['catalogueProductId']).isEmpty;

bool specialRequestIsFinalised(Map<String, dynamic> row) {
  final String status = specialRequestText(row['status']).toLowerCase();
  return (status == 'approved' && !specialRequestAwaitsCatalogue(row)) ||
      status == 'rejected';
}

String specialRequestStatusLabel(Map<String, dynamic> row) {
  final String status = specialRequestText(row['status']).toLowerCase();
  switch (status) {
    case 'approved':
      return specialRequestAwaitsCatalogue(row)
          ? 'Approved, not in catalogue yet'
          : 'Approved';
    case 'rejected':
      return 'Rejected';
    case 'pending_supervisor':
      return 'Waiting for supervisor';
    case 'pending_branch_manager':
      return 'Waiting for branch manager';
    case 'pending_admin':
      return 'Waiting for admin';
    default:
      final String step = specialRequestText(row['approvalStep']);
      return step.isEmpty ? 'Waiting' : 'Waiting for ${step.toLowerCase()}';
  }
}

ScootTone specialRequestTone(Map<String, dynamic> row) {
  switch (specialRequestText(row['status']).toLowerCase()) {
    case 'approved':
      return specialRequestAwaitsCatalogue(row)
          ? ScootTone.warning
          : ScootTone.success;
    case 'rejected':
      return ScootTone.danger;
    default:
      return ScootTone.info;
  }
}

String specialRequestTime(Object? value, {DateTime? now}) {
  if (value is! Timestamp) return '';
  final DateTime kl = value.toDate().toUtc().add(const Duration(hours: 8));
  final DateTime today = (now ?? DateTime.now().toUtc()).toUtc().add(
    const Duration(hours: 8),
  );
  final String clock =
      '${kl.hour.toString().padLeft(2, '0')}:${kl.minute.toString().padLeft(2, '0')}';
  if (kl.year == today.year && kl.month == today.month && kl.day == today.day) {
    return 'Today $clock';
  }
  const List<String> months = <String>[
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
  return '${kl.day} ${months[kl.month - 1]} ${kl.year}, $clock';
}

class SpecialRequestsView extends StatefulWidget {
  const SpecialRequestsView({
    super.key,
    required this.phase,
    required this.onRetry,
    required this.rows,
    required this.isBranchManager,
    required this.isAdmin,
    required this.canDecide,
    required this.isLegacy,
    required this.busyIds,
    required this.onNewRequest,
    required this.onApprove,
    required this.onReject,
    required this.onAddToCatalogue,
    required this.onUpgradeLegacy,
    required this.onOpenOrder,
    this.pageSize = ScootPaging.pageSize,
  });

  final ScootLoadPhase phase;
  final VoidCallback onRetry;
  final List<Map<String, dynamic>> rows;
  final bool isBranchManager;
  final bool isAdmin;
  final bool Function(Map<String, dynamic> row) canDecide;
  final bool Function(Map<String, dynamic> row) isLegacy;
  final Set<String> busyIds;
  final VoidCallback onNewRequest;
  final ValueChanged<Map<String, dynamic>> onApprove;
  final ValueChanged<Map<String, dynamic>> onReject;
  final ValueChanged<Map<String, dynamic>> onAddToCatalogue;
  final ValueChanged<Map<String, dynamic>> onUpgradeLegacy;
  final ValueChanged<String> onOpenOrder;
  final int pageSize;

  @override
  State<SpecialRequestsView> createState() => _SpecialRequestsViewState();
}

class _SpecialRequestsViewState extends State<SpecialRequestsView> {
  SpecialRequestTab _tab = SpecialRequestTab.open;
  String _selectedId = '';
  int _pagesLoaded = 1;

  List<Map<String, dynamic>> get _filtered {
    switch (_tab) {
      case SpecialRequestTab.all:
        return widget.rows;
      case SpecialRequestTab.open:
        return widget.rows
            .where(
              (Map<String, dynamic> row) => !specialRequestIsFinalised(row),
            )
            .toList(growable: false);
      case SpecialRequestTab.finalised:
        return widget.rows
            .where(specialRequestIsFinalised)
            .toList(growable: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final int openCount = widget.rows
        .where((Map<String, dynamic> row) => !specialRequestIsFinalised(row))
        .length;
    return Padding(
      padding: const EdgeInsets.all(ScootSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ScootPageHeader(
            title: 'Special Requests',
            fact: widget.phase == ScootLoadPhase.ready
                ? '$openCount open request${openCount == 1 ? '' : 's'}'
                : null,
            actions: <Widget>[
              if (!widget.isBranchManager)
                FilledButton.icon(
                  key: const ValueKey<String>('sr-new'),
                  onPressed: widget.onNewRequest,
                  icon: const Icon(ScootIcons.add, size: 18),
                  label: const Text('New request'),
                ),
            ],
          ),
          if (widget.isBranchManager) ...<Widget>[
            const SizedBox(height: 12),
            ScootNotice.readOnly(
              message: 'View only. Supervisors and admins decide requests.',
            ),
          ],
          const SizedBox(height: ScootSpace.md),
          Expanded(child: _body(context, openCount)),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, Widget child) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: child,
    );
  }

  Widget _body(BuildContext context, int openCount) {
    switch (widget.phase) {
      case ScootLoadPhase.loading:
        return _card(
          context,
          SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(ScootSpace.lg),
            child: ScootLoadingState(
              onRetry: widget.onRetry,
              semanticLabel: 'Loading special requests',
              skeleton: Column(
                children: <Widget>[
                  for (int i = 0; i < 5; i++)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: ScootSkeleton(height: 64, radius: 10),
                    ),
                ],
              ),
            ),
          ),
        );
      case ScootLoadPhase.error:
        return _card(
          context,
          Center(
            child: ScootErrorState(
              title: 'Special requests could not be loaded',
              message: 'Check your connection and access, then try again.',
              onRetry: widget.onRetry,
            ),
          ),
        );
      case ScootLoadPhase.ready:
        break;
    }
    final List<Map<String, dynamic>> filtered = _filtered;
    final int limit = widget.pageSize * _pagesLoaded;
    final List<Map<String, dynamic>> shown = filtered.length > limit
        ? filtered.sublist(0, limit)
        : filtered;
    Map<String, dynamic>? selected;
    for (final Map<String, dynamic> row in filtered) {
      if (specialRequestText(row['docId']) == _selectedId) selected = row;
    }
    selected ??= filtered.isEmpty ? null : filtered.first;
    final Widget queue = _queue(context, openCount, filtered, shown, selected);
    final Widget detail = _card(
      context,
      selected == null
          ? const Center(
              child: ScootEmptyState(
                title: 'No request selected',
                message: 'Pick a request on the left.',
                icon: ScootIcons.specialRequests,
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(ScootSpace.xl),
              child: _detail(context, selected),
            ),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if (box.maxWidth >= 900) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(width: 400, child: queue),
              const SizedBox(width: 16),
              Expanded(child: detail),
            ],
          );
        }
        return ListView(
          children: <Widget>[
            SizedBox(height: 420, child: queue),
            const SizedBox(height: 16),
            SizedBox(height: 520, child: detail),
          ],
        );
      },
    );
  }

  Widget _queue(
    BuildContext context,
    int openCount,
    List<Map<String, dynamic>> filtered,
    List<Map<String, dynamic>> shown,
    Map<String, dynamic>? selected,
  ) {
    final ScootColors c = ScootColors.of(context);
    return _card(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                PageFilterChip(
                  key: const ValueKey<String>('sr-tab-open'),
                  label: 'Open',
                  count: openCount,
                  selected: _tab == SpecialRequestTab.open,
                  onTap: () => setState(() {
                    _tab = SpecialRequestTab.open;
                    _pagesLoaded = 1;
                  }),
                ),
                PageFilterChip(
                  key: const ValueKey<String>('sr-tab-finalised'),
                  label: 'Finalised',
                  selected: _tab == SpecialRequestTab.finalised,
                  onTap: () => setState(() {
                    _tab = SpecialRequestTab.finalised;
                    _pagesLoaded = 1;
                  }),
                ),
                PageFilterChip(
                  key: const ValueKey<String>('sr-tab-all'),
                  label: 'All',
                  selected: _tab == SpecialRequestTab.all,
                  onTap: () => setState(() {
                    _tab = SpecialRequestTab.all;
                    _pagesLoaded = 1;
                  }),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.hair),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: ScootEmptyState(
                      icon: ScootIcons.specialRequests,
                      title: switch (_tab) {
                        SpecialRequestTab.open => 'No open requests',
                        SpecialRequestTab.finalised =>
                          'No approved or rejected requests yet',
                        SpecialRequestTab.all => 'No special requests yet',
                      },
                      message: widget.isBranchManager
                          ? 'Requests from your branch appear here.'
                          : 'Requests from the phone appear here. Use New request to add one.',
                    ),
                  )
                : ListView.builder(
                    itemCount:
                        shown.length + (shown.length < filtered.length ? 1 : 0),
                    itemBuilder: (BuildContext context, int index) {
                      if (index == shown.length) {
                        return Padding(
                          padding: const EdgeInsets.all(12),
                          child: OutlinedButton(
                            key: const ValueKey<String>('sr-load-more'),
                            onPressed: () => setState(() => _pagesLoaded++),
                            child: Text('Load ${widget.pageSize} more'),
                          ),
                        );
                      }
                      return _queueRow(context, shown[index], selected);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _queueRow(
    BuildContext context,
    Map<String, dynamic> row,
    Map<String, dynamic>? selected,
  ) {
    final ScootColors c = ScootColors.of(context);
    final String id = specialRequestText(row['docId']);
    final bool isSelected =
        selected != null && specialRequestText(selected['docId']) == id;
    final String who = [
      specialRequestText(row['retailerName']),
      specialRequestText(row['salesmanName']).isNotEmpty
          ? specialRequestText(row['salesmanName'])
          : specialRequestText(row['salesmanCode']),
    ].where((String part) => part.isNotEmpty).join(' · ');
    return Semantics(
      button: true,
      selected: isSelected,
      label:
          '${specialRequestText(row['requestedItem'])}, ${specialRequestStatusLabel(row)}',
      excludeSemantics: true,
      child: Material(
        color: isSelected ? c.brandTint : c.card,
        child: InkWell(
          onTap: () => setState(() => _selectedId = id),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: c.hair),
                left: BorderSide(
                  color: isSelected ? c.brand : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ScootLongText(
                  specialRequestText(row['requestedItem']),
                  maxLines: 1,
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
                ScootLongText(
                  who,
                  maxLines: 1,
                  style: ScootType.small.copyWith(color: c.muted),
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    Flexible(
                      child: ScootBadge(
                        label: specialRequestStatusLabel(row),
                        tone: specialRequestTone(row),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      specialRequestTime(row['createdAt']),
                      style: ScootType.small.copyWith(color: c.muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fact(ScootColors c, String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(label, style: ScootType.small.copyWith(color: c.muted)),
          ),
          Expanded(child: value),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, Map<String, dynamic> row) {
    final ScootColors c = ScootColors.of(context);
    final String docId = specialRequestText(row['docId']);
    final String statusLower = specialRequestText(row['status']).toLowerCase();
    final bool finalised =
        statusLower == 'approved' || statusLower == 'rejected';
    final bool legacy = widget.isLegacy(row);
    final bool canDecide = !finalised && widget.canDecide(row);
    final bool busy = widget.busyIds.contains(docId);
    final bool isOther =
        specialRequestText(row['requestType']) == 'non_catalogue_item';
    final bool needsProduct =
        isOther &&
        specialRequestText(row['selectedProductId']).isEmpty &&
        specialRequestText(row['catalogueProductId']).isEmpty;
    final String code = specialRequestText(row['salesmanCode']);
    final String name = specialRequestText(row['salesmanName']);
    final String orderId = specialRequestText(row['orderId']);
    final String role = specialRequestText(row['createdByRole']).toLowerCase();
    final String time = specialRequestTime(row['createdAt']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: ScootLongText(
                specialRequestText(row['requestedItem']),
                style: ScootType.h2.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(width: 12),
            ScootBadge(
              label: specialRequestStatusLabel(row),
              tone: specialRequestTone(row),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _fact(
          c,
          'Retailer',
          ScootLongText(
            specialRequestText(row['retailerName']),
            style: ScootType.body.copyWith(color: c.ink),
          ),
        ),
        _fact(
          c,
          'Salesperson',
          Text(
            name.isEmpty ? (code.isEmpty ? '-' : code) : '$name ($code)',
            style: ScootType.body.copyWith(color: c.ink),
          ),
        ),
        if (orderId.isNotEmpty)
          _fact(
            c,
            'Order',
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey<String>('sr-order-link'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 24),
                ),
                onPressed: () => widget.onOpenOrder(orderId),
                child: Text(orderId),
              ),
            ),
          ),
        if (time.isNotEmpty)
          _fact(
            c,
            'Requested',
            Text(
              role == 'salesman' || role.contains('sales')
                  ? '$time · from the phone'
                  : time,
              style: ScootType.body.copyWith(color: c.ink),
            ),
          ),
        if (specialRequestText(row['reason']).isNotEmpty)
          _fact(
            c,
            'Reason',
            ScootLongText(
              specialRequestText(row['reason']),
              maxLines: 6,
              style: ScootType.body.copyWith(color: c.ink),
            ),
          ),
        if (legacy) ...<Widget>[
          const SizedBox(height: 4),
          const ScootNotice(
            tone: ScootTone.warning,
            title: 'Legacy record',
            message: 'Assign its salesman and branch before approval.',
          ),
        ],
        if (needsProduct && !finalised) ...<Widget>[
          const SizedBox(height: 4),
          const ScootNotice(
            key: ValueKey<String>('sr-other-item-warning'),
            tone: ScootTone.warning,
            message:
                'This item is not in the catalogue. Approving adds it as a text-only product at RM 0.00. Set its price in Products before anyone orders it.',
          ),
        ],
        if (!finalised && !legacy && !widget.isBranchManager) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            _whoCanDecide(statusLower, code),
            key: const ValueKey<String>('sr-who-decides'),
            style: ScootType.small.copyWith(color: c.muted),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            if (legacy && widget.isAdmin && !finalised)
              OutlinedButton(
                onPressed: () => widget.onUpgradeLegacy(row),
                child: const Text('Upgrade legacy record'),
              ),
            if (canDecide)
              FilledButton(
                key: const ValueKey<String>('sr-approve'),
                onPressed: busy ? null : () => widget.onApprove(row),
                child: Text(
                  widget.isAdmin && isOther
                      ? 'Approve and add to catalogue'
                      : 'Approve',
                ),
              ),
            if (widget.isAdmin && specialRequestAwaitsCatalogue(row))
              FilledButton(
                onPressed: busy ? null : () => widget.onAddToCatalogue(row),
                child: const Text('Add to catalogue'),
              ),
            if (canDecide)
              OutlinedButton(
                key: const ValueKey<String>('sr-reject'),
                onPressed: busy ? null : () => widget.onReject(row),
                child: const Text('Reject'),
              ),
          ],
        ),
      ],
    );
  }

  String _whoCanDecide(String status, String code) {
    if (status == 'pending_supervisor') {
      return widget.isAdmin
          ? 'You are an admin, so you can decide now. The supervisor of $code can also decide.'
          : 'Only the supervisor of $code or an admin can decide.';
    }
    if (status == 'pending_admin' || status == 'pending_branch_manager') {
      return widget.isAdmin
          ? 'You are an admin, so you can decide now.'
          : 'Only an admin can decide this request.';
    }
    return '';
  }
}
