import 'package:flutter/material.dart';

import '../utils/retailer_bulk_assign.dart';
import '../utils/retailer_form_utils.dart';
import 'cms_feedback.dart';
import 'confirm_destructive_dialog.dart';

class RetailerBulkAssignList extends StatefulWidget {
  const RetailerBulkAssignList({
    super.key,
    required this.retailers,
    required this.options,
    required this.writer,
    required this.canEdit,
    required this.isRetired,
    required this.cardBuilder,
    this.padding = const EdgeInsets.fromLTRB(18, 8, 18, 18),
    this.header,
    this.rowGap = 10,
  });

  final List<Map<String, dynamic>> retailers;
  final List<RetailerSalesmanOption> options;
  final RetailerAssignmentWriter writer;
  final bool canEdit;
  final bool Function(Map<String, dynamic>) isRetired;
  final Widget Function(BuildContext context, Map<String, dynamic> retailer)
  cardBuilder;
  final EdgeInsetsGeometry padding;

  final Widget? header;
  final double rowGap;

  @override
  State<RetailerBulkAssignList> createState() => _RetailerBulkAssignListState();
}

class _RetailerBulkAssignListState extends State<RetailerBulkAssignList> {
  Set<String> _selected = <String>{};
  bool _busy = false;
  int _done = 0;
  int _total = 0;

  String _idOf(Map<String, dynamic> retailer) =>
      '${retailer['docId'] ?? retailer['retailerId'] ?? ''}'.trim();

  List<Map<String, dynamic>> get _selectedRows => widget.retailers
      .where((Map<String, dynamic> r) => _selected.contains(_idOf(r)))
      .toList(growable: false);

  @override
  void didUpdateWidget(RetailerBulkAssignList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Set<String> visible = widget.retailers.map(_idOf).toSet();
    final Set<String> pruned = _selected.where(visible.contains).toSet();
    if (pruned.length != _selected.length) _selected = pruned;
  }

  void _toggle(String id, bool selected) {
    setState(() {
      _selected = <String>{..._selected};
      selected ? _selected.add(id) : _selected.remove(id);
    });
  }

  void _toggleAll(bool selected) {
    setState(() {
      _selected = selected
          ? widget.retailers
                .map(_idOf)
                .where((String id) => id.isNotEmpty)
                .toSet()
          : <String>{};
    });
  }

