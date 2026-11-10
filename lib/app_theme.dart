import 'package:flutter/material.dart';

import 'widgets/pattern_background.dart';

/// Brand colours, taken from the app logo.
class BrandColors {
  static const navy = Color(0xFF0A1033);
  static const indigo = Color(0xFF2B3A9E);
  static const cyan = Color(0xFF22C3EE);
}

/// The app-wide light / dark theme (indigo brand, calm neutral surfaces).
class AppTheme {
  /// [patterned]: every page gets the doodle wallpaper (widgets/pattern_background.dart).
  /// Only the main app; the quick-download panel floats over other apps and stays plain.
  static ThemeData light({bool patterned = false}) => _build(Brightness.light, patterned);
  static ThemeData dark({bool patterned = false}) => _build(Brightness.dark, patterned);

  static ThemeData _build(Brightness brightness, bool patterned) {
    final scheme = ColorScheme.fromSeed(
      seedColor: BrandColors.indigo,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    return base.copyWith(
      // Patterned: pages are see-through so the wallpaper painted under each route shows.
      scaffoldBackgroundColor: patterned ? Colors.transparent : null,
      pageTransitionsTheme: patterned
          ? PageTransitionsTheme(builders: {
              for (final e in const PageTransitionsTheme().builders.entries)
                e.key: PatternedPageTransitionsBuilder(e.value),
            })
          : null,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
            )),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}
