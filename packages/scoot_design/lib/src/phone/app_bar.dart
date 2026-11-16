import 'package:flutter/material.dart';

import '../common/badges.dart';
import '../common/focus_ring.dart';
import '../common/pressable.dart';
import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';

class ScootPhoneAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ScootPhoneAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(ScootSize.phoneAppBar);

  @override
  Widget build(BuildContext context) {
    assert(actions.length <= 2, 'The phone app bar has at most 2 actions.');
    final ScootColors c = ScootColors.of(context);
    final bool subpage = onBack != null;
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      decoration: BoxDecoration(
        color: c.card,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: SizedBox(
        height: ScootSize.phoneAppBar - 1,
        child: Row(
          children: <Widget>[
            if (subpage) ...<Widget>[
              const SizedBox(width: 4),
              ScootFocusRing(
                child: IconButton(
                  onPressed: onBack,
                  tooltip: 'Back',
                  icon: Icon(ScootIcons.back, color: c.ink),
                ),
              ),
              const SizedBox(width: 4),
            ] else
              const SizedBox(width: ScootSpace.phoneGutter),
            Expanded(
              child: Semantics(
                header: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (subpage
                                  ? ScootType.phoneSubpageTitle
                                  : ScootType.phoneTitle)
                              .copyWith(color: c.ink),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ScootType.caption.copyWith(color: c.muted),
                      ),
                  ],
                ),
              ),
            ),
            for (final Widget action in actions) ...<Widget>[
              const SizedBox(width: 4),
              action,
            ],
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class ScootPhoneAction extends StatelessWidget {
  const ScootPhoneAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.count,
    this.countLabel,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final int? count;
  final String? countLabel;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final bool hasCount = count != null && count! > 0;
    return ScootPressable(
      onTap: onPressed,
      minSize: const Size.square(ScootSize.phoneTarget),
      tooltip: label,
      semanticLabel: hasCount ? '$label, ${countLabel ?? '$count new'}' : label,
      child: SizedBox.square(
        dimension: ScootSize.phoneTarget,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Icon(icon, size: ScootSize.phoneIcon, color: c.text2),
            if (hasCount)
              Positioned(
                top: 2,
                right: 0,
                child: ScootCountBadge(
                  count: count!,
                  semanticLabel: countLabel ?? '$count new',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ScootCopilotPill extends StatelessWidget {
  const ScootCopilotPill({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return ScootPressable(
      onTap: onPressed,
      minSize: const Size(0, ScootSize.phoneTarget),
      borderRadius: ScootRadius.pillAll,
      semanticLabel: 'Scout',
      child: SizedBox(
        height: ScootSize.phoneTarget,
        child: Center(
          widthFactor: 1,
          child: Container(
            height: ScootSize.copilotPill,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: c.card,
              border: Border.all(color: c.line2),
              borderRadius: ScootRadius.pillAll,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(ScootIcons.mic, size: 18, color: c.brandText),
                const SizedBox(width: 6),
                Text(
                  'Scout',
                  style: ScootType.smallStrong.copyWith(
                    color: c.brandText,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ScootSectionHeader extends StatelessWidget {
  const ScootSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return SizedBox(
      height: ScootSize.phoneTarget,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: ScootType.section.copyWith(color: c.ink),
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton.icon(
              onPressed: onAction,
              icon: actionIcon == null ? null : Icon(actionIcon, size: 18),
              label: Text(actionLabel!),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
        ],
      ),
    );
  }
}
