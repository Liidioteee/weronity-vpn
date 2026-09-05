import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds the Material 3 dark and light themes from [WColors] tokens.
abstract final class AppTheme {
  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        bg: WColors.bgDark,
        surface: WColors.surfaceDark,
        surfaceHigh: WColors.surfaceHighDark,
        surfaceInk: WColors.surfaceInkDark,
        outline: WColors.outlineDark,
        text: WColors.textDark,
        textMuted: WColors.textMutedDark,
      );

  static ThemeData get light => _build(
        brightness: Brightness.light,
        bg: WColors.bgLight,
        surface: WColors.surfaceLight,
        surfaceHigh: WColors.surfaceHighLight,
        surfaceInk: WColors.surfaceInkLight,
        outline: WColors.outlineLight,
        text: WColors.textLight,
        textMuted: WColors.textMutedLight,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color surfaceHigh,
    required Color surfaceInk,
    required Color outline,
    required Color text,
    required Color textMuted,
  }) {
    const fontFamily = 'Inter';
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: WColors.violet,
      onPrimary: isDark ? WColors.bgDark : Colors.white,
      primaryContainer: WColors.violetDeep,
      onPrimaryContainer: Colors.white,
      secondary: WColors.info,
      onSecondary: Colors.black,
      tertiary: WColors.protected,
      onTertiary: Colors.black,
      error: WColors.danger,
      onError: Colors.black,
      surface: surface,
      onSurface: text,
      onSurfaceVariant: textMuted,
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surfaceHigh,
      surfaceContainerHigh: surfaceInk,
      surfaceContainerHighest: surfaceInk,
      outline: outline,
      outlineVariant: outline,
    );

    final baseText = (isDark
            ? ThemeData.dark().textTheme
            : ThemeData.light().textTheme)
        .apply(
      fontFamily: fontFamily,
      bodyColor: text,
      displayColor: text,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      textTheme: baseText.copyWith(
        headlineMedium: baseText.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: WRadius.card,
          side: BorderSide(color: outline),
        ),
      ),
      dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceHigh,
        selectedColor: WColors.violetDeep,
        side: BorderSide(color: outline),
        labelStyle: baseText.labelMedium?.copyWith(color: text),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: WSpace.md, vertical: WSpace.xs),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WRadius.md)),
          textStyle: baseText.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: outline),
          foregroundColor: text,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WRadius.md)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: WSpace.lg, vertical: WSpace.xs),
        shape: const RoundedRectangleBorder(borderRadius: WRadius.card),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: WColors.violetGlow,
        elevation: 0,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? WColors.violetBright : textMuted,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? WColors.violetDeep
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Colors.white : text,
          ),
          side: WidgetStateProperty.all(BorderSide(color: outline)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? WColors.violet : textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? WColors.violetDeep : surfaceInk,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceInk,
        contentTextStyle: baseText.bodyMedium?.copyWith(color: text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WRadius.md)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: WRadius.sheet),
        showDragHandle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WRadius.md),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WRadius.md),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WRadius.md),
          borderSide: const BorderSide(color: WColors.violet, width: 1.5),
        ),
      ),
    );
  }
}
