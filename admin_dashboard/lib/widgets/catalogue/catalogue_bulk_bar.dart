import 'package:flutter/material.dart';

import '../../theme/dso_theme.dart';

class CatalogueBulkAction {
  const CatalogueBulkAction({
    required this.label,
    required this.run,
    this.destructive = false,
    this.confirmText,
  });

  final String label;
  final Future<void> Function() run;
  final bool destructive;

  final String? confirmText;
}

class CatalogueBulkBar extends StatelessWidget {
  const CatalogueBulkBar({
    super.key,
    required this.selectedCount,
    required this.actions,
    required this.onClear,
    this.busy = false,
  });

  final int selectedCount;
  final List<CatalogueBulkAction> actions;
  final VoidCallback onClear;
  final bool busy;

  Future<void> _press(BuildContext context, CatalogueBulkAction action) async {
    if (action.confirmText != null) {
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text(action.label),
          content: Text(action.confirmText!),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(action.label),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await action.run();
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      decoration: BoxDecoration(
        color: dso.brandSurface,
        borderRadius: BorderRadius.circular(DsoTokens.rMd),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: <Widget>[
                Semantics(
                  container: true,
                  excludeSemantics: true,
                  label: '$selectedCount selected',
                  child: Text(
                    '$selectedCount selected',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: dso.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                for (final CatalogueBulkAction action in actions)
                  TextButton(
                    onPressed: busy ? null : () => _press(context, action),
                    style: action.destructive
                        ? TextButton.styleFrom(foregroundColor: dso.dangerText)
                        : null,
                    child: Text(action.label),
                  ),
                TextButton(
                  onPressed: busy ? null : onClear,
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}
