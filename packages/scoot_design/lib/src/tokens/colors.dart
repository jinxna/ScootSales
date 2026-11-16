import 'package:flutter/material.dart';

class ScootPalette {
  const ScootPalette._();

  static const Color brand = Color(0xFF3A7D5C);
  static const Color brandHover = Color(0xFF2F6B4D);
  static const Color brandTint = Color(0xFFF0F7F3);
  static const Color brandTintBorder = Color(0xFFCFE3D7);
  static const Color brandText = Color(0xFF1D6340);

  static const Color ink = Color(0xFF16201B);
  static const Color text2 = Color(0xFF3F4A44);
  static const Color muted = Color(0xFF5F6B65);
  static const Color line = Color(0xFFE3E7E4);
  static const Color line2 = Color(0xFFD5DBD7);
  static const Color hair = Color(0xFFEEF1EF);
  static const Color page = Color(0xFFF5F7F6);
  static const Color card = Color(0xFFFFFFFF);
  static const Color tableHead = Color(0xFFFAFBFA);
  static const Color tableHeadText = Color(0xFF5A6660);
  static const Color searchFill = Color(0xFFF8FAF9);
  static const Color skeleton = Color(0xFFE9EDEA);
  static const Color disabledFill = Color(0xFFEEF1EF);
  static const Color disabledText = Color(0xFF626C67);

  static const Color navBg = Color(0xFF10231A);
  static const Color navHover = Color(0xFF1A3426);
  static const Color navOn = Color(0xFF24452F);
  static const Color navText = Color(0xFFC9D8CF);
  static const Color navLabel = Color(0xFF93AB9E);
  static const Color countBg = Color(0xFFF2B24C);
  static const Color countText = Color(0xFF2A1A00);

  static const Color greenBg = Color(0xFFE5F3EA);
  static const Color greenFg = Color(0xFF1D6340);
  static const Color amberBg = Color(0xFFFFF1DA);
  static const Color amberFg = Color(0xFF7F4500);
  static const Color blueBg = Color(0xFFE8F0FF);
  static const Color blueFg = Color(0xFF1E4FBF);
  static const Color redBg = Color(0xFFFDECEA);
  static const Color redFg = Color(0xFFA8261B);
  static const Color grayBg = Color(0xFFEFF2F0);
  static const Color grayFg = Color(0xFF46514B);

  static const Color warnNoteBg = Color(0xFFFFF8EC);
  static const Color warnNoteBorder = Color(0xFFF5DDB0);
  static const Color warnNoteText = Color(0xFF6B3F00);
  static const Color errNoteBg = Color(0xFFFDECEA);
  static const Color errNoteBorder = Color(0xFFF4C7C1);
  static const Color errNoteText = Color(0xFF7A1B12);
  static const Color okNoteBg = Color(0xFFEAF3EE);
  static const Color okNoteBorder = Color(0xFFBFD9CB);
  static const Color okNoteText = Color(0xFF24533C);
  static const Color infoNoteBg = Color(0xFFE8F0FF);
  static const Color infoNoteBorder = Color(0xFFC9D8F5);
  static const Color infoNoteText = Color(0xFF1E3F8F);
  static const Color neutralNoteBg = Color(0xFFEFF2F0);
  static const Color neutralNoteBorder = Color(0xFFE3E7E4);
  static const Color neutralNoteText = Color(0xFF2C3631);
}

enum ScootTone { success, warning, info, danger, neutral }

@immutable
class ScootToneColors {
  const ScootToneColors({
    required this.background,
    required this.foreground,
    required this.border,
    required this.noteBackground,
    required this.noteText,
  });

  final Color background;
  final Color foreground;
  final Color border;
  final Color noteBackground;
  final Color noteText;
}

@immutable
class ScootColors extends ThemeExtension<ScootColors> {
  const ScootColors({
    required this.brightness,
    required this.page,
    required this.card,
    required this.tableHead,
    required this.tableHeadText,
    required this.searchFill,
    required this.line,
    required this.line2,
    required this.hair,
    required this.ink,
    required this.text2,
    required this.muted,
    required this.brand,
    required this.onBrand,
    required this.brandHover,
    required this.brandTint,
    required this.brandTintBorder,
    required this.brandText,
    required this.focus,
    required this.skeleton,
    required this.disabledFill,
    required this.disabledText,
    required this.navBg,
    required this.navHover,
    required this.navOn,
    required this.navText,
    required this.navLabel,
    required this.navDivider,
    required this.countBg,
    required this.countText,
    required this.scrim,
    required this.success,
    required this.warning,
    required this.info,
    required this.danger,
    required this.neutral,
  });

