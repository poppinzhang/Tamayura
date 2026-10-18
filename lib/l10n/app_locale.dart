import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/widgets.dart' show BuildContext;

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

/// The user's display language. [system] follows the platform's preferred
/// languages in order, using the first supported one and English otherwise.
enum AppLanguage {
  system,
  zh,
  ja,
  en;

  /// Parse a stored preference; unknown or missing values follow the system.
  static AppLanguage parse(String? value) => values.firstWhere(
    (language) => language.name == value,
    orElse: () => system,
  );

  /// Each language is offered by its own name, readable in any interface
  /// language. [system] has no fixed name and is labelled by the UI.
  String get nativeName => switch (this) {
    system => '',
    zh => '简体中文',
    ja => '日本語',
    en => 'English',
  };
}

/// Resolve a preference against the platform's ordered preferred locales.
/// All Chinese variants use Simplified Chinese, the only Chinese translation.
Locale resolveAppLocale(AppLanguage language, Iterable<Locale> systemLocales) {
  if (language != AppLanguage.system) return Locale(language.name);
  for (final locale in systemLocales) {
    switch (locale.languageCode) {
      case 'zh' || 'ja' || 'en':
        return Locale(locale.languageCode);
    }
  }
  return const Locale('en');
}

/// Process-wide display language for text produced outside the widget tree,
/// such as errors raised by services and stored task messages. The app
/// controller keeps [language] in sync with the saved preference; widgets
/// read [BuildContext.l10n] so they rebuild when the language changes.
abstract final class AppLocale {
  static AppLanguage language = AppLanguage.system;

  /// The platform's preferred locales, most preferred first.
  static List<Locale> Function() systemLocales = _platformLocales;

  static Locale get current => resolveAppLocale(language, systemLocales());

  static AppLocalizations get strings => lookupAppLocalizations(current);

  static List<Locale> _platformLocales() => PlatformDispatcher.instance.locales;
}

extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
