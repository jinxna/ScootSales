import 'package:flutter/material.dart';

import '../app/lifecycle_notice.dart';

class ConsoleNotices extends StatelessWidget {
  const ConsoleNotices({
    super.key,
    required this.state,
    required this.graceEndsAt,
    required this.roleChange,
    required this.onDismissRoleChange,
    required this.child,
    this.isAdmin = false,
  });

  final String? state;
  final DateTime? graceEndsAt;
  final String roleChange;
  final VoidCallback onDismissRoleChange;
  final Widget child;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    final String? pastDue = pastDueNotice(
      state,
      graceEndsAt,
      isAdmin: isAdmin,
    );
    if (pastDue == null && roleChange.isEmpty) return child;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (pastDue != null)
          _notice(
            scheme,
            label: 'Payment overdue',
            icon: Icons.warning_amber_rounded,
            text: pastDue,
          ),
        if (roleChange.isNotEmpty)
          _notice(
            scheme,
            label: 'Role changed',
            icon: Icons.badge_outlined,
            text: roleChange,
            onDismiss: onDismissRoleChange,
          ),
        Expanded(child: child),
      ],
    );
  }

  Widget _notice(
    ColorScheme scheme, {
    required String label,
    required IconData icon,
    required String text,
    VoidCallback? onDismiss,
  }) {
    return Material(
      color: scheme.tertiaryContainer,
      child: Semantics(
        container: true,
        liveRegion: true,
        label: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: <Widget>[
              Icon(icon, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onDismiss != null)
                TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
            ],
          ),
        ),
      ),
    );
  }
}
