import 'package:flutter/material.dart';

import 'tokens/colors.dart';
import 'tokens/metrics.dart';

enum ScootSurface { dashboard, phone }

class ScootTheme {
  const ScootTheme._();

  static ThemeData dashboard({
    Brightness brightness = Brightness.light,
    String? fontFamily = ScootType.fontFamily,
    Iterable<ThemeExtension<dynamic>> extensions =
        const <ThemeExtension<dynamic>>[],
  }) {
    return build(
      surface: ScootSurface.dashboard,
      brightness: brightness,
      fontFamily: fontFamily,
      extensions: extensions,
    );
  }

  static ThemeData phone({
    Brightness brightness = Brightness.light,
    String? fontFamily = ScootType.fontFamily,
    Iterable<ThemeExtension<dynamic>> extensions =
        const <ThemeExtension<dynamic>>[],
  }) {
    return build(
      surface: ScootSurface.phone,
      brightness: brightness,
      fontFamily: fontFamily,
      extensions: extensions,
    );
  }

  static double targetFor(ScootSurface surface) => surface == ScootSurface.phone
      ? ScootSize.phoneTarget
      : ScootSize.dashboardTarget;

  static ThemeData build({
    required ScootSurface surface,
    Brightness brightness = Brightness.light,
    String? fontFamily = ScootType.fontFamily,
    Iterable<ThemeExtension<dynamic>> extensions =
        const <ThemeExtension<dynamic>>[],
  }) {
    final ScootColors c = brightness == Brightness.dark
        ? ScootColors.dark
        : ScootColors.light;
    final double target = targetFor(surface);
    final Size minButton = Size(64, target);
    final Size minIcon = Size(target, target);

    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: ScootPalette.brand,
          brightness: brightness,
        ).copyWith(
          primary: c.brand,
          onPrimary: c.onBrand,
          primaryContainer: c.brandTint,
          onPrimaryContainer: c.brandText,
          secondary: c.text2,
          onSecondary: c.card,
          surface: c.card,
          onSurface: c.ink,
          onSurfaceVariant: c.text2,
          surfaceContainerLowest: c.card,
          surfaceContainerLow: c.page,
          surfaceContainer: c.page,
          surfaceContainerHigh: c.tableHead,
          surfaceContainerHighest: c.hair,
          outline: c.line2,
          outlineVariant: c.line,
          error: c.danger.foreground,
          onError: c.card,
          errorContainer: c.danger.background,
          onErrorContainer: c.danger.foreground,
          surfaceTint: Colors.transparent,
        );
    TextStyle withFont(TextStyle style) => style.copyWith(
      fontFamily: fontFamily,
      fontFamilyFallback: ScootType.fontFamilyFallback,
    );

    final TextTheme text = TextTheme(
      displaySmall: withFont(ScootType.kpi).copyWith(color: c.ink),
      headlineSmall: withFont(ScootType.h1).copyWith(color: c.ink),
      titleLarge: withFont(ScootType.h2).copyWith(color: c.ink),
      titleMedium: withFont(ScootType.cardTitle).copyWith(color: c.ink),
      titleSmall: withFont(ScootType.section).copyWith(color: c.ink),
      bodyLarge: withFont(ScootType.body).copyWith(color: c.ink),
      bodyMedium: withFont(ScootType.body).copyWith(color: c.ink),
      bodySmall: withFont(ScootType.small).copyWith(color: c.muted),
      labelLarge: withFont(ScootType.button).copyWith(color: c.ink),
      labelMedium: withFont(ScootType.caption).copyWith(color: c.text2),
      labelSmall: withFont(ScootType.caption).copyWith(color: c.muted),
    );

