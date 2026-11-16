import 'package:flutter/material.dart';

import '../../theme/dso_theme.dart';

Future<void> closeCatalogueDrawer(
  BuildContext context, {
  required bool dirty,
  required VoidCallback onClose,
}) async {
  if (!dirty) {
    onClose();
    return;
  }
  final bool? discard = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Discard changes?'),
      content: const Text('You have unsaved changes in this panel.'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  if (discard == true) onClose();
}

class CatalogueDrawer extends StatelessWidget {
  const CatalogueDrawer({
    super.key,
    required this.title,
    required this.body,
    required this.footer,
    required this.onClose,
    this.dirty = false,
  });

  static const double width = 480;

  final String title;
  final Widget body;
  final List<Widget> footer;
  final VoidCallback onClose;
  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: title,
      child: FocusScope(
        child: Material(
          color: dso.card,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: dso.hairline)),
            ),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: dso.ink,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close (Esc)',
                        onPressed: () => closeCatalogueDrawer(
                          context,
                          dirty: dirty,
                          onClose: onClose,
                        ),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: dso.hairline),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: body,
                  ),
                ),
                Divider(height: 1, color: dso.hairline),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: footer),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
