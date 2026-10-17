import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/core/transfer_task.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/platform/android_bridge.dart';
import 'package:tamayura/platform/macos_bridge.dart';
import 'package:tamayura/platform/windows_bridge.dart';

import 'controller_test.dart' show FakeBridge;

const _peer = Peer(id: 'source', name: 'Source', host: '192.0.2.5', port: 4000);

MediaItem _photo(String id) => MediaItem(
  id: id,
  deviceId: _peer.id,
  name: '$id.jpg',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 3,
  modifiedMs: 123,
  thumbnail: Uint8List.fromList([4, 5, 6]),
);

class _Gate {
  final entered = Completer<void>();
  final released = Completer<void>();

  Future<void> wait() async {
    entered.complete();
    await released.future;
  }

  void release() {
    if (!released.isCompleted) released.complete();
  }
}

class _DeletionBridge extends FakeBridge {
  final deleted = <String>[];
  _Gate? gate;
  Object? failure;

  @override
  Future<void> deleteDownload(String uri) async {
    deleted.add(uri);
    await gate?.wait();
    if (failure != null) throw failure!;
    final file = File.fromUri(Uri.parse(uri));
    if (await file.exists()) await file.delete();
  }
}

/// Hold a completed database read to exercise a truly stale polling snapshot.
class _GatedFactory implements DatabaseFactory {
  late _GatedDatabase database;

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async => database = _GatedDatabase(
    await databaseFactoryFfi.openDatabase(path, options: options),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedDatabase implements Database {
  _GatedDatabase(this.delegate);
  final Database delegate;
  int recentReadsUntilGate = 0;
  _Gate? readGate;
  bool failCompletedDelete = false;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final rows = await delegate.rawQuery(sql, arguments);
    if (sql.startsWith('SELECT * FROM transfers WHERE') &&
        recentReadsUntilGate > 0 &&
        --recentReadsUntilGate == 0) {
      await readGate!.wait();
    }
    return rows;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => delegate.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => delegate.transaction(action, exclusive: exclusive);

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => delegate.update(
    table,
    values,
    where: where,
    whereArgs: whereArgs,
    conflictAlgorithm: conflictAlgorithm,
  );

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    if (failCompletedDelete && where?.contains("state = 'completed'") == true) {
      throw StateError('completed record temporarily unavailable');
    }
    return delegate.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  Future<void> close() => delegate.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temporary;
  late TamayuraRepository repository;
  late TransferStore tasks;
  late _GatedFactory taskFactory;
  late _DeletionBridge bridge;
  late AppController model;

  Future<void> openModel() async {
    repository = await TamayuraRepository.open(
      path: '${temporary.path}/library.db',
      factory: databaseFactoryFfi,
    );
    taskFactory = _GatedFactory();
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: taskFactory,
    );
    model = AppController(
      bridge: bridge,
      preferredPort: 0,
      openRepository: () async => repository,
      openTransfers: () async => tasks,
    );
    await model.setForeground(false);
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tamayura-delete-test-');
    bridge = _DeletionBridge();
    await openModel();
    await repository.setSetting('downloadUri', temporary.uri.toString());
  });