    final OutlinedBorder controlShape = const RoundedRectangleBorder(
      borderRadius: ScootRadius.controlAll,
    );
    final WidgetStateProperty<BorderSide?> focusSide =
        WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.focused)) {
            return BorderSide(color: c.focus, width: 2);
          }
          return null;
        });
    final WidgetStateProperty<BorderSide?> outlinedSide =
        WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.focused)) {
            return BorderSide(color: c.focus, width: 2);
          }
          if (states.contains(WidgetState.disabled)) {
            return BorderSide(color: c.line);
          }
          return BorderSide(color: c.line2);
        });

    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
      fontFamilyFallback: ScootType.fontFamilyFallback,
      materialTapTargetSize: surface == ScootSurface.phone
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      extensions: [c, ...extensions],
    );

    return base.copyWith(
      scaffoldBackgroundColor: c.page,
      canvasColor: c.card,
      dividerColor: c.line,
      focusColor: c.brandTint,
      hoverColor: c.hair,
      textTheme: base.textTheme.merge(text),
      iconTheme: IconThemeData(color: c.text2, size: ScootSize.icon),
      dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: c.card,
        foregroundColor: c.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: withFont(ScootType.phoneTitle).copyWith(color: c.ink),
        toolbarHeight: surface == ScootSurface.phone
            ? ScootSize.phoneAppBar
            : ScootSize.topBar,
      ),
      cardTheme: CardThemeData(
        color: c.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: ScootRadius.cardAll,
          side: BorderSide(color: c.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.card,
        isDense: true,
        constraints: BoxConstraints(minHeight: target),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: withFont(ScootType.body).copyWith(color: c.muted),
        labelStyle: withFont(ScootType.smallStrong).copyWith(color: c.ink),
        floatingLabelStyle: withFont(
          ScootType.smallStrong,
        ).copyWith(color: c.brandText),
        prefixIconColor: c.muted,
        suffixIconColor: c.muted,
        border: OutlineInputBorder(
          borderRadius: ScootRadius.controlAll,
          borderSide: BorderSide(color: c.line2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: ScootRadius.controlAll,
          borderSide: BorderSide(color: c.line2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: ScootRadius.controlAll,
          borderSide: BorderSide(color: c.focus, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: ScootRadius.controlAll,
          borderSide: BorderSide(color: c.danger.foreground),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: ScootRadius.controlAll,
          borderSide: BorderSide(color: c.danger.foreground, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll<Size>(minButton),
          padding: const WidgetStatePropertyAll<EdgeInsets>(
            EdgeInsets.symmetric(horizontal: 16),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            withFont(ScootType.button),
          ),
          side: focusSide,
          elevation: const WidgetStatePropertyAll<double>(0),
          backgroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> s,
          ) {
            if (s.contains(WidgetState.disabled)) {
              return c.disabledFill;
            }
            if (s.contains(WidgetState.hovered) ||
                s.contains(WidgetState.pressed)) {
              return c.brandHover;
            }
            return c.brand;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> s,
          ) {
            if (s.contains(WidgetState.disabled)) {
              return c.disabledText;
            }
            return c.onBrand;
          }),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll<Size>(minButton),
          padding: const WidgetStatePropertyAll<EdgeInsets>(
            EdgeInsets.symmetric(horizontal: 16),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            withFont(ScootType.button),
          ),
          side: outlinedSide,
          backgroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> s,
          ) {
            return s.contains(WidgetState.disabled) ? c.disabledFill : c.card;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> s,
          ) {
            if (s.contains(WidgetState.disabled)) {
              return c.disabledText;
            }
            return c.ink;
          }),
          overlayColor: WidgetStatePropertyAll<Color>(c.hair),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll<Size>(minButton),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            withFont(ScootType.button),
          ),
          side: focusSide,
          foregroundColor: WidgetStatePropertyAll<Color>(c.brandText),
          overlayColor: WidgetStatePropertyAll<Color>(c.brandTint),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll<Size>(minIcon),
          fixedSize: WidgetStatePropertyAll<Size>(minIcon),
          iconSize: WidgetStatePropertyAll<double>(
            surface == ScootSurface.phone
                ? ScootSize.phoneIcon
                : ScootSize.icon,
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          side: focusSide,
          foregroundColor: WidgetStatePropertyAll<Color>(c.text2),
          overlayColor: WidgetStatePropertyAll<Color>(c.hair),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.card,
        selectedColor: c.brandTint,
        disabledColor: c.disabledFill,
        checkmarkColor: c.brandText,
        side: BorderSide(color: c.line2),
        labelStyle: withFont(ScootType.small).copyWith(
          color: WidgetStateColor.resolveWith(
            (Set<WidgetState> s) =>
                s.contains(WidgetState.selected) ? c.brandText : c.text2,
          ),
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: withFont(
          ScootType.small,
        ).copyWith(color: c.brandText, fontWeight: FontWeight.w600),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: ScootRadius.cardAll),
        titleTextStyle: withFont(ScootType.h2).copyWith(color: c.ink),
        contentTextStyle: withFont(ScootType.body).copyWith(color: c.text2),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.card,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: c.line2,
        dragHandleSize: const Size(36, 4),
        shape: const RoundedRectangleBorder(borderRadius: ScootRadius.sheetTop),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.card,
        surfaceTintColor: Colors.transparent,
        shadowColor: c.ink.withValues(alpha: 0.12),
        textStyle: withFont(ScootType.body).copyWith(color: c.ink),
        shape: RoundedRectangleBorder(
          borderRadius: ScootRadius.noteAll,
          side: BorderSide(color: c.line),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(c.card),
          surfaceTintColor: const WidgetStatePropertyAll<Color>(
            Colors.transparent,
          ),
          shadowColor: WidgetStatePropertyAll<Color>(
            c.ink.withValues(alpha: 0.12),
          ),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: c.line)),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: ScootRadius.noteAll),
          ),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll<Size>(Size(160, target)),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            withFont(ScootType.body).copyWith(color: c.ink),
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: c.line,
        labelColor: c.ink,
        unselectedLabelColor: c.text2,
        indicatorColor: c.brand,
        labelStyle: withFont(ScootType.bodyStrong),
        unselectedLabelStyle: withFont(ScootType.body),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.isDark ? c.tableHead : ScootPalette.ink,
          borderRadius: ScootRadius.controlAll,
        ),
        textStyle: withFont(
          ScootType.small,
        ).copyWith(color: const Color(0xFFFFFFFF)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.isDark ? c.tableHead : ScootPalette.ink,
        contentTextStyle: withFont(
          ScootType.body,
        ).copyWith(color: const Color(0xFFFFFFFF)),
        actionTextColor: const Color(0xFF9DE3B9),
        shape: const RoundedRectangleBorder(
          borderRadius: ScootRadius.controlAll,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.brand,
        linearTrackColor: c.hair,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) {
          return s.contains(WidgetState.selected) ? c.brand : c.line2;
        }),
        thumbColor: const WidgetStatePropertyAll<Color>(Color(0xFFFFFFFF)),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) {
          return s.contains(WidgetState.selected) ? c.brand : null;
        }),
        side: BorderSide(color: c.muted, width: 1.5),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll<Color>(c.tableHead),
        headingTextStyle: withFont(
          ScootType.tableHead,
        ).copyWith(color: c.tableHeadText),
        dataTextStyle: withFont(ScootType.body).copyWith(color: c.ink),
        dividerThickness: 1,
      ),
    );
  }
}
