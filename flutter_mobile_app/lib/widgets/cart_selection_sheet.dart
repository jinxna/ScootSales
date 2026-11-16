import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../utils/salesperson_cart_limits.dart';

Future<bool?> showCartSelectionSheet(
  BuildContext context, {
  required int totalSelected,
  required List<String> added,
  required List<String> removed,
  required List<String> previouslySelected,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CartSelectionSheet(
      totalSelected: totalSelected,
      added: added,
      removed: removed,
      previouslySelected: previouslySelected,
    ),
  );
}

class CartSelectionSheet extends StatefulWidget {
  const CartSelectionSheet({
    super.key,
    required this.totalSelected,
    required this.added,
    required this.removed,
    this.previouslySelected = const <String>[],
  });

  final int totalSelected;
  final List<String> added;
  final List<String> removed;
  final List<String> previouslySelected;

  @override
  State<CartSelectionSheet> createState() => _CartSelectionSheetState();
}

class _CartSelectionSheetState extends State<CartSelectionSheet> {
  bool _showPrevious = false;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final int total = widget.totalSelected;
    final bool hasPrevious = widget.previouslySelected.isNotEmpty;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ScootSpace.phoneGutter,
              0,
              ScootSpace.phoneGutter,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Check your selection',
                  style: ScootType.h2.copyWith(color: c.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  '$total product${total == 1 ? '' : 's'} selected. '
                  'One order holds up to '
                  '${SalespersonCartLimits.maxDistinctItems}. '
                  'Next, count the shelf stock.',
                  style: ScootType.body.copyWith(color: c.text2),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(
                horizontal: ScootSpace.phoneGutter,
              ),
              children: <Widget>[
                if (hasPrevious)
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _showPrevious = !_showPrevious),
                    icon: Icon(
                      _showPrevious
                          ? ScootIcons.expandLess
                          : ScootIcons.expandMore,
                      size: 18,
                    ),
                    label: Text(
                      'Previously selected (${widget.previouslySelected.length})',
                    ),
                  ),
                if (_showPrevious)
                  _Group(
                    title: null,
                    names: widget.previouslySelected,
                    badge: null,
                  ),
                if (widget.added.isNotEmpty)
                  _Group(
                    title: 'Added (${widget.added.length})',
                    names: widget.added,
                    badge: const ScootBadge(
                      label: 'New',
                      tone: ScootTone.success,
                      icon: ScootIcons.add,
                    ),
                  ),
                if (widget.removed.isNotEmpty)
                  _Group(
                    title: 'Removed (${widget.removed.length})',
                    names: widget.removed,
                    badge: const ScootBadge(
                      label: 'Out',
                      tone: ScootTone.danger,
                      icon: ScootIcons.remove,
                    ),
                  ),
                if (widget.added.isEmpty && widget.removed.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: Text(
                      'No changes from previous selection.',
                      style: ScootType.body.copyWith(color: c.text2),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ScootSpace.phoneGutter,
              12,
              ScootSpace.phoneGutter,
              ScootSpace.phoneGutter,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: 2,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(
                        ScootSize.primaryButton,
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(
                        ScootSize.primaryButton,
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Start counting'),
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

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.names, required this.badge});

  static const int shown = 5;

  final String? title;
  final List<String> names;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                title!,
                style: ScootType.smallStrong.copyWith(color: c.text2),
              ),
            ),
          for (final String name in names.take(shown))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ScootType.body.copyWith(color: c.ink),
                    ),
                  ),
                  if (badge != null) ...<Widget>[
                    const SizedBox(width: 8),
                    badge!,
                  ],
                ],
              ),
            ),
          if (names.length > shown)
            Text(
              '+ ${names.length - shown} more',
              style: ScootType.small.copyWith(color: c.muted),
            ),
        ],
      ),
    );
  }
}
