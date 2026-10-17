import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository;

class _DisplayRepository extends GatedRepository {
  _DisplayRepository(super.inner);

  Future<void> Function(String key)? beforeSettingRead;

  @override
  Future<String?> getSetting(String key) async {
    await beforeSettingRead?.call(key);
    return super.getSetting(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late TamayuraRepository db;
  late _DisplayRepository repository;
  late TransferStore tasks;
  late FakeBridge bridge;
  late AppController model;
  late Directory temporary;

  AppController createController() => AppController(
    bridge: bridge,
    preferredPort: 0,
    openRepository: () async => repository,
    openTransfers: () async => tasks,
  )..setForeground(false);

  setUp(() async {
    db = await TamayuraRepository.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repository = _DisplayRepository(db);
    temporary = await Directory.systemTemp.createTemp(
      'tamayura-album-display-',
    );
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: databaseFactoryFfi,
    );
    bridge = FakeBridge();
    model = createController();
  });

  tearDown(() async {
    await model.shutdown();
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  test(
    'first launch uses the compact default without writing a preference',
    () async {
      expect(model.albumDetailedMode, isFalse);
      expect(model.albumDetailedModeSaving, isFalse);

      await model.initialize();

      expect(model.albumDetailedMode, isFalse);
      expect(model.albumDetailedModeSaving, isFalse);
      expect(await db.getSetting('albumDetailedMode'), isNull);
      expect(model.error, isNull);
    },
  );

  for (final saved in ['true', 'false', '', 'invalid']) {
    test('initialization restores the album preference "$saved"', () async {
      await db.setSetting('albumDetailedMode', saved);
      await model.initialize();

      expect(model.albumDetailedMode, saved == 'true');
      expect(model.albumDetailedModeSaving, isFalse);
      expect(model.error, isNull);
    });
  }

  test('both display modes persist across application restarts', () async {
    await db.close();
    final path = '${temporary.path}/album.db';
    db = await TamayuraRepository.open(path: path, factory: databaseFactoryFfi);
    repository = _DisplayRepository(db);
    await model.initialize();

    for (final enabled in [true, false]) {
      await model.setAlbumDetailedMode(enabled);
      expect(model.albumDetailedMode, enabled);
      expect(await db.getSetting('albumDetailedMode'), enabled.toString());
      expect(model.albumDetailedModeSaving, isFalse);
      await model.shutdown();

      db = await TamayuraRepository.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      repository = _DisplayRepository(db);
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      model = createController();
      await model.initialize();
      expect(model.albumDetailedMode, enabled);
      expect(model.error, isNull);
    }
  });

  test('reselecting the saved mode does not write or notify', () async {
    await model.initialize();
    var writes = 0;
    var notifications = 0;
    repository.beforeSettingWrite = (_, _) async => writes++;
    model.addListener(() => notifications++);

    await model.setAlbumDetailedMode(false);

    expect(writes, 0);
    expect(notifications, 0);
    expect(model.albumDetailedModeSaving, isFalse);
  });

  test(
    'failed saves retain the mode and notify before a successful retry',
    () async {
      await db.setSetting('albumDetailedMode', 'true');
      await model.initialize();
      repository.beforeSettingWrite = (key, value) async {
        if (key == 'albumDetailedMode') throw StateError('write failed');
      };
      final observed = <(bool, bool, String?)>[];
      model.addListener(() {
        observed.add((
          model.albumDetailedMode,
          model.albumDetailedModeSaving,
          model.error,
        ));
      });

      await model.setAlbumDetailedMode(false);

      expect(model.albumDetailedMode, isTrue);
      expect(await db.getSetting('albumDetailedMode'), 'true');
      expect(model.albumDetailedModeSaving, isFalse);
      expect(model.error, '相册详细模式设置保存失败，请重试');
      expect(
        observed,
        containsAllInOrder([
          (true, true, null),
          (true, false, '相册详细模式设置保存失败，请重试'),
        ]),
      );

      repository.beforeSettingWrite = null;
      await model.setAlbumDetailedMode(false);
      expect(model.albumDetailedMode, isFalse);
      expect(await db.getSetting('albumDetailedMode'), 'false');
      expect(model.error, isNull);
    },
  );

  test(
    'pending saves retain the old mode and prevent overlapping writes',
    () async {
      await model.initialize();
      final entered = Completer<void>();
      final release = Completer<void>();
      final observed = <(bool, bool)>[];
      var writes = 0;
      repository.beforeSettingWrite = (key, value) async {
        if (key != 'albumDetailedMode') return;
        writes++;
        entered.complete();
        await release.future;
      };
      model.addListener(() {
        observed.add((model.albumDetailedMode, model.albumDetailedModeSaving));
      });
      final saving = model.setAlbumDetailedMode(true);
      try {
        await entered.future;
        expect(model.albumDetailedMode, isFalse);
        expect(model.albumDetailedModeSaving, isTrue);
        expect(model.busy, isFalse);
        await model.setAlbumDetailedMode(true);
        await model.setAlbumDetailedMode(false);
        expect(writes, 1);
      } finally {
        release.complete();
        await saving;
      }

      expect(model.albumDetailedMode, isTrue);
      expect(model.albumDetailedModeSaving, isFalse);
      expect(await db.getSetting('albumDetailedMode'), 'true');
      expect(observed, containsAllInOrder([(false, true), (true, false)]));
    },
  );

  test(
    'changing mode before initialization reports a recoverable error',
    () async {
      await model.setAlbumDetailedMode(true);
      expect(model.albumDetailedMode, isFalse);
      expect(model.albumDetailedModeSaving, isFalse);
      expect(model.error, '应用尚未完成初始化，请稍后重试');

      await model.initialize();
      await model.setAlbumDetailedMode(true);
      expect(model.albumDetailedMode, isTrue);
      expect(model.error, isNull);
    },
  );

  test(
    'a failed preference read can be retried without losing the saved mode',
    () async {
      await db.setSetting('albumDetailedMode', 'true');
      repository.beforeSettingRead = (key) async {
        if (key == 'albumDetailedMode') throw StateError('read failed');
      };
      await model.initialize();
      expect(model.albumDetailedMode, isFalse);
      expect(model.loading, isFalse);
      expect(model.error, isNotNull);
      await model.setAlbumDetailedMode(true);
      expect(model.albumDetailedMode, isFalse);
      expect(model.error, '应用尚未完成初始化，请稍后重试');
      expect(await db.getSetting('albumDetailedMode'), 'true');

      repository.beforeSettingRead = null;
      await model.initialize();
      expect(model.albumDetailedMode, isTrue);
      expect(model.error, isNull);
    },
  );

  test(
    'a save that finishes after disposal does not notify or change the mode',
    () async {
      await model.initialize();
      final entered = Completer<void>();
      final release = Completer<void>();
      var notifications = 0;
      var writes = 0;
      repository.beforeSettingWrite = (key, value) async {
        if (key != 'albumDetailedMode') return;
        writes++;
        entered.complete();
        await release.future;
      };
      model.addListener(() => notifications++);
      final saving = model.setAlbumDetailedMode(true);
      await entered.future;
      model.dispose();
      final countAtDisposal = notifications;
      release.complete();
      await saving;
      await model.setAlbumDetailedMode(true);

      expect(model.albumDetailedMode, isFalse);
      expect(model.albumDetailedModeSaving, isFalse);
      expect(model.error, isNull);
      expect(notifications, countAtDisposal);
      expect(writes, 1);
    },
  );
}
