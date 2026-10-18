import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/l10n/app_locale.dart';

/// Suites assert the Simplified Chinese source text unless a test selects
/// another language, independent of the host's language settings.
const testSystemLocales = [Locale('zh', 'CN')];

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    AppLocale.language = AppLanguage.system;
    AppLocale.systemLocales = () => testSystemLocales;
  });
  await testMain();
}