  tearDown(() async {
    bridge.gate?.release();
    taskFactory.database.readGate?.release();
    await model.shutdown();
    await tasks.close();
    await repository.close();
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  Future<(MediaView, File, TransferTask?)> savedPhoto({
    bool withTask = true,
    bool withRecord = true,
    String id = 'photo',
  }) async {
    final item = _photo(id);
    await repository.replacePeerSnapshot(_peer, [item]);
    final file = await File(
      '${temporary.path}/${item.name}',
    ).writeAsBytes([1, 2, 3]);
    TransferTask? task;
    if (withTask) {
      task = await tasks.enqueue(_peer, item, temporary.uri.toString());
      await tasks.update(task.id, {
        'state': 'completed',
        'saved_uri': file.uri.toString(),
        'received': item.size,
      });
    }
    if (withRecord) {
      await repository.saveDownload(
        DownloadRecord(
          deviceId: item.deviceId,
          mediaId: item.id,
          uri: file.uri.toString(),
          completedAt: DateTime.now(),
        ),
      );
    }
    await model.initialize();
    expect(model.error, isNull);
    return (model.media.single, file, task);
  }

  test(
    'deletion removes saved state and completed task, retaining catalog',
    () async {
      final (item, file, task) = await savedPhoto();
      expect(await model.deleteLocalFile(item), isTrue);
      expect(await file.exists(), isFalse);
      expect(await repository.getDownload(item.deviceId, item.id), isNull);
      expect(await tasks.get(task!.id), isNull);
      expect(model.transfers[item.key], isNull);
      expect(model.media.single.key, item.key);
      expect(model.media.single.thumbnail, [4, 5, 6]);
      expect((await repository.getMedia(item.deviceId, item.id))!.thumbnail, [
        4,
        5,
        6,
      ]);

      await model.shutdown();
      await openModel();
      await model.initialize();
      expect(model.transfers[item.key], isNull);
      expect(model.media.single.key, item.key);
      await model.download(model.media.single);
      final retry = await tasks.forMedia(item.deviceId, item.id);
      expect(retry!.state, DownloadState.queued);
      expect(retry.id, isNot(task.id));
      expect(bridge.scheduled, contains(retry.id));
    },
  );

  test('saved record without a transfer can be deleted', () async {
    final (item, file, _) = await savedPhoto(withTask: false);
    expect(await model.deleteLocalFile(item), isTrue);
    expect(await file.exists(), isFalse);
    expect(await repository.getDownload(item.deviceId, item.id), isNull);
    expect(model.transfers[item.key], isNull);
  });

  test('completed task without a download record can be cleaned up', () async {
    final (item, file, task) = await savedPhoto(withRecord: false);
    expect(await model.deleteLocalFile(item), isTrue);
    expect(await file.exists(), isFalse);
    expect(await tasks.get(task!.id), isNull);
    expect(model.transfers[item.key], isNull);
  });

  test(
    'completed tasks older than the recent window do not block redownload',
    () async {
      final (item, file, task) = await savedPhoto();
      for (var index = 0; index < 100; index++) {
        final other = await tasks.enqueue(
          _peer,
          _photo('new-$index'),
          temporary.uri.toString(),
        );
        await tasks.update(other.id, {
          'state': 'completed',
          'saved_uri': 'file:///saved-$index.jpg',
        });
      }
      expect(
        (await tasks.recent()).map((task) => task.id),
        isNot(contains(task!.id)),
      );
      expect(await model.deleteLocalFile(item), isTrue);
      expect(await file.exists(), isFalse);
      expect(await tasks.get(task.id), isNull);
      await model.download(item);
      expect(
        (await tasks.forMedia(item.deviceId, item.id))!.state,
        DownloadState.queued,
      );
    },
  );

  test('missing local file still removes its saved state', () async {
    final (item, file, task) = await savedPhoto();
    await file.delete();
    expect(await model.deleteLocalFile(item), isTrue);
    expect(await repository.getDownload(item.deviceId, item.id), isNull);
    expect(await tasks.get(task!.id), isNull);
    expect(model.transfers[item.key], isNull);
  });

  test('native failure preserves records and can be retried', () async {
    final (item, file, task) = await savedPhoto();
    bridge.failure = PlatformException(
      code: 'PERMISSION',
      message: '无法删除，请检查目录权限',
    );
    expect(await model.deleteLocalFile(item), isFalse);
    expect(await file.exists(), isTrue);
    expect(
      (await repository.getDownload(item.deviceId, item.id))!.uri,
      file.uri.toString(),
    );
    expect((await tasks.get(task!.id))!.state, DownloadState.completed);
    expect(model.transfers[item.key]!.complete, isTrue);
    expect(model.error, contains('目录权限'));

    bridge.failure = null;
    expect(await model.deleteLocalFile(item), isTrue);
    expect(model.error, isNull);
    expect(await file.exists(), isFalse);
  });

  test(
    'persistence failure retains retryable record after native deletion',
    () async {
      final (item, file, task) = await savedPhoto();
      taskFactory.database.failCompletedDelete = true;
      expect(await model.deleteLocalFile(item), isFalse);
      expect(await file.exists(), isFalse);
      expect(await repository.getDownload(item.deviceId, item.id), isNotNull);
      expect(await tasks.get(task!.id), isNotNull);
      expect(model.transfers[item.key]!.complete, isTrue);

      taskFactory.database.failCompletedDelete = false;
      expect(await model.deleteLocalFile(item), isTrue);
      expect(await tasks.get(task.id), isNull);
      expect(await repository.getDownload(item.deviceId, item.id), isNull);
    },
  );

  test(
    'duplicate deletion and download cannot race with native deletion',
    () async {
      final (item, file, task) = await savedPhoto();
      final gate = bridge.gate = _Gate();
      final deletion = model.deleteLocalFile(item);
      await gate.entered.future;
      expect(await model.deleteLocalFile(item), isFalse);
      await model.download(item);
      expect(bridge.deleted, [file.uri.toString()]);
      expect(bridge.scheduled, isEmpty);
      expect(await tasks.get(task!.id), isNotNull);
      gate.release();
      expect(await deletion, isTrue);
      expect(await tasks.get(task.id), isNull);
      expect(model.transfers[item.key], isNull);
    },
  );

  test(
    'in-flight polling snapshot cannot restore deleted completed state',
    () async {
      final (item, _, _) = await savedPhoto();
      final gate = taskFactory.database.readGate = _Gate();
      taskFactory.database.recentReadsUntilGate = 2;
      // An already completed download performs the ordinary final poll only.
      final polling = model.download(item);
      await gate.entered.future;
      expect(await model.deleteLocalFile(item), isTrue);
      expect(model.transfers[item.key], isNull);
      gate.release();
      await polling;
      expect(model.transfers[item.key], isNull);
      await model.selectDevice(null);
      expect(model.transfers[item.key], isNull);
    },
  );

  test(
    'a running export cannot be deleted using a stale saved badge',
    () async {
      final (item, file, task) = await savedPhoto();
      await tasks.update(task!.id, {'state': 'saving'});
      bridge.scheduled.add(task.id);
      expect(await model.deleteLocalFile(item), isFalse);
      expect(bridge.deleted, isEmpty);
      expect(await file.exists(), isTrue);
      expect(await repository.getDownload(item.deviceId, item.id), isNotNull);
    },
  );

  const methods = MethodChannel('test/tamayura/delete-local-file');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final bridge in [
    const AndroidBridge(methods: methods),
    const MacOSBridge(methods: methods),
    const WindowsBridge(methods: methods),
  ]) {
    test(
      '${bridge.platformName} forwards deletion URI and native failure',
      () async {
        addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
        messenger.setMockMethodCallHandler(methods, (call) async {
          expect(call.method, 'deleteDownload');
          expect(call.arguments, {'uri': 'content://saved/photo.jpg'});
          return null;
        });
        await bridge.deleteDownload('content://saved/photo.jpg');
        messenger.setMockMethodCallHandler(methods, (_) async {
          throw PlatformException(code: 'DELETE_FAILED', message: '文件删除失败');
        });
        await expectLater(
          bridge.deleteDownload('content://saved/photo.jpg'),
          throwsA(isA<PlatformException>()),
        );
      },
    );
  }
}
