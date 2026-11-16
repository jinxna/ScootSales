import 'package:flutter/material.dart';

import '../../theme/dso_theme.dart';

enum CatalogueTone { neutral, success, warning, danger, info }

(Color, Color) catalogueToneColors(BuildContext context, CatalogueTone tone) {
  final DsoColors dso = context.dso;
  switch (tone) {
    case CatalogueTone.success:
      return (dso.successSoft, dso.successText);
    case CatalogueTone.warning:
      return (dso.warningSoft, dso.warningText);
    case CatalogueTone.danger:
      return (dso.dangerSoft, dso.dangerText);
    case CatalogueTone.info:
      return (dso.infoSoft, dso.infoText);
    case CatalogueTone.neutral:
      return (dso.surfaceSoft, dso.muted);
  }
}

class CatalogueStatusPill extends StatelessWidget {
  const CatalogueStatusPill({
    super.key,
    required this.label,
    required this.tone,
  });

  final String label;
  final CatalogueTone tone;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = catalogueToneColors(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DsoTokens.rPill),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}
