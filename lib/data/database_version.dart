import 'package:sqflite/sqflite.dart';

import '../l10n/app_locale.dart';

/// An unsupported schema must never be reset or marked as a supported version.
/// Add explicit, transactional migrations when a future release needs them.
void rejectUnsupportedDatabaseVersion(
  Database database,
  int oldVersion,
  int newVersion,
) {
  throw FormatException(AppLocale.strings.errorDatabaseVersionUnsupported);
}
