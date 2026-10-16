import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tamayura/data/platform_database.dart';

class _Factory implements DatabaseFactory {
  String? path;
  @override
  Future<void> setDatabasesPath(String path) async => this.path = path;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('test/windows/database');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test(
    'Windows databases use the native per-user directory instead of the exe directory',
    () async {
      final factory = _Factory();
      const directory = r'C:\Users\照片\AppData\Local\Tamayura\databases';
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'databaseDirectory');
        return directory;
      });
      expect(
        await configureWindowsDatabase(methods: methods, factory: factory),
        same(factory),
      );
      expect(factory.path, directory);
    },
  );

  test(
    'missing or relative database paths fail without silently writing elsewhere',
    () async {
      for (final path in [null, '', 'databases', r'C:relative']) {
        final factory = _Factory();
        messenger.setMockMethodCallHandler(methods, (_) async => path);
        await expectLater(
          configureWindowsDatabase(methods: methods, factory: factory),
          throwsA(isA<PlatformException>()),
        );
        expect(factory.path, isNull);
      }
    },
  );

  test(
    'native storage failures propagate for the initialization retry UI',
    () async {
      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(code: 'PERMISSION_LOST', message: '目录不可访问');
      });
      await expectLater(
        configureWindowsDatabase(methods: methods, factory: _Factory()),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'PERMISSION_LOST',
          ),
        ),
      );
    },
  );
}
