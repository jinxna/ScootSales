import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';
import 'focus_ring.dart';

class ScootNotice extends StatelessWidget {
  const ScootNotice({
    super.key,
    required this.tone,
    required this.message,
    this.title,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.liveRegion = false,
    this.actionBelow = false,
  });

  factory ScootNotice.pastDue({
    Key? key,
    required String since,
    VoidCallback? onOpenAccount,
  }) {
    return ScootNotice(
      key: key,
      tone: ScootTone.warning,
      icon: ScootIcons.error,
      title: 'Payment overdue',
      message:
          'Payment overdue since $since. Everyone can still work. Open Account and plan to pay.',
      actionLabel: onOpenAccount == null ? null : 'Account and plan',
      onAction: onOpenAccount,
    );
  }

  factory ScootNotice.readOnly({
    Key? key,
    String message = 'You can view this page but not change it.',
  }) {
    return ScootNotice(
      key: key,
      tone: ScootTone.neutral,
      icon: ScootIcons.lock,
      title: 'Read-only',
      message: message,
    );
  }

  factory ScootNotice.roleChanged({
    Key? key,
    required String roleName,
    required String pagesLabel,
    VoidCallback? onDismiss,
  }) {
    return ScootNotice(
      key: key,
      tone: ScootTone.neutral,
      icon: ScootIcons.roleChanged,
      message:
          'Your role changed to $roleName. The menu now shows $pagesLabel pages.',
      actionLabel: onDismiss == null ? null : 'OK',
      onAction: onDismiss,
      liveRegion: true,
      actionBelow: true,
    );
  }

  final ScootTone tone;
  final String message;
  final String? title;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;
  final bool liveRegion;
  final bool actionBelow;

  static IconData defaultIcon(ScootTone tone) {
    switch (tone) {
      case ScootTone.success:
        return ScootIcons.success;
      case ScootTone.warning:
        return ScootIcons.warning;
      case ScootTone.info:
        return ScootIcons.info;
      case ScootTone.danger:
        return ScootIcons.error;
      case ScootTone.neutral:
        return ScootIcons.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ScootToneColors t = ScootColors.of(context).tone(tone);
    final TextStyle base = ScootType.body.copyWith(color: t.noteText);
    final bool hasAction = actionLabel != null && onAction != null;
    final bool below = actionBelow && hasAction;
    final Widget note = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: EdgeInsets.fromLTRB(14, 6, below ? 14 : 6, 6),
      decoration: BoxDecoration(
        color: t.noteBackground,
        border: Border.all(color: t.border),
        borderRadius: ScootRadius.noteAll,
      ),
      child: Row(
        children: <Widget>[
          Icon(icon ?? defaultIcon(tone), size: 18, color: t.noteText),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    if (title != null)
                      TextSpan(
                        text: '$title. ',
                        style: base.copyWith(fontWeight: FontWeight.w700),
                      ),
                    TextSpan(text: message),
                  ],
                ),
                style: base,
              ),
            ),
          ),
          if (hasAction && !below) ...<Widget>[
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
          if (onDismiss != null)
            ScootFocusRing(
              child: IconButton(
                onPressed: onDismiss,
                tooltip: 'Dismiss',
                icon: Icon(ScootIcons.close, color: t.noteText),
              ),
            ),
        ],
      ),
    );
    return Semantics(
      container: true,
      liveRegion: liveRegion,
      child: below
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                note,
                const SizedBox(height: 8),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            )
          : note,
    );
  }
}
