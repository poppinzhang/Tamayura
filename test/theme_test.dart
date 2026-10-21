import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/ui/app_theme.dart';

double _contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return first > second
      ? (first + .05) / (second + .05)
      : (second + .05) / (first + .05);
}

void main() {
  for (final entry in {
    Brightness.light: AppTheme.light,
    Brightness.dark: AppTheme.dark,
  }.entries) {
    final brightness = entry.key;
    final theme = entry.value;
    final colors = theme.colorScheme;

    test('$brightness uses neutral surfaces and readable text', () {
      expect(theme.useMaterial3, isTrue);
      expect(theme.iconButtonTheme.variant, StyleVariant.material3);
      expect(theme.brightness, brightness);
      expect(theme.scaffoldBackgroundColor, colors.surface);
      for (final surface in [
        colors.surface,
        colors.surfaceContainerLow,
        colors.surfaceContainerHighest,
        colors.primaryContainer,
        colors.secondaryContainer,
      ]) {
        expect(surface.r, surface.g, reason: 'Surfaces should have no hue');
        expect(surface.g, surface.b, reason: 'Surfaces should have no hue');
        expect(_contrast(colors.onSurface, surface), greaterThanOrEqualTo(4.5));
        expect(
          _contrast(colors.onSurfaceVariant, surface),
          greaterThanOrEqualTo(4.5),
          reason: 'Secondary labels must remain readable on raised surfaces',
        );
      }
      for (final pair in [
        (colors.onPrimary, colors.primary),
        (colors.onPrimaryContainer, colors.primaryContainer),
        (colors.onSecondaryContainer, colors.secondaryContainer),
        (colors.onErrorContainer, colors.errorContainer),
        (colors.onInverseSurface, colors.inverseSurface),
      ]) {
        expect(_contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
      }
    });

    test('$brightness uses legible Android system bar icons', () {
      final overlay = theme.appBarTheme.systemOverlayStyle!;
      final iconBrightness = brightness == Brightness.dark
          ? Brightness.light
          : Brightness.dark;
      expect(overlay.statusBarIconBrightness, iconBrightness);
      expect(overlay.systemNavigationBarIconBrightness, iconBrightness);
      expect(overlay.statusBarColor, Colors.transparent);
      expect(overlay.systemNavigationBarColor, Colors.transparent);
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
      expect(theme.navigationBarTheme.surfaceTintColor, Colors.transparent);
    });
  }
}
