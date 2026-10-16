import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/core/transfer_task.dart';
import 'package:tamayura/data/transfer_store.dart';

const peer = Peer(
  id: 'source',
  name: 'Source',
  host: '192.168.1.2',
  port: 4000,
);
MediaItem photo(String id) => MediaItem(
  id: id,
  deviceId: peer.id,
  name: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 8,
  modifiedMs: 1,
  sharedFolderId: 'photos',
  sharedFolderName: 'Photos',
  relativePath: '$id.jpg',
  thumbnail: Uint8List(0),
);

void main() {
  sqfliteFfiInit();
  late TransferStore store;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tamayura-cleanup-');
    store = await TransferStore.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  Future<TransferTask> task(String id, String state) async {
    final value = await store.enqueue(peer, photo(id), 'content://destination');
    await store.update(value.id, {'state': state});
    await Directory('${root.path}/${value.id}').create();
    await File('${root.path}/${value.id}/0.part').writeAsBytes([1, 2, 3]);
    return value;
  }

  test(
    'discard fences an old worker and deletes only its staging after it drains',
    () async {
      final value = await task('active', 'queued');
      await store.claim(value.id, 'old-worker');
      final exported = await File(
        '${root.path}/saved.jpg',
      ).writeAsBytes([7, 8]);
      expect(await store.requestDiscard(value.id), isTrue);
      expect(await store.claim(value.id, 'late-worker'), isNull);
      expect(
        await store.update(value.id, {
          'state': 'completed',
        }, runToken: 'old-worker'),
        isFalse,
      );
      await expectLater(
        store.enqueue(peer, value.item, 'content://destination'),
        throwsStateError,
      );
      expect(
        await File('${root.path}/${value.id}/0.part').exists(),
        isTrue,
        reason:
            'requesting stop must not delete files still used by the worker',
      );
      await store.finishDiscard(value.id, root);
      expect(await Directory('${root.path}/${value.id}').exists(), isFalse);
      expect(await store.get(value.id), isNull);
      expect(await exported.readAsBytes(), [7, 8]);
      final retry = await store.enqueue(
        peer,
        value.item,
        'content://destination',
      );
      expect(retry.id, isNot(value.id));
      expect(retry.received, 0);
    },
  );

  test(
    'startup reclaims abandoned storage but preserves every resumable or active task',
    () async {
      final paused = await task('paused', 'cancelled');
      final failed = await task('failed', 'failed');
      final queued = await task('queued', 'queued');
      final completed = await task('completed', 'completed');
      final abandoned = await task('abandoned', 'failed');
      final draining = await task('draining', 'downloading');
      await store.requestDiscard(abandoned.id);
      await store.requestDiscard(draining.id);
      final orphan = await Directory('${root.path}/orphan-task').create();
      await File('${orphan.path}/complete.partial').writeAsBytes([1, 2]);
      await store.cleanupStaging(root, activeIds: {draining.id});
      for (final value in [paused, failed, queued, draining]) {
        expect(await Directory('${root.path}/${value.id}').exists(), isTrue);
      }
      expect(await Directory('${root.path}/${completed.id}').exists(), isFalse);
      expect((await store.get(completed.id))!.state, DownloadState.completed);
      expect(await store.get(abandoned.id), isNull);
      expect(await orphan.exists(), isFalse);
      await store.cleanupStaging(root, activeIds: {});
      expect(await store.get(draining.id), isNull);
      expect(await Directory('${root.path}/${draining.id}').exists(), isFalse);
    },
  );

  test('missing staging root still completes a persisted discard', () async {
    final value = await store.enqueue(
      peer,
      photo('missing'),
      'content://destination',
    );
    await store.requestDiscard(value.id);
    await store.cleanupStaging(
      Directory('${root.path}/not-created'),
      activeIds: {},
    );
    expect(await store.get(value.id), isNull);
  });

  test(
    'completed files cannot be discarded and old unfinished tasks remain accessible',
    () async {
      final old = await task('old-paused', 'cancelled');
      await store.update(old.id, {'updated_ms': 1});
      for (var i = 0; i < 105; i++) {
        final value = await store.enqueue(
          peer,
          photo('done-$i'),
          'content://destination',
        );
        await store.update(value.id, {
          'state': 'completed',
          'saved_uri': 'content://saved/$i',
        });
        expect(await store.requestDiscard(value.id), isFalse);
      }
      expect((await store.recent()).any((value) => value.id == old.id), isTrue);
    },
  );
}
