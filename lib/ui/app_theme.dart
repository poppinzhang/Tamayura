import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_icons.dart';
import 'app_motion.dart';

/// Neutral surfaces and monochrome actions, inspired by ChatGPT on Android.
/// These are Tamayura's own tokens, not an exact copy of a third-party palette.
abstract final class AppTheme {
  static final light = _build(_lightColors);
  static final dark = _build(_darkColors);

  // Material's Linux text theme falls back to these Latin families only.
  static const _linuxLatin = [
    'Ubuntu',
    'Adwaita Sans',
    'Cantarell',
    'DejaVu Sans',
    'Liberation Sans',
    'Arial',
  ];
  static const _linuxChinese = [
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'Source Han Sans CN',
    'WenQuanYi Micro Hei',
    'WenQuanYi Zen Hei',
    'Droid Sans Fallback',
  ];
  static const _linuxJapanese = [
    'Noto Sans CJK JP',
    'Noto Sans JP',
    'Source Han Sans JP',
    'Source Han Sans',
    'IPAexGothic',
    'IPAGothic',
    'TakaoPGothic',
    'VL Gothic',
  ];
  static const _linuxOther = [
    'Noto Sans CJK TC',
    'Noto Sans CJK HK',
    'Noto Sans CJK KR',
    'Noto Color Emoji',
  ];

  /// Flutter's Linux engine reads font files without fontconfig, so text has
  /// no system fallback beyond the families it names. Chinese, Japanese and
  /// emoji fonts that distributions install are listed after the Latin ones,
  /// with the Han forms of the interface language first.
  static List<String> linuxFontFallback(Locale locale) => [
    ..._linuxLatin,
    if (locale.languageCode == 'ja') ...[
      ..._linuxJapanese,
      ..._linuxChinese,
    ] else ...[
      ..._linuxChinese,
      ..._linuxJapanese,
    ],
    ..._linuxOther,
  ];

  // Per base theme, so rebuilding the app reuses the same theme objects.
  static final _linuxThemes = Expando<Map<bool, ThemeData>>();

  /// [theme] for the interface [locale]; only Linux needs named fallbacks.
  static ThemeData forLocale(ThemeData theme, Locale locale) {
    if (defaultTargetPlatform != TargetPlatform.linux) return theme;
    final japanese = locale.languageCode == 'ja';
    final themes = _linuxThemes[theme] ??= {};
    return themes.putIfAbsent(japanese, () {
      final fallback = linuxFontFallback(locale);
      return theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamilyFallback: fallback),
        primaryTextTheme: theme.primaryTextTheme.apply(
          fontFamilyFallback: fallback,
        ),
      );
    });
  }

  static const _lightColors = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF171717),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFECECEC),
    onPrimaryContainer: Color(0xFF171717),
    secondary: Color(0xFF454545),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFECECEC),
    onSecondaryContainer: Color(0xFF171717),
    tertiary: Color(0xFF454545),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFF1F1F1),
    onTertiaryContainer: Color(0xFF171717),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFCE9E7),
    onErrorContainer: Color(0xFF85221B),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF171717),
    surfaceDim: Color(0xFFE5E5E5),
    surfaceBright: Color(0xFFFFFFFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7F7F7),
    surfaceContainer: Color(0xFFF1F1F1),
    surfaceContainerHigh: Color(0xFFECECEC),
    surfaceContainerHighest: Color(0xFFE5E5E5),
    onSurfaceVariant: Color(0xFF626262),
    outline: Color(0xFF767676),
    outlineVariant: Color(0xFFDEDEDE),
    inverseSurface: Color(0xFF262626),
    onInverseSurface: Color(0xFFF5F5F5),
    inversePrimary: Color(0xFFF5F5F5),
    surfaceTint: Colors.transparent,
  );

  static const _darkColors = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFF5F5F5),
    onPrimary: Color(0xFF171717),
    primaryContainer: Color(0xFF383838),
    onPrimaryContainer: Color(0xFFF5F5F5),
    secondary: Color(0xFFD4D4D4),
    onSecondary: Color(0xFF171717),
    secondaryContainer: Color(0xFF383838),
    onSecondaryContainer: Color(0xFFF5F5F5),
    tertiary: Color(0xFFD4D4D4),
    onTertiary: Color(0xFF171717),
    tertiaryContainer: Color(0xFF2A2A2A),
    onTertiaryContainer: Color(0xFFF5F5F5),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF601410),
    errorContainer: Color(0xFF482321),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: Color(0xFF171717),
    onSurface: Color(0xFFF5F5F5),
    surfaceDim: Color(0xFF121212),
    surfaceBright: Color(0xFF383838),
    surfaceContainerLowest: Color(0xFF121212),
    surfaceContainerLow: Color(0xFF212121),
    surfaceContainer: Color(0xFF262626),
    surfaceContainerHigh: Color(0xFF2F2F2F),
    surfaceContainerHighest: Color(0xFF383838),
    onSurfaceVariant: Color(0xFFB4B4B4),
    outline: Color(0xFF8A8A8A),
    outlineVariant: Color(0xFF424242),
    inverseSurface: Color(0xFFECECEC),
    onInverseSurface: Color(0xFF171717),
    inversePrimary: Color(0xFF171717),
    surfaceTint: Colors.transparent,
  );

  static ThemeData _build(ColorScheme colors) {
    final dark = colors.brightness == Brightness.dark;
    final overlay = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: colors.brightness,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: dark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      canvasColor: colors.surface,
      dividerColor: colors.outlineVariant,
      disabledColor: colors.onSurface.withValues(alpha: .38),
      iconButtonTheme: const IconButtonThemeData(
        variant: StyleVariant.material3,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AppPageTransitionsBuilder(),
          TargetPlatform.iOS: AppPageTransitionsBuilder(),
          TargetPlatform.macOS: AppPageTransitionsBuilder(),
          TargetPlatform.windows: AppPageTransitionsBuilder(),
          TargetPlatform.linux: AppPageTransitionsBuilder(),
          TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
        },
      ),
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) => const Icon(AppIcons.back),
        closeButtonIconBuilder: (_) => const Icon(AppIcons.close),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: overlay,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.secondaryContainer,
        height: 72,
        elevation: 0,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? colors.onSecondaryContainer
                : colors.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? colors.onSurface
                : colors.onSurfaceVariant,
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.outline),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.inverseSurface,
        contentTextStyle: TextStyle(color: colors.onInverseSurface),
        actionTextColor: colors.inversePrimary,
      ),
    );
  }
}
