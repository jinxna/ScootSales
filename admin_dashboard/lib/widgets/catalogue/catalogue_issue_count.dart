import 'package:flutter/material.dart';

import 'package:scoot_design/scoot_design.dart';

import '../../theme/dso_theme.dart';
import 'catalogue_status_pill.dart';

class CatalogueIssueCount extends StatelessWidget {
  const CatalogueIssueCount({
    super.key,
    required this.label,
    required this.count,
    required this.onTap,
    this.active = false,
    this.tone = CatalogueTone.warning,
  });

  final String label;
  final int count;
  final VoidCallback onTap;
  final bool active;
  final CatalogueTone tone;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final ScootColors c = ScootColors.of(context);
    final bool none = count == 0;
    final Color countColor = none
        ? dso.subtle
        : tone == CatalogueTone.danger
        ? dso.dangerText
        : tone == CatalogueTone.warning
        ? dso.warningText
        : dso.ink;
    return Semantics(
      button: true,
      enabled: !none,
      selected: active,
      label: '$label $count',
      excludeSemantics: true,
      onTap: none ? null : onTap,
      child: InkWell(
        borderRadius: ScootRadius.pillAll,
        onTap: none ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: active ? c.brandTint : c.card,
            border: Border.all(color: active ? c.brandTintBorder : c.line),
            borderRadius: ScootRadius.pillAll,
          ),
          child: Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: '$label  ',
                  style: TextStyle(color: none ? dso.subtle : c.text2),
                ),
                TextSpan(
                  text: '$count',
                  style: TextStyle(
                    color: countColor,
                    fontWeight: FontWeight.w700,
                    fontFeatures: ScootType.tabular,
                  ),
                ),
              ],
            ),
            style: ScootType.small,
          ),
        ),
      ),
    );
  }
}
