import 'package:flutter/material.dart';

import '../common/focus_ring.dart';
import '../common/pressable.dart';
import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';

enum ScootCopilotStatus { ready, wakingUp, offline }

class ScootAccount {
  const ScootAccount({
    required this.name,
    required this.subtitle,
    this.initial,
  });

  final String name;
  final String subtitle;
  final String? initial;

  String get avatarText {
    final String value = initial ?? name.trim();
    return value.isEmpty ? '?' : value.characters.first.toUpperCase();
  }
}

class ScootMenuAction {
  const ScootMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

class ScootTopBar extends StatelessWidget {
  const ScootTopBar({
    super.key,
    required this.onSearch,
    required this.scopeLabel,
    required this.account,
    required this.accountActions,
    this.searchHint = 'Jump to a page or order ID',
    this.copilotStatus,
    this.onCopilot,
    this.onHelp,
  });

  final VoidCallback onSearch;
  final String searchHint;
  final String scopeLabel;
  final ScootCopilotStatus? copilotStatus;
  final VoidCallback? onCopilot;
  final VoidCallback? onHelp;
  final ScootAccount account;
  final List<ScootMenuAction> accountActions;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      height: ScootSize.topBar,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: c.card,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ScootSize.searchMaxWidth,
                ),
                child: ScootSearchField(hint: searchHint, onTap: onSearch),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ScootScopePill(label: scopeLabel),
          if (copilotStatus != null && onCopilot != null) ...<Widget>[
            const SizedBox(width: 10),
            ScootCopilotButton(status: copilotStatus!, onPressed: onCopilot!),
          ],
          if (onHelp != null) ...<Widget>[
            const SizedBox(width: 6),
            ScootFocusRing(
              child: IconButton(
                onPressed: onHelp,
                tooltip: 'Help and keyboard shortcuts',
                icon: const Icon(ScootIcons.help),
              ),
            ),
          ],
          const SizedBox(width: 6),
          ScootAccountButton(account: account, actions: accountActions),
        ],
      ),
    );
  }
}

class ScootSearchField extends StatelessWidget {
  const ScootSearchField({super.key, required this.hint, required this.onTap});

  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return ScootPressable(
      onTap: onTap,
      minSize: const Size(220, ScootSize.control),
      semanticLabel: '$hint. Shortcut Control K',
      color: c.searchFill,
      hoverColor: c.hair,
      child: Container(
        height: ScootSize.control,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: c.line2),
          borderRadius: ScootRadius.controlAll,
        ),
        child: Row(
          children: <Widget>[
            Icon(ScootIcons.search, size: ScootSize.icon, color: c.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ScootType.body.copyWith(color: c.muted),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: c.card,
                border: Border.all(color: c.line2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Ctrl K',
                style: ScootType.caption.copyWith(color: c.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScootScopePill extends StatelessWidget {
  const ScootScopePill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      label: 'Scope: $label',
      excludeSemantics: true,
      child: Container(
        height: ScootSize.scopePill,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.brandTint,
          border: Border.all(color: c.brandTintBorder),
          borderRadius: ScootRadius.pillAll,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(ScootIcons.branch, size: 16, color: c.brandText),
            const SizedBox(width: 6),
            Text(
              label,
              style: ScootType.smallStrong.copyWith(color: c.brandText),
            ),
          ],
        ),
      ),
    );
  }
}

class ScootCopilotButton extends StatelessWidget {
  const ScootCopilotButton({
    super.key,
    required this.status,
    required this.onPressed,
  });

  final ScootCopilotStatus status;
  final VoidCallback onPressed;

  static String statusWord(ScootCopilotStatus status) {
    switch (status) {
      case ScootCopilotStatus.ready:
        return 'Ready';
      case ScootCopilotStatus.wakingUp:
        return 'Waking up';
      case ScootCopilotStatus.offline:
        return 'Offline';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Color dot;
    switch (status) {
      case ScootCopilotStatus.ready:
        dot = c.brand;
      case ScootCopilotStatus.wakingUp:
        dot = ScootPalette.countBg;
      case ScootCopilotStatus.offline:
        dot = c.danger.foreground;
    }
    final String word = statusWord(status);
    return Semantics(
      button: true,
      label: 'Scout, $word',
      excludeSemantics: true,
      child: OutlinedButton(
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(ScootIcons.copilot, size: 18, color: c.text2),
            const SizedBox(width: 8),
            const Text('Scout'),
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(word, style: ScootType.caption.copyWith(color: c.muted)),
          ],
        ),
      ),
    );
  }
}

class ScootAccountButton extends StatelessWidget {
  const ScootAccountButton({
    super.key,
    required this.account,
    required this.actions,
  });

  final ScootAccount account;
  final List<ScootMenuAction> actions;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      menuChildren: <Widget>[
        for (final ScootMenuAction action in actions)
          MenuItemButton(
            leadingIcon: Icon(action.icon, size: 18),
            onPressed: action.onSelected,
            child: Text(action.label),
          ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return ScootPressable(
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          minSize: const Size(0, 44),
          borderRadius: ScootRadius.pillAll,
          color: c.card,
          hoverColor: c.hair,
          semanticLabel: 'Account menu, ${account.name}, ${account.subtitle}',
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
            decoration: BoxDecoration(
              border: Border.all(color: c.line),
              borderRadius: ScootRadius.pillAll,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: ScootSize.avatar,
                  height: ScootSize.avatar,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.brand,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    account.avatarText,
                    style: ScootType.bodyStrong.copyWith(color: c.onBrand),
                  ),
                ),
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        account.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ScootType.bodyStrong.copyWith(
                          color: c.ink,
                          height: 1.25,
                        ),
                      ),
                      Text(
                        account.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ScootType.caption.copyWith(
                          color: c.muted,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(ScootIcons.expandMore, size: 18, color: c.muted),
              ],
            ),
          ),
        );
      },
    );
  }
}
