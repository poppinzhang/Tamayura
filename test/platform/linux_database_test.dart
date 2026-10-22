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
  const methods = MethodChannel('test/linux/database');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test(
    'Linux databases use the XDG data directory instead of the bundle',
    () async {
      final factory = _Factory();
      const directory = '/home/用户/.local/share/tamayura/databases';
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'databaseDirectory');
        return directory;
      });
      expect(
        await configureLinuxDatabase(methods: methods, factory: factory),
        same(factory),
      );
      expect(factory.path, directory);
    },
  );

  test(
    'missing, relative or Windows paths fail without writing elsewhere',
    () async {
      for (final path in [
        null,
        '',
        'databases',
        '~/.local/share',
        r'C:\Users\a\databases',
      ]) {
        final factory = _Factory();
        messenger.setMockMethodCallHandler(methods, (_) async => path);
        await expectLater(
          configureLinuxDatabase(methods: methods, factory: factory),
          throwsA(isA<PlatformException>()),
        );
        expect(factory.path, isNull);
      }
    },
  );

  test('native storage failures propagate for the retry UI', () async {
    messenger.setMockMethodCallHandler(methods, (_) async {
      throw PlatformException(
        code: 'STAGING_UNAVAILABLE',
        message: '无法准备应用数据目录',
      );
    });
    await expectLater(
      configureLinuxDatabase(methods: methods, factory: _Factory()),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'STAGING_UNAVAILABLE',
        ),
      ),
    );
  });
}