  final Brightness brightness;
  final Color page;
  final Color card;
  final Color tableHead;
  final Color tableHeadText;
  final Color searchFill;
  final Color line;
  final Color line2;
  final Color hair;
  final Color ink;
  final Color text2;
  final Color muted;
  final Color brand;
  final Color onBrand;
  final Color brandHover;
  final Color brandTint;
  final Color brandTintBorder;
  final Color brandText;
  final Color focus;
  final Color skeleton;
  final Color disabledFill;
  final Color disabledText;
  final Color navBg;
  final Color navHover;
  final Color navOn;
  final Color navText;
  final Color navLabel;
  final Color navDivider;
  final Color countBg;
  final Color countText;
  final Color scrim;
  final ScootToneColors success;
  final ScootToneColors warning;
  final ScootToneColors info;
  final ScootToneColors danger;
  final ScootToneColors neutral;

  bool get isDark => brightness == Brightness.dark;

  ScootToneColors tone(ScootTone tone) {
    switch (tone) {
      case ScootTone.success:
        return success;
      case ScootTone.warning:
        return warning;
      case ScootTone.info:
        return info;
      case ScootTone.danger:
        return danger;
      case ScootTone.neutral:
        return neutral;
    }
  }

  static const ScootColors light = ScootColors(
    brightness: Brightness.light,
    page: ScootPalette.page,
    card: ScootPalette.card,
    tableHead: ScootPalette.tableHead,
    tableHeadText: ScootPalette.tableHeadText,
    searchFill: ScootPalette.searchFill,
    line: ScootPalette.line,
    line2: ScootPalette.line2,
    hair: ScootPalette.hair,
    ink: ScootPalette.ink,
    text2: ScootPalette.text2,
    muted: ScootPalette.muted,
    brand: ScootPalette.brand,
    onBrand: Color(0xFFFFFFFF),
    brandHover: ScootPalette.brandHover,
    brandTint: ScootPalette.brandTint,
    brandTintBorder: ScootPalette.brandTintBorder,
    brandText: ScootPalette.brandText,
    focus: ScootPalette.brand,
    skeleton: ScootPalette.skeleton,
    disabledFill: ScootPalette.disabledFill,
    disabledText: ScootPalette.disabledText,
    navBg: ScootPalette.navBg,
    navHover: ScootPalette.navHover,
    navOn: ScootPalette.navOn,
    navText: ScootPalette.navText,
    navLabel: ScootPalette.navLabel,
    navDivider: ScootPalette.navOn,
    countBg: ScootPalette.countBg,
    countText: ScootPalette.countText,
    scrim: Color(0x6B10231A),
    success: ScootToneColors(
      background: ScootPalette.greenBg,
      foreground: ScootPalette.greenFg,
      border: ScootPalette.okNoteBorder,
      noteBackground: ScootPalette.okNoteBg,
      noteText: ScootPalette.okNoteText,
    ),
    warning: ScootToneColors(
      background: ScootPalette.amberBg,
      foreground: ScootPalette.amberFg,
      border: ScootPalette.warnNoteBorder,
      noteBackground: ScootPalette.warnNoteBg,
      noteText: ScootPalette.warnNoteText,
    ),
    info: ScootToneColors(
      background: ScootPalette.blueBg,
      foreground: ScootPalette.blueFg,
      border: ScootPalette.infoNoteBorder,
      noteBackground: ScootPalette.infoNoteBg,
      noteText: ScootPalette.infoNoteText,
    ),
    danger: ScootToneColors(
      background: ScootPalette.redBg,
      foreground: ScootPalette.redFg,
      border: ScootPalette.errNoteBorder,
      noteBackground: ScootPalette.errNoteBg,
      noteText: ScootPalette.errNoteText,
    ),
    neutral: ScootToneColors(
      background: ScootPalette.grayBg,
      foreground: ScootPalette.grayFg,
      border: ScootPalette.neutralNoteBorder,
      noteBackground: ScootPalette.neutralNoteBg,
      noteText: ScootPalette.neutralNoteText,
    ),
  );

