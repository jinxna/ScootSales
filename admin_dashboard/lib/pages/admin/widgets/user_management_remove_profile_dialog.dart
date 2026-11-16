import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:flutter/services.dart';

enum UserManagementRemoveProfileChoice { remove, suspend }

class UserManagementRemoveProfileDialog extends StatefulWidget {
  const UserManagementRemoveProfileDialog({
    super.key,
    required this.name,
    required this.confirmText,
    required this.canSuspend,
    required this.linkedSalesmen,
  });

  final String name;
  final String confirmText;
  final bool canSuspend;
  final int linkedSalesmen;

  @override
  State<UserManagementRemoveProfileDialog> createState() =>
      UserManagementRemoveProfileDialogState();
}

class UserManagementRemoveProfileDialogState
    extends State<UserManagementRemoveProfileDialog> {
  final TextEditingController _controller = TextEditingController();

  bool get _matches =>
      widget.confirmText.isNotEmpty &&
      _controller.text.trim() == widget.confirmText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_matches) {
      Navigator.of(context).pop(UserManagementRemoveProfileChoice.remove);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int n = widget.linkedSalesmen;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Semantics(
                    label: 'Warning',
                    child: CircleAvatar(
                      radius: 26,
                      backgroundColor: scheme.errorContainer,
                      child: Icon(
                        ScootIcons.remove,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Remove ${widget.name}?',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Deletes ${widget.name}'s dashboard profile and access "
                    'entry. Orders, routes, visits and audit records are kept. '
                    'Their sign-in account is not deleted.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (n > 0) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      '$n ${n == 1 ? 'salesman is' : 'salesmen are'} still '
                      'assigned to this supervisor. Reassign them first, '
                      'otherwise they will point at a missing supervisor.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Type ${widget.confirmText} to confirm',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: widget.confirmText,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  if (widget.canSuspend) ...<Widget>[
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Icon(ScootIcons.info, size: 16, color: scheme.error),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Consider suspending this user if you only need '
                            'to remove their access',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.error,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(
                            context,
                          ).pop(UserManagementRemoveProfileChoice.suspend),
                          child: const Text('Suspend instead'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.error,
                            foregroundColor: scheme.onError,
                          ),
                          onPressed: _matches ? _submit : null,
                          child: const Text('Delete'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
