import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/endpoint.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/update/update_service.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository;
import 'flutter_test_config.dart' show testSystemLocales;

class _LanguageBridge extends FakeBridge {
  final languages = <String>[];
  Object? languageFailure;

  @override
  Future<void> setLanguage(String language) async {
    languages.add(language);
    if (languageFailure != null) throw languageFailure!;
  }
}

Map<String, dynamic> _catalog(String language) =>
    jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
        as Map<String, dynamic>;

Map<String, String> _messages(Map<String, dynamic> catalog) => {
  for (final entry in catalog.entries)
    if (!entry.key.startsWith('@')) entry.key: entry.value as String,
};

void main() {
  group('language resolution', () {
    for (final (preferred, expected) in [
      (const [Locale('zh', 'CN')], 'zh'),
      (
        const [Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')],
        'zh',
      ),
      (const [Locale('zh', 'TW'), Locale('en')], 'zh'),
      (const [Locale('ja', 'JP')], 'ja'),
      (const [Locale('en', 'GB')], 'en'),
      (const [Locale('fr', 'FR'), Locale('ja')], 'ja'),
      (const [Locale('fr', 'FR'), Locale('de')], 'en'),
      (const <Locale>[], 'en'),
    ]) {
      test('system preference $preferred uses $expected', () {
        expect(
          resolveAppLocale(AppLanguage.system, preferred),
          Locale(expected),
        );
      });
    }

    test('a chosen language ignores the system languages', () {
      for (final language in [AppLanguage.zh, AppLanguage.ja, AppLanguage.en]) {
        expect(
          resolveAppLocale(language, const [Locale('fr'), Locale('ja')]),
          Locale(language.name),
        );
      }
    });

    test('stored values parse strictly and default to the system', () {
      for (final language in AppLanguage.values) {
        expect(AppLanguage.parse(language.name), language);
      }
      for (final invalid in [null, '', 'ZH', 'zh-CN', 'fr']) {
        expect(AppLanguage.parse(invalid), AppLanguage.system);
      }
    });

    test('every language offers its own readable name', () {
      expect(AppLanguage.zh.nativeName, '简体中文');
      expect(AppLanguage.ja.nativeName, '日本語');
      expect(AppLanguage.en.nativeName, 'English');
    });

    test('service text follows the language and the system list', () {
      expect(AppLocale.strings.navSettings, '设置');
      AppLocale.language = AppLanguage.ja;
      expect(AppLocale.strings.navSettings, '設定');
      AppLocale.language = AppLanguage.system;
      AppLocale.systemLocales = () => const [Locale('de'), Locale('en')];
      expect(AppLocale.current, const Locale('en'));
      expect(AppLocale.strings.navSettings, 'Settings');
    });

    test('generated localizations support exactly the offered languages', () {
      expect(
        AppLocalizations.supportedLocales.map((locale) => locale.languageCode),
        unorderedEquals(['zh', 'ja', 'en']),
      );
    });
  });

  group('translation catalogs', () {
    final template = _catalog('zh');
    final source = _messages(template);

    for (final language in ['ja', 'en']) {
      final messages = _messages(_catalog(language));

      test('$language translates every message', () {
        expect(messages.keys.toSet(), source.keys.toSet());
      });

      test('$language keeps every placeholder', () {
        for (final key in source.keys) {
          final metadata = template['@$key'] as Map<String, dynamic>?;
          final placeholders =
              (metadata?['placeholders'] as Map<String, dynamic>?)?.keys ??
              const <String>[];
          for (final name in placeholders) {
            expect(
              messages[key]!.contains('{$name}') ||
                  messages[key]!.contains('{$name,'),
              isTrue,
              reason: '$language $key misses {$name}',
            );
          }
        }
      });
    }

    test('English contains no Chinese text', () {
      for (final MapEntry(:key, :value) in _messages(_catalog('en')).entries) {
        expect(value, isNot(matches(RegExp(r'[一-鿿]'))), reason: key);
      }
    });

    test('Japanese contains no Simplified-only characters', () {
      const simplified =
          '们这个设载传请时对为选择启图册务复储览级网络连进还让读说认识变发现开关间隐删'
          '绝继续页项码扫视频线态档录无输问题该么显广岛县';
      for (final MapEntry(:key, :value) in _messages(_catalog('ja')).entries) {
        for (final character in simplified.split('')) {
          expect(
            value.contains(character),
            isFalse,
            reason: '$key: $character',
          );
        }
      }
    });
  });

  group('service messages', () {
    test('error descriptions use the interface language', () {
      AppLocale.language = AppLanguage.en;
      expect(
        describeError(GrpcError.notFound()),
        'The file was deleted or can\'t be accessed on the other device. '
        'Refresh the album.',
      );
      expect(
        describeError(const SocketException('offline')),
        'Can\'t connect to the local network. Check Wi-Fi and try again.',
      );
      AppLocale.language = AppLanguage.ja;
      expect(
        describeError(GrpcError.dataLoss()),
        'ファイルが完全に転送されませんでした。もう一度お試しください',
      );
    });

    test('shared platform codes read the same on every platform', () {
      for (final message in [
        '共享目录不能重复或互相包含',
        'Shared directories cannot repeat or contain each other',
      ]) {
        final error = PlatformException(code: 'DIR_OVERLAP', message: message);
        expect(describeError(error), '此目录已共享，或与现有共享目录存在父子关系');
        AppLocale.language = AppLanguage.en;
        expect(
          describeError(error),
          'This folder is already shared, or it contains or is inside a '
          'shared folder.',
        );
        AppLocale.language = AppLanguage.system;
      }
      AppLocale.language = AppLanguage.ja;
      expect(
        describeError(
          PlatformException(code: 'FILE_CHANGED', message: 'Media changed'),
        ),
        'ファイルのサイズが変わりました。アルバムを更新してください',
      );
      expect(
        describeError(
          PlatformException(code: 'SCAN_CANCELLED', message: 'scan again'),
        ),
        '共有フォルダーが変更されました。もう一度スキャンしてください',
      );
      // Other codes keep the platform's own localized message.
      expect(
        describeError(
          PlatformException(code: 'PERMISSION_LOST', message: '権限がありません'),
        ),
        '権限がありません',
      );
    });

    test('address validation explains errors in the interface language', () {
      AppLocale.language = AppLanguage.en;
      expect(
        () => LanEndpoint.parse('not an address'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Enter a local IPv4 address, or scan a Tamayura QR code.',
          ),
        ),
      );
      AppLocale.language = AppLanguage.ja;
      expect(
        () => LanEndpoint.parse('8.8.8.8'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '現在はローカルネットワークのプライベート IPv4 アドレスのみに対応しています',
          ),
        ),
      );
    });

    test('a shared cancellation reads in the current language', () {
      const cancelled = UpdateCancelledException();
      expect(cancelled, isA<UpdateException>());
      expect(cancelled.message, '已取消更新下载');
      AppLocale.language = AppLanguage.en;
      expect(cancelled.message, 'Update download cancelled');
      expect('$cancelled', 'Update download cancelled');
      expect(
        '${const SnapshotConflictException()}',
        'The media catalog was '
            'updated. Sync again.',
      );
    });

    test(
      'stored task messages use the language at the time of writing',
      () async {
        sqfliteFfiInit();
        final directory = await Directory.systemTemp.createTemp(
          'tamayura-l10n-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = await TransferStore.open(
          path: '${directory.path}/tasks.db',
          factory: databaseFactoryFfi,
        );
        addTearDown(store.close);
        final task = await store.enqueue(
          const Peer(id: 'peer', name: 'Peer', host: '192.168.1.9', port: 1),
          MediaItem(
            id: 'photo',
            deviceId: 'peer',
            name: 'photo.jpg',
            sharedFolderId: 'camera',
            sharedFolderName: 'Camera',
            relativePath: 'photo.jpg',
            mimeType: 'image/jpeg',
            size: 3,
            modifiedMs: 1,
            thumbnail: Uint8List(0),
          ),
          'content://receive',
        );
        AppLocale.language = AppLanguage.en;
        await store.reconcile(const {});
        expect(
          (await store.get(task.id))!.error,
          'The task was interrupted. Tap retry to continue downloading.',
        );
      },
    );
  });

  group('language preference', () {
    late TamayuraRepository db;
    late GatedRepository repository;
    late TransferStore tasks;
    late _LanguageBridge bridge;
    late AppController model;
    late Directory temporary;

    AppController createController() => AppController(
      bridge: bridge,
      preferredPort: 0,
      openRepository: () async => repository,
      openTransfers: () async => tasks,
    )..setForeground(false);

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      db = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      repository = GatedRepository(db);
      temporary = await Directory.systemTemp.createTemp('tamayura-language-');
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      bridge = _LanguageBridge();
      model = createController();
    });

    tearDown(() async {
      await model.shutdown();
      await bridge.events.close();
      // The fixture opens these even when the controller never initializes.
      await tasks.close();
      await db.close();
      await temporary.delete(recursive: true);
    });

    test('first launch follows the system without saving a choice', () async {
      expect(model.language, AppLanguage.system);
      await model.initialize();
      expect(model.language, AppLanguage.system);
      expect(model.locale, const Locale('zh'));
      expect(model.languageSaving, isFalse);
      expect(await db.getSetting('language'), isNull);
      expect(bridge.languages, ['system']);
    });

    for (final language in AppLanguage.values) {
      test(
        'initialization restores the saved ${language.name} language',
        () async {
          await db.setSetting('language', language.name);
          await model.initialize();
          expect(model.language, language);
          expect(AppLocale.language, language);
          expect(bridge.languages, [language.name]);
          expect(model.error, isNull);
        },
      );
    }

    for (final invalid in ['', 'fr', 'zh-CN']) {
      test('invalid language "$invalid" follows the system', () async {
        await db.setSetting('language', invalid);
        await model.initialize();
        expect(model.language, AppLanguage.system);
        expect(model.locale, const Locale('zh'));
      });
    }

    test(
      'a chosen language is saved, sent to the platform and used for messages',
      () async {
        await model.initialize();
        var notifications = 0;
        model.addListener(() => notifications++);
        await model.setLanguage(AppLanguage.en);
        expect(model.language, AppLanguage.en);
        expect(model.locale, const Locale('en'));
        expect(AppLocale.language, AppLanguage.en);
        expect(await db.getSetting('language'), 'en');
        expect(bridge.languages.last, 'en');
        expect(notifications, greaterThan(0));
        await model.setAutoSyncIntervalMinutes(0);
        expect(
          model.error,
          'Enter a whole number of minutes from 1 to 525600 for the auto sync '
          'interval.',
        );
        await model.setLanguage(AppLanguage.ja);
        await model.setAutoSyncIntervalMinutes(0);
        expect(model.error, '自動同期の間隔は 1–525600 の整数（分）で入力してください');
        await model.setLanguage(AppLanguage.system);
        expect(model.locale, const Locale('zh'));
        expect(await db.getSetting('language'), 'system');
        expect(bridge.languages, ['system', 'en', 'ja', 'system']);
      },
    );

    test('choosing the current language writes nothing', () async {
      await db.setSetting('language', 'ja');
      await model.initialize();
      var writes = 0;
      repository.beforeSettingWrite = (key, value) async => writes++;
      await model.setLanguage(AppLanguage.ja);
      expect(writes, 0);
      expect(bridge.languages, ['ja']);
    });

    test(
      'the saved language survives reopening the application stores',
      () async {
        await db.close();
        final path = '${temporary.path}/language.db';
        db = await TamayuraRepository.open(
          path: path,
          factory: databaseFactoryFfi,
        );
        repository = GatedRepository(db);
        model = createController();
        await model.initialize();
        await model.setLanguage(AppLanguage.ja);
        await model.shutdown();
        db = await TamayuraRepository.open(
          path: path,
          factory: databaseFactoryFfi,
        );
        repository = GatedRepository(db);
        tasks = await TransferStore.open(
          path: '${temporary.path}/tasks.db',
          factory: databaseFactoryFfi,
        );
        AppLocale.language = AppLanguage.system;
        model = createController();
        await model.initialize();
        expect(model.language, AppLanguage.ja);
        expect(model.locale, const Locale('ja'));
      },
    );

    test('a failed write keeps the previous language and can retry', () async {
      await db.setSetting('language', 'en');
      await model.initialize();
      repository.beforeSettingWrite = (key, value) async {
        throw StateError('disk write failed');
      };
      await model.setLanguage(AppLanguage.ja);
      expect(model.language, AppLanguage.en);
      expect(model.languageSaving, isFalse);
      expect(await db.getSetting('language'), 'en');
      expect(model.error, 'Couldn\'t save the language. Please try again.');
      expect(bridge.languages, ['en']);
      repository.beforeSettingWrite = null;
      await model.setLanguage(AppLanguage.ja);
      expect(model.language, AppLanguage.ja);
      expect(model.error, isNull);
    });

    test('a pending write blocks overlapping changes', () async {
      await model.initialize();
      final release = Completer<void>();
      repository.beforeSettingWrite = (key, value) => release.future;
      final saving = model.setLanguage(AppLanguage.en);
      expect(model.languageSaving, isTrue);
      await model.setLanguage(AppLanguage.ja);
      release.complete();
      await saving;
      expect(model.language, AppLanguage.en);
      expect(await db.getSetting('language'), 'en');
      expect(model.languageSaving, isFalse);
    });

    test('changing languages before initialization explains why', () async {
      await model.setLanguage(AppLanguage.en);
      expect(model.language, AppLanguage.system);
      expect(model.error, '应用尚未完成初始化，请稍后重试');
    });

    test(
      'platform failures do not block startup or language changes',
      () async {
        bridge.languageFailure = MissingPluginException();
        await model.initialize();
        expect(model.error, isNull);
        bridge.languageFailure = PlatformException(code: 'FAILED');
        await model.setLanguage(AppLanguage.en);
        expect(model.language, AppLanguage.en);
        expect(model.error, isNull);
      },
    );

    test(
      'system language changes apply only while following the system',
      () async {
        await model.initialize();
        var notifications = 0;
        model.addListener(() => notifications++);
        AppLocale.systemLocales = () => const [Locale('ja', 'JP')];
        model.systemLocalesChanged();
        expect(model.locale, const Locale('ja'));
        expect(notifications, 1);
        expect(bridge.languages, ['system', 'system']);
        await model.setLanguage(AppLanguage.en);
        notifications = 0;
        AppLocale.systemLocales = () => testSystemLocales;
        model.systemLocalesChanged();
        expect(notifications, 0);
        expect(model.locale, const Locale('en'));
      },
    );

    test(
      'the local device has a localized name until the system reports one',
      () {
        expect(model.deviceName, '我的设备');
        AppLocale.systemLocales = () => const [Locale('en')];
        expect(model.deviceName, 'My device');
      },
    );
  });
}
