import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';

class ScootBadge extends StatelessWidget {
  const ScootBadge({
    super.key,
    required this.label,
    this.tone = ScootTone.neutral,
    this.icon,
  });

  const ScootBadge.waiting({super.key, this.label = 'Waiting for approval'})
    : tone = ScootTone.info,
      icon = ScootIcons.clock;

  const ScootBadge.approved({super.key, this.label = 'Approved'})
    : tone = ScootTone.success,
      icon = ScootIcons.check;

  const ScootBadge.rejected({super.key, this.label = 'Rejected'})
    : tone = ScootTone.danger,
      icon = ScootIcons.close;

  const ScootBadge.attention({super.key, required this.label})
    : tone = ScootTone.warning,
      icon = ScootIcons.error;

  const ScootBadge.draft({super.key, this.label = 'Draft'})
    : tone = ScootTone.neutral,
      icon = ScootIcons.edit;

  final String label;
  final ScootTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ScootToneColors colors = ScootColors.of(context).tone(tone);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: ScootRadius.pillAll,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 14, color: colors.foreground),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ScootType.caption.copyWith(
                  color: colors.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScootCountBadge extends StatelessWidget {
  const ScootCountBadge({
    super.key,
    required this.count,
    required this.semanticLabel,
    this.text,
  });

  final int count;
  final String semanticLabel;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: 1,
        heightFactor: 1,
        child: Container(
          constraints: const BoxConstraints(minWidth: 22, minHeight: 20),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: c.countBg,
            borderRadius: ScootRadius.pillAll,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              text ?? (count > 99 ? '99+' : '$count'),
              style: ScootType.caption.copyWith(
                color: c.countText,
                fontWeight: FontWeight.w700,
                fontFeatures: ScootType.tabular,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