  Future<void> _assign() async {
    if (_busy || _selected.isEmpty) return;
    final RetailerSalesmanOption? target =
        await showDialog<RetailerSalesmanOption>(
          context: context,
          builder: (BuildContext context) =>
              _SalesmanPickerDialog(options: widget.options),
        );
    if (target == null || !mounted) return;
    final BulkAssignPlan plan = planBulkAssignment(
      retailers: _selectedRows,
      target: target,
      isRetired: widget.isRetired,
    );
    if (plan.ids.isEmpty) {
      showCmsToast(
        context,
        plan.unchanged > 0
            ? 'Everything selected is already assigned to ${target.label}.'
            : 'Nothing to assign: the selected retailers are retired.',
      );
      return;
    }
    final String count = _plural(plan.ids.length);
    final StringBuffer message = StringBuffer(
      'Assign $count to ${target.label}?',
    );
    if (plan.changingOwner > 0) {
      message.write(
        ' ${plan.changingOwner} ${plan.changingOwner == 1 ? 'is' : 'are'} '
        'currently assigned to someone else.',
      );
    }
    if (plan.unchanged > 0) {
      message.write(' ${plan.unchanged} already assigned will be left as is.');
    }
    if (plan.skippedRetired.isNotEmpty) {
      message.write(' ${plan.skippedRetired.length} retired will be skipped.');
    }
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Assign retailers',
      message: message.toString(),
      confirmLabel: 'Assign',
    );
    if (!confirmed || !mounted) return;
    await _run(plan, target.storageValue, 'Assigned', target.label);
  }

  Future<void> _unassign() async {
    if (_busy || _selected.isEmpty) return;
    final BulkAssignPlan plan = planBulkAssignment(
      retailers: _selectedRows,
      target: null,
      isRetired: widget.isRetired,
    );
    if (plan.ids.isEmpty) {
      showCmsToast(context, 'None of the selected retailers is assigned.');
      return;
    }
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Unassign retailers',
      message:
          'Remove the salesman from ${_plural(plan.ids.length)}? They will '
          'show as Not assigned.',
      confirmLabel: 'Unassign',
    );
    if (!confirmed || !mounted) return;
    await _run(plan, '', 'Unassigned', null);
  }

  Future<void> _run(
    BulkAssignPlan plan,
    String salesmanId,
    String verb,
    String? targetLabel,
  ) async {
    setState(() {
      _busy = true;
      _done = 0;
      _total = plan.ids.length;
    });
    Map<String, Object> failed;
    try {
      failed = await widget.writer.setAssignment(
        plan.ids,
        salesmanId,
        onProgress: (int done) {
          if (mounted) setState(() => _done = done);
        },
      );
    } catch (error) {
      failed = <String, Object>{for (final String id in plan.ids) id: error};
    }
    if (!mounted) return;
    final int ok = plan.ids.length - failed.length;
    setState(() {
      _busy = false;
      _selected = failed.keys.toSet();
    });
    if (failed.isEmpty) {
      showCmsToast(
        context,
        targetLabel == null
            ? '$verb ${_plural(ok)}.'
            : '$verb ${_plural(ok)} to $targetLabel.',
      );
      return;
    }
    final Map<String, String> names = <String, String>{
      for (final Map<String, dynamic> r in widget.retailers)
        _idOf(r): '${r['retailerName'] ?? r['name'] ?? _idOf(r)}',
    };
    final int definiteFailureCount = failed.values
        .where(isDefiniteRetailerAssignmentFailure)
        .length;
    final int unconfirmedCount = failed.length - definiteFailureCount;
    final List<String> report = <String>[
      '$verb $ok of ${plan.ids.length} retailers',
      if (definiteFailureCount > 0) '$definiteFailureCount failed',
      if (unconfirmedCount > 0)
        '$unconfirmedCount could not be confirmed. Refresh before retrying.',
    ];
    final String reportText = report.join('; ');
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: Theme.of(context).colorScheme.error,
        content: Text(reportText.endsWith('.') ? reportText : '$reportText.'),
        action: SnackBarAction(
          label: 'View failures',
          textColor: Colors.white,
          onPressed: () => _showFailureDetails(
            failed,
            names,
            hasUnconfirmed: unconfirmedCount > 0,
          ),
        ),
      ),
    );
  }

  void _showFailureDetails(
    Map<String, Object> failed,
    Map<String, String> names, {
    required bool hasUnconfirmed,
  }) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          hasUnconfirmed
              ? 'Retailer results needing attention'
              : '${failed.length} retailer failures',
        ),
        content: SizedBox(
          width: 480,
          height: 360,
          child: ListView.separated(
            itemCount: failed.length,
            separatorBuilder: (BuildContext context, int index) =>
                const Divider(height: 20),
            itemBuilder: (BuildContext context, int index) {
              final String id = failed.keys.elementAt(index);
              final String name = names[id] ?? id;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(retailerAssignmentFailureReason(name, failed[id]!)),
                ],
              );
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _plural(int n) => '$n ${n == 1 ? 'retailer' : 'retailers'}';

  @override
  Widget build(BuildContext context) {
    final Widget gap = SizedBox(height: widget.rowGap);
    if (!widget.canEdit) {
      return Column(
        children: <Widget>[
          if (widget.header != null)
            Padding(
              padding: EdgeInsets.only(
                left: widget.padding.resolve(TextDirection.ltr).left,
                right: widget.padding.resolve(TextDirection.ltr).right,
              ),
              child: widget.header,
            ),
          Expanded(
            child: ListView.separated(
              padding: widget.padding,
              itemCount: widget.retailers.length,
              separatorBuilder: (_, _) => gap,
              itemBuilder: (BuildContext context, int index) =>
                  widget.cardBuilder(context, widget.retailers[index]),
            ),
          ),
        ],
      );
    }
    final int visibleCount = widget.retailers.length;
    final bool all = visibleCount > 0 && _selected.length >= visibleCount;
    final bool some = _selected.isNotEmpty && !all;
    final Widget selectAll = Tooltip(
      message: 'Select all ($visibleCount)',
      child: Checkbox(
        key: const ValueKey<String>('retailer-select-all'),
        tristate: true,
        value: all ? true : (some ? null : false),
        onChanged: _busy ? null : (bool? v) => _toggleAll(v == true),
      ),
    );
    return Column(
      children: <Widget>[
        Padding(
          padding: widget.header == null
              ? const EdgeInsets.fromLTRB(10, 0, 12, 0)
              : EdgeInsets.only(
                  left: widget.padding.resolve(TextDirection.ltr).left,
                  right: widget.padding.resolve(TextDirection.ltr).right,
                ),
          child: Row(
            children: <Widget>[
              selectAll,
              if (widget.header != null)
                Expanded(child: widget.header!)
              else
                Text('Select all ($visibleCount)'),
            ],
          ),
        ),
        if (_selected.isNotEmpty) _selectionBar(context),
        Expanded(
          child: ListView.separated(
            padding: widget.padding,
            itemCount: widget.retailers.length,
            separatorBuilder: (_, _) => gap,
            itemBuilder: (BuildContext context, int index) {
              final Map<String, dynamic> retailer = widget.retailers[index];
              final String id = _idOf(retailer);
              return Row(
                children: <Widget>[
                  Checkbox(
                    key: ValueKey<String>('retailer-select-$id'),
                    value: _selected.contains(id),
                    onChanged: _busy
                        ? null
                        : (bool? v) => _toggle(id, v == true),
                  ),
                  Expanded(child: widget.cardBuilder(context, retailer)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _selectionBar(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 4, 18, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            '${_selected.length} selected',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const Text('·'),
          FilledButton.tonal(
            key: const ValueKey<String>('retailer-bulk-assign'),
            onPressed: _busy ? null : _assign,
            child: const Text('Assign to…'),
          ),
          OutlinedButton(
            key: const ValueKey<String>('retailer-bulk-unassign'),
            onPressed: _busy ? null : _unassign,
            child: const Text('Unassign'),
          ),
          TextButton(
            key: const ValueKey<String>('retailer-bulk-clear'),
            onPressed: _busy ? null : () => _toggleAll(false),
            child: const Text('Clear'),
          ),
          if (_busy) ...<Widget>[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Text('Updating $_done of $_total…'),
          ],
        ],
      ),
    );
  }
}

class _SalesmanPickerDialog extends StatefulWidget {
  const _SalesmanPickerDialog({required this.options});

  final List<RetailerSalesmanOption> options;

  @override
  State<_SalesmanPickerDialog> createState() => _SalesmanPickerDialogState();
}

class _SalesmanPickerDialogState extends State<_SalesmanPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final String q = _query.trim().toLowerCase();
    final List<RetailerSalesmanOption> shown = widget.options
        .where(
          (RetailerSalesmanOption o) =>
              q.isEmpty || o.label.toLowerCase().contains(q),
        )
        .toList(growable: false);
    return AlertDialog(
      title: const Text('Assign to salesman'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: <Widget>[
            if (widget.options.length > 6)
              TextField(
                key: const ValueKey<String>('salesman-search'),
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search salesmen',
                ),
                onChanged: (String v) => setState(() => _query = v),
              ),
            Expanded(
              child: widget.options.isEmpty
                  ? const Center(child: Text('No salesmen found.'))
                  : shown.isEmpty
                  ? const Center(child: Text('No match.'))
                  : ListView(
                      children: <Widget>[
                        for (final RetailerSalesmanOption option in shown)
                          ListTile(
                            key: ValueKey<String>('salesman-${option.value}'),
                            title: Text(option.label),
                            onTap: () => Navigator.of(context).pop(option),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