  static const ScootColors dark = ScootColors(
    brightness: Brightness.dark,
    page: Color(0xFF0F1412),
    card: Color(0xFF171E1B),
    tableHead: Color(0xFF1C2420),
    tableHeadText: Color(0xFFAEB8B2),
    searchFill: Color(0xFF111714),
    line: Color(0xFF2C3832),
    line2: Color(0xFF3B4942),
    hair: Color(0xFF232C28),
    ink: Color(0xFFE8ECE8),
    text2: Color(0xFFC4CCC5),
    muted: Color(0xFFA3ADA7),
    brand: ScootPalette.brand,
    onBrand: Color(0xFFFFFFFF),
    brandHover: ScootPalette.brandHover,
    brandTint: Color(0xFF16291F),
    brandTintBorder: Color(0xFF2E5A42),
    brandText: Color(0xFF8FD0AC),
    focus: Color(0xFF8FD0AC),
    skeleton: Color(0xFF26302B),
    disabledFill: Color(0xFF222B26),
    disabledText: Color(0xFF9AA49E),
    navBg: Color(0xFF0B1912),
    navHover: Color(0xFF16291F),
    navOn: Color(0xFF214130),
    navText: Color(0xFFC9D8CF),
    navLabel: Color(0xFF93AB9E),
    navDivider: Color(0xFF214130),
    countBg: ScootPalette.countBg,
    countText: ScootPalette.countText,
    scrim: Color(0x99000000),
    success: ScootToneColors(
      background: Color(0xFF153D2C),
      foreground: Color(0xFF9DE3B9),
      border: Color(0xFF2E5A42),
      noteBackground: Color(0xFF122E22),
      noteText: Color(0xFFB9E8CB),
    ),
    warning: ScootToneColors(
      background: Color(0xFF4A3410),
      foreground: Color(0xFFFFD58A),
      border: Color(0xFF6B4D1C),
      noteBackground: Color(0xFF33250C),
      noteText: Color(0xFFFFDFA6),
    ),
    info: ScootToneColors(
      background: Color(0xFF1E335C),
      foreground: Color(0xFFB4CCFF),
      border: Color(0xFF34507F),
      noteBackground: Color(0xFF172742),
      noteText: Color(0xFFC6D7FF),
    ),
    danger: ScootToneColors(
      background: Color(0xFF4A1C18),
      foreground: Color(0xFFFFB8AE),
      border: Color(0xFF6E2F28),
      noteBackground: Color(0xFF361512),
      noteText: Color(0xFFFFC7BF),
    ),
    neutral: ScootToneColors(
      background: Color(0xFF2A332E),
      foreground: Color(0xFFC4CCC5),
      border: Color(0xFF3B4942),
      noteBackground: Color(0xFF1F2723),
      noteText: Color(0xFFD3DAD5),
    ),
  );

  static ScootColors of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.extension<ScootColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  ScootColors copyWith({Color? brand, Color? brandHover, Color? focus}) {
    return ScootColors(
      brightness: brightness,
      page: page,
      card: card,
      tableHead: tableHead,
      tableHeadText: tableHeadText,
      searchFill: searchFill,
      line: line,
      line2: line2,
      hair: hair,
      ink: ink,
      text2: text2,
      muted: muted,
      brand: brand ?? this.brand,
      onBrand: onBrand,
      brandHover: brandHover ?? this.brandHover,
      brandTint: brandTint,
      brandTintBorder: brandTintBorder,
      brandText: brandText,
      focus: focus ?? this.focus,
      skeleton: skeleton,
      disabledFill: disabledFill,
      disabledText: disabledText,
      navBg: navBg,
      navHover: navHover,
      navOn: navOn,
      navText: navText,
      navLabel: navLabel,
      navDivider: navDivider,
      countBg: countBg,
      countText: countText,
      scrim: scrim,
      success: success,
      warning: warning,
      info: info,
      danger: danger,
      neutral: neutral,
    );
  }

  @override
  ScootColors lerp(ThemeExtension<ScootColors>? other, double t) {
    if (other is! ScootColors) {
      return this;
    }
    return t < 0.5 ? this : other;
  }
}
