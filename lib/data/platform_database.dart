import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../l10n/app_locale.dart';

/// sqflite's mobile/Darwin plugin has no Windows or Linux implementation.
/// Both databases use the same FFI factory with the bundled SQLite and a
/// writable per-user directory chosen by the native layer.
Future<DatabaseFactory> platformDatabaseFactory() async {
  if (Platform.isWindows) {
    sqfliteFfiInit();
    return configureWindowsDatabase();
  }
  if (Platform.isLinux) {
    sqfliteFfiInit();
    return configureLinuxDatabase();
  }
  return databaseFactory;
}

Future<DatabaseFactory> configureWindowsDatabase({
  MethodChannel methods = const MethodChannel('tamayura/platform'),
  DatabaseFactory? factory,
}) => _configureDatabase(p.windows, methods, factory);

/// Linux stores databases below $XDG_DATA_HOME/tamayura/databases.
Future<DatabaseFactory> configureLinuxDatabase({
  MethodChannel methods = const MethodChannel('tamayura/platform'),
  DatabaseFactory? factory,
}) => _configureDatabase(p.posix, methods, factory);

Future<DatabaseFactory> _configureDatabase(
  p.Context paths,
  MethodChannel methods,
  DatabaseFactory? factory,
) async {
  final directory = await methods.invokeMethod<String>('databaseDirectory');
  if (directory == null || !paths.isAbsolute(directory)) {
    throw PlatformException(
      code: 'DATABASE_UNAVAILABLE',
      message: AppLocale.strings.errorDatabaseDirectory,
    );
  }
  final selected = factory ?? databaseFactoryFfi;
  await selected.setDatabasesPath(directory);
  return selected;
}
