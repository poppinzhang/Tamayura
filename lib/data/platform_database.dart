import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../l10n/app_locale.dart';

/// sqflite's mobile/Darwin plugin has no Windows implementation. Both databases
/// use the same FFI factory and a writable per-user directory on Windows.
Future<DatabaseFactory> platformDatabaseFactory() async {
  if (!Platform.isWindows) return databaseFactory;
  sqfliteFfiInit();
  return configureWindowsDatabase();
}

Future<DatabaseFactory> configureWindowsDatabase({
  MethodChannel methods = const MethodChannel('tamayura/platform'),
  DatabaseFactory? factory,
}) async {
  final directory = await methods.invokeMethod<String>('databaseDirectory');
  if (directory == null || !p.windows.isAbsolute(directory)) {
    throw PlatformException(
      code: 'DATABASE_UNAVAILABLE',
      message: AppLocale.strings.errorDatabaseDirectory,
    );
  }
  final selected = factory ?? databaseFactoryFfi;
  await selected.setDatabasesPath(directory);
  return selected;
}
