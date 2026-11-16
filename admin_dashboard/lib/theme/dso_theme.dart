import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import 'dso_colors.dart';

export 'dso_colors.dart';

class DsoTokens {
  const DsoTokens._();

  static const Color green900 = Color(0xFF1A4A3C);
  static const Color green700 = Color(0xFF2D6A4F);
  static const Color green600 = Color(0xFF2D6E5E);
  static const Color green550 = Color(0xFF3A7D5C);
  static const Color green500 = Color(0xFF40916C);
  static const Color greenBright = Color(0xFF27AE60);
  static const Color greenSurface = Color(0xFFEFF5F1);

  static const Color success = Color(0xFF27AE60);
  static const Color warning = Color(0xFFFF9500);
  static const Color warningAmber = Color(0xFFF79009);
  static const Color danger = Color(0xFFD32F2F);
  static const Color info = Color(0xFF1E88E5);
  static const Color successSoft = Color(0xFFE7F8EE);
  static const Color successSurfaceDark = Color(0xFF153D2C);
  static const Color successTextDark = Color(0xFF7EE2A8);
  static const Color warningSoft = Color(0xFFFFF7ED);
  static const Color warningText = Color(0xFF9A3412);
  static const Color warningSurfaceDark = Color(0xFF4A3410);
  static const Color warningTextDark = Color(0xFFFFD166);
  static const Color dangerSoft = Color(0xFFFEE2E2);
  static const Color dangerText = Color(0xFFB42318);
  static const Color successText = Color(0xFF166534);
  static const Color infoSoft = Color(0xFFEFF6FF);
  static const Color infoText = Color(0xFF1D4ED8);
  static const Color infoSurfaceDark = Color(0xFF1E335C);
  static const Color infoTextDark = Color(0xFF93C5FD);
  static const Color violet = Color(0xFF6D28D9);
  static const Color violetSoft = Color(0xFFF5F3FF);
  static const List<Color> salesmanMapPalette = <Color>[
    Color(0xFF2563EB),
    Color(0xFF16A34A),
    Color(0xFFDC2626),
    Color(0xFF9333EA),
    Color(0xFFEA580C),
    Color(0xFF0891B2),
    Color(0xFFBE123C),
    Color(0xFF4F46E5),
  ];

  static const Color ink = Color(0xFF1C1917);
  static const Color body = Color(0xFF44403C);
  static const Color secondary = Color(0xFF78716C);
  static const Color tertiary = Color(0xFFA8A29E);
  static const Color hairline = Color(0xFFE9E7E2);
  static const Color soft = Color(0xFFEFEDE8);
  static const Color hover = Color(0xFFF5F5F4);
  static const Color canvas = Color(0xFFFAFAF8);
  static const Color white = Color(0xFFFFFFFF);

  static const List<BoxShadow> cardShadow = <BoxShadow>[
    BoxShadow(color: Color(0x09000000), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0D000000), blurRadius: 14, offset: Offset(0, 4)),
  ];

  static Color fineBorder(Color outline, Color surface) =>
      Color.lerp(surface, outline, 0.55)!;

  static const double rSm = 8;
  static const double rMd = 10;
  static const double rXl = 16;
  static const double rDialog = 18;
  static const double rPill = 999;
}

enum DsoDensity { compact, comfortable, spacious }

enum DsoThemeMode { light, dark }

class DsoAppearance {
  const DsoAppearance({
    this.accent = ScootPalette.brand,
    this.mode = DsoThemeMode.light,
    this.density = DsoDensity.comfortable,
  });

  final Color accent;
  final DsoThemeMode mode;
  final DsoDensity density;

  bool get dark => mode == DsoThemeMode.dark;

  DsoAppearance copyWith({
    Color? accent,
    DsoThemeMode? mode,
    DsoDensity? density,
  }) {
    return DsoAppearance(
      accent: accent ?? this.accent,
      mode: mode ?? this.mode,
      density: density ?? this.density,
    );
  }
}

class DsoTheme {
  const DsoTheme._();

  static ThemeData get light => build(const DsoAppearance());

  static VisualDensity _visualDensity(DsoDensity density) {
    switch (density) {
      case DsoDensity.compact:
        return const VisualDensity(horizontal: -2, vertical: -2);
      case DsoDensity.comfortable:
        return VisualDensity.standard;
      case DsoDensity.spacious:
        return const VisualDensity(horizontal: 1, vertical: 1);
    }
  }

  static ThemeData build(DsoAppearance appearance) {
    return ScootTheme.dashboard(
      brightness: appearance.dark ? Brightness.dark : Brightness.light,
      extensions: <ThemeExtension<dynamic>>[
        DsoColors.forAppearance(appearance),
      ],
    ).copyWith(visualDensity: _visualDensity(appearance.density));
  }
}
