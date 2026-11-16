import 'package:flutter/material.dart';

import 'dso_theme.dart';

@immutable
class DsoColors extends ThemeExtension<DsoColors> {
  const DsoColors({
    required this.surface,
    required this.card,
    required this.surfaceSoft,
    required this.hairline,
    required this.ink,
    required this.body,
    required this.muted,
    required this.subtle,
    required this.brandSurface,
    required this.accent,
    required this.accentText,
    required this.successSoft,
    required this.successText,
    required this.success,
    required this.warningSoft,
    required this.warningText,
    required this.warning,
    required this.dangerSoft,
    required this.dangerText,
    required this.danger,
    required this.infoSoft,
    required this.infoText,
    required this.info,
    required this.violetSoft,
    required this.violetText,
    required this.violet,
  });

  final Color surface;

  final Color card;

  final Color surfaceSoft;
  final Color hairline;

  final Color ink;
  final Color body;
  final Color muted;
  final Color subtle;

  final Color brandSurface;

  final Color accent;
  final Color accentText;

  final Color successSoft;
  final Color successText;
  final Color success;
  final Color warningSoft;
  final Color warningText;
  final Color warning;
  final Color dangerSoft;
  final Color dangerText;
  final Color danger;
  final Color infoSoft;
  final Color infoText;
  final Color info;
  final Color violetSoft;
  final Color violetText;
  final Color violet;

  static DsoColors light([Color accent = DsoTokens.green600]) => DsoColors(
    surface: DsoTokens.canvas,
    card: DsoTokens.white,
    surfaceSoft: DsoTokens.soft,
    hairline: DsoTokens.hairline,
    ink: DsoTokens.ink,
    body: DsoTokens.body,
    muted: DsoTokens.secondary,
    subtle: DsoTokens.tertiary,
    brandSurface: DsoTokens.greenSurface,
    accent: accent,
    accentText: accent,
    successSoft: DsoTokens.successSoft,
    successText: DsoTokens.successText,
    success: DsoTokens.success,
    warningSoft: DsoTokens.warningSoft,
    warningText: DsoTokens.warningText,
    warning: DsoTokens.warning,
    dangerSoft: DsoTokens.dangerSoft,
    dangerText: DsoTokens.dangerText,
    danger: DsoTokens.danger,
    infoSoft: DsoTokens.infoSoft,
    infoText: DsoTokens.infoText,
    info: DsoTokens.info,
    violetSoft: DsoTokens.violetSoft,
    violetText: DsoTokens.violet,
    violet: DsoTokens.violet,
  );

  static DsoColors dark([Color accent = DsoTokens.green600]) => DsoColors(
    surface: const Color(0xFF0F1412),
    card: const Color(0xFF171E1B),
    surfaceSoft: const Color(0xFF222B26),
    hairline: const Color(0xFF3B4942),
    ink: const Color(0xFFE8ECE8),
    body: const Color(0xFFC4CCC5),
    muted: const Color(0xFF9DA9A1),
    subtle: const Color(0xFF7F8B84),
    brandSurface: const Color(0xFF1B2E26),
    accent: accent,
    accentText: Color.lerp(accent, Colors.white, 0.35)!,
    successSoft: DsoTokens.successSurfaceDark,
    successText: DsoTokens.successTextDark,
    success: DsoTokens.success,
    warningSoft: DsoTokens.warningSurfaceDark,
    warningText: DsoTokens.warningTextDark,
    warning: DsoTokens.warning,
    dangerSoft: const Color(0xFF4A1F1F),
    dangerText: const Color(0xFFFFB4AB),
    danger: DsoTokens.danger,
    infoSoft: DsoTokens.infoSurfaceDark,
    infoText: DsoTokens.infoTextDark,
    info: DsoTokens.info,
    violetSoft: const Color(0xFF2E2350),
    violetText: const Color(0xFFC4B5FD),
    violet: DsoTokens.violet,
  );

  static DsoColors forAppearance(DsoAppearance a) => a.dark
      ? dark(a.accent)
      : light(a.accent);

  @override
  DsoColors copyWith({
    Color? surface,
    Color? card,
    Color? surfaceSoft,
    Color? hairline,
    Color? ink,
    Color? body,
    Color? muted,
    Color? subtle,
    Color? brandSurface,
    Color? accent,
    Color? accentText,
    Color? successSoft,
    Color? successText,
    Color? success,
    Color? warningSoft,
    Color? warningText,
    Color? warning,
    Color? dangerSoft,
    Color? dangerText,
    Color? danger,
    Color? infoSoft,
    Color? infoText,
    Color? info,
    Color? violetSoft,
    Color? violetText,
    Color? violet,
  }) => DsoColors(
    surface: surface ?? this.surface,
    card: card ?? this.card,
    surfaceSoft: surfaceSoft ?? this.surfaceSoft,
    hairline: hairline ?? this.hairline,
    ink: ink ?? this.ink,
    body: body ?? this.body,
    muted: muted ?? this.muted,
    subtle: subtle ?? this.subtle,
    brandSurface: brandSurface ?? this.brandSurface,
    accent: accent ?? this.accent,
    accentText: accentText ?? this.accentText,
    successSoft: successSoft ?? this.successSoft,
    successText: successText ?? this.successText,
    success: success ?? this.success,
    warningSoft: warningSoft ?? this.warningSoft,
    warningText: warningText ?? this.warningText,
    warning: warning ?? this.warning,
    dangerSoft: dangerSoft ?? this.dangerSoft,
    dangerText: dangerText ?? this.dangerText,
    danger: danger ?? this.danger,
    infoSoft: infoSoft ?? this.infoSoft,
    infoText: infoText ?? this.infoText,
    info: info ?? this.info,
    violetSoft: violetSoft ?? this.violetSoft,
    violetText: violetText ?? this.violetText,
    violet: violet ?? this.violet,
  );

  @override
  DsoColors lerp(ThemeExtension<DsoColors>? other, double t) {
    if (other is! DsoColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DsoColors(
      surface: l(surface, other.surface),
      card: l(card, other.card),
      surfaceSoft: l(surfaceSoft, other.surfaceSoft),
      hairline: l(hairline, other.hairline),
      ink: l(ink, other.ink),
      body: l(body, other.body),
      muted: l(muted, other.muted),
      subtle: l(subtle, other.subtle),
      brandSurface: l(brandSurface, other.brandSurface),
      accent: l(accent, other.accent),
      accentText: l(accentText, other.accentText),
      successSoft: l(successSoft, other.successSoft),
      successText: l(successText, other.successText),
      success: l(success, other.success),
      warningSoft: l(warningSoft, other.warningSoft),
      warningText: l(warningText, other.warningText),
      warning: l(warning, other.warning),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      dangerText: l(dangerText, other.dangerText),
      danger: l(danger, other.danger),
      infoSoft: l(infoSoft, other.infoSoft),
      infoText: l(infoText, other.infoText),
      info: l(info, other.info),
      violetSoft: l(violetSoft, other.violetSoft),
      violetText: l(violetText, other.violetText),
      violet: l(violet, other.violet),
    );
  }
}

extension DsoBuildContext on BuildContext {
  DsoColors get dso =>
      Theme.of(this).extension<DsoColors>() ?? DsoColors.light();
}
