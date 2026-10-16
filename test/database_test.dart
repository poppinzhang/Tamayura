import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';

const firstPeer = Peer(
  id: 'phone-a',
  name: 'Phone A',
  host: '192.168.1.2',
  port: 4000,
);
const secondPeer = Peer(
  id: 'phone-b',
  name: 'Phone B',
  host: '192.168.1.3',
  port: 4000,
);

MediaItem media(
  String id, {
  String deviceId = 'phone-a',
  int modified = 123,
  String sharedFolderId = 'camera',
  String sharedFolderName = 'Camera',
  String? name,
  String? relativePath,
  List<int> thumbnail = const [1, 2, 3],
}) => MediaItem(
  id: id,
  deviceId: deviceId,
  name: name ?? '$id.jpg',
  sharedFolderId: sharedFolderId,
  sharedFolderName: sharedFolderName,
  relativePath: relativePath ?? name ?? '$id.jpg',
  mimeType: 'image/jpeg',
  size: 123,
  modifiedMs: modified,
  thumbnail: Uint8List.fromList(thumbnail),
);

void main() {
  sqfliteFfiInit();
  late TamayuraRepository repository;

  setUp(() async {
    repository = await TamayuraRepository.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() => repository.close());

  test('settings can be written, replaced and removed', () async {
    expect(await repository.getSetting('folder'), isNull);
    await repository.setSetting('folder', 'content://tree/photos');
    await repository.setSetting('folder', 'content://tree/camera');
    expect(await repository.getSetting('folder'), 'content://tree/camera');
    await repository.setSetting('folder', null);
    expect(await repository.getSetting('folder'), isNull);
  });

  test(
    'updating a remembered address preserves thumbnails and last sync',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [media('one')]);
      final before = (await repository.listPeers()).single;
      await repository.upsertPeer(firstPeer.copyWith(host: '192.168.1.9'));
      final peer = (await repository.listPeers()).single;
      expect(peer.host, '192.168.1.9');
      expect(peer.lastSync, before.lastSync);
      final cached = (await repository.listMedia()).single;
      expect(cached.id, 'one');
      expect(cached.thumbnail, [1, 2, 3]);
    },
  );

  test(
    'concurrent discovery updates do not create duplicate peer rows',
    () async {
      await Future.wait(
        List.generate(
          5,
          (index) => repository.upsertPeer(
            firstPeer.copyWith(host: '192.168.1.${index + 1}'),
          ),
        ),
      );
      expect(await repository.listPeers(), hasLength(1));
    },
  );

  test(
    'a complete snapshot handles additions and deletions for only its peer',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [
        media('removed'),
        media('kept'),
      ]);
      await repository.replacePeerSnapshot(secondPeer, [
        media('other', deviceId: secondPeer.id),
      ]);
      await repository.replacePeerSnapshot(firstPeer, [
        media('kept'),
        media('new', modified: 999),
      ]);
      expect(
        (await repository.listMedia(
          deviceId: firstPeer.id,
        )).map((item) => item.id),
        ['new', 'kept'],
      );
      expect(
        (await repository.listMedia(deviceId: secondPeer.id)).single.id,
        'other',
      );
      await repository.replacePeerSnapshot(firstPeer, []);
      expect(await repository.listMedia(deviceId: firstPeer.id), isEmpty);
      expect((await repository.listMedia()).single.id, 'other');
    },
  );

  test(
    'duplicate or wrong-device snapshots never destroy preceding data',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [media('original')]);
      await expectLater(
        repository.replacePeerSnapshot(firstPeer, [
          media('duplicate'),
          media('duplicate'),
        ]),
        throwsFormatException,
      );
      await expectLater(
        repository.replacePeerSnapshot(firstPeer, [
          media('foreign', deviceId: secondPeer.id),
        ]),
        throwsFormatException,
      );
      expect((await repository.listMedia()).single.id, 'original');
    },
  );

  test('completed downloads survive removal from the remote library', () async {
    await repository.replacePeerSnapshot(firstPeer, [media('one')]);
    final completion = DateTime.fromMillisecondsSinceEpoch(456);
    await repository.saveDownload(
      DownloadRecord(
        deviceId: firstPeer.id,
        mediaId: 'one',
        uri: 'content://local/one',
        completedAt: completion,
      ),
    );
    await repository.replacePeerSnapshot(firstPeer, []);
    final downloaded = await repository.getDownload(firstPeer.id, 'one');
    expect(downloaded!.uri, 'content://local/one');
    expect(downloaded.completedAt, completion);
    expect(await repository.getDownload(secondPeer.id, 'one'), isNull);
    await repository.removeDownload(firstPeer.id, 'one');
    expect(await repository.getDownload(firstPeer.id, 'one'), isNull);
  });

  test('peer metadata and thumbnail bytes survive database reopen', () async {
    final folder = await Directory.systemTemp.createTemp('tamayura-db-test-');
    final path = '${folder.path}/library.db';
    final persistent = await TamayuraRepository.open(
      path: path,
      factory: databaseFactoryFfi,
    );
    try {
      await persistent.replacePeerSnapshot(firstPeer, [media('cached')]);
      await persistent.setSetting('device_id', 'persistent-uuid');
    } finally {
      await persistent.close();
    }
    final reopened = await TamayuraRepository.open(
      path: path,
      factory: databaseFactoryFfi,
    );
    try {
      expect((await reopened.listPeers()).single.id, firstPeer.id);
      expect((await reopened.listMedia()).single.thumbnail, [1, 2, 3]);
      final collection = (await reopened.mediaCollections()).single;
      expect(collection.key, '${firstPeer.id}/camera');
      expect(collection.sharedFolderName, 'Camera');
      expect(collection.itemCount, 1);
      expect((await reopened.listMedia()).single.relativePath, 'cached.jpg');
      expect(await reopened.getSetting('device_id'), 'persistent-uuid');
    } finally {
      await reopened.close();
      await folder.delete(recursive: true);
    }
  });
  test(
    'staged thumbnails are previewed while deletions wait for a complete commit',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [
        media('old'),
        media('kept'),
      ]);
      final session = await repository.beginPeerSnapshot(
        firstPeer,
        'revision-2',
        2,
      );
      expect(
        await repository.stageMediaPage(session, [media('kept')]),
        isEmpty,
      );
      final missing = await repository.stageMediaPage(session, [media('new')]);
      expect(missing.single.id, 'new');
      expect(
        (await repository.listMediaPage()).items.map((item) => item.id).toSet(),
        {'old', 'kept'},
      );
      await expectLater(
        repository.commitPeerSnapshot(session),
        throwsFormatException,
      );
      await repository.saveStagedThumbnail(
        session,
        'new',
        Uint8List.fromList([9]),
      );
      expect(
        (await repository.listMediaPage()).items.map((item) => item.id).toSet(),
        {'old', 'kept', 'new'},
      );
      expect(await repository.peerRevision(firstPeer.id), isNull);
      final committed = await repository.commitPeerSnapshot(session);
      expect(committed.totalCount, 2);
      expect(committed.addedCount, 1);
      expect(committed.deletedCount, 1);
      expect((await repository.getMedia(firstPeer.id, 'kept'))!.thumbnail, [
        1,
        2,
        3,
      ]);
      expect((await repository.getMedia(firstPeer.id, 'new'))!.thumbnail, [9]);
      expect(await repository.getMedia(firstPeer.id, 'old'), null);
      expect(await repository.peerRevision(firstPeer.id), 'revision-2');
    },
  );

  test(
    'first sync previews completed thumbnails and new collections',
    () async {
      final session = await repository.beginPeerSnapshot(firstPeer, 'first', 2);
      final camera = media('camera-photo', modified: 2);
      final holiday = media(
        'holiday-photo',
        modified: 3,
        sharedFolderId: 'holiday',
        sharedFolderName: 'Holiday',
      );
      await repository.stageMediaPage(session, [camera, holiday]);
      expect(await repository.countMedia(), 0);
      expect(await repository.mediaCollections(), isEmpty);
      expect(await repository.getMedia(firstPeer.id, camera.id), isNull);
      await repository.saveStagedThumbnail(
        session,
        camera.id,
        camera.thumbnail,
      );
      expect((await repository.listMedia()).single.id, camera.id);
      expect((await repository.getMedia(firstPeer.id, camera.id))!.thumbnail, [
        1,
        2,
        3,
      ]);
      expect((await repository.mediaCollections()).single.itemCount, 1);
      expect(await repository.countMedia(sharedFolderId: 'holiday'), 0);
      await repository.saveStagedThumbnail(
        session,
        holiday.id,
        holiday.thumbnail,
      );
      final collections = await repository.mediaCollections(
        deviceId: firstPeer.id,
      );
      expect(collections.map((item) => item.sharedFolderId), [
        'camera',
        'holiday',
      ]);
      expect(collections.map((item) => item.itemCount), [1, 1]);
      final page = await repository.listMediaPage(sharedFolderId: 'holiday');
      expect(page.items.single.id, holiday.id);
      expect(page.totalCount, 1);
      await repository.abortPeerSnapshot(session);
      expect(await repository.countMedia(), 0);
      expect(await repository.mediaCollections(), isEmpty);
      expect(await repository.getMedia(firstPeer.id, camera.id), isNull);
    },
  );

  test(
    'aborting a preview restores old metadata, thumbnail and collections',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [
        media('kept'),
        media('old'),
      ]);
      final session = await repository.beginPeerSnapshot(
        firstPeer,
        'changed',
        2,
      );
      final changed = media(
        'kept',
        modified: 500,
        sharedFolderId: 'archive',
        sharedFolderName: 'Archive',
        thumbnail: [9],
      );
      final added = media(
        'added',
        sharedFolderId: 'archive',
        sharedFolderName: 'Archive',
      );
      await repository.stageMediaPage(session, [changed, added]);
      await repository.saveStagedThumbnail(
        session,
        changed.id,
        changed.thumbnail,
      );
      await repository.saveStagedThumbnail(session, added.id, added.thumbnail);
      expect(await repository.countMedia(), 3);
      expect(await repository.countMedia(sharedFolderId: 'camera'), 1);
      expect(await repository.countMedia(sharedFolderId: 'archive'), 2);
      expect((await repository.getMedia(firstPeer.id, 'kept'))!.thumbnail, [9]);
      expect(
        (await repository.getMedia(firstPeer.id, 'kept'))!.modifiedMs,
        500,
      );
      await repository.abortPeerSnapshot(session);
      expect(await repository.countMedia(), 2);
      expect(
        (await repository.mediaCollections()).single.sharedFolderId,
        'camera',
      );
      expect((await repository.getMedia(firstPeer.id, 'kept'))!.thumbnail, [
        1,
        2,
        3,
      ]);
      expect(
        (await repository.getMedia(firstPeer.id, 'kept'))!.modifiedMs,
        123,
      );
      expect(await repository.getMedia(firstPeer.id, 'added'), isNull);
    },
  );

  test(
    'preview keyset pages deduplicate replacements and isolate concurrent peers',
    () async {
      for (final peer in [firstPeer, secondPeer]) {
        await repository.replacePeerSnapshot(
          peer,
          List.generate(
            9,
            (i) => media('id-$i', deviceId: peer.id, modified: i % 3),
          ),
        );
        final session = await repository.beginPeerSnapshot(
          peer,
          'new-${peer.id}',
          6,
        );
        final staged = List.generate(
          6,
          (i) => media('id-${i + 6}', deviceId: peer.id, modified: 4),
        );
        await repository.stageMediaPage(session, staged);
        for (final item in staged) {
          await repository.saveStagedThumbnail(
            session,
            item.id,
            item.thumbnail,
          );
        }
      }
      final keys = <String>[];
      MediaCursor? cursor;
      do {
        final page = await repository.listMediaPage(after: cursor, limit: 5);
        expect(page.totalCount, 24);
        keys.addAll(page.items.map((item) => item.key));
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(keys, hasLength(24));
      expect(keys.toSet(), hasLength(24));
      expect(await repository.countMedia(deviceId: firstPeer.id), 12);
      expect(await repository.countMedia(deviceId: secondPeer.id), 12);
      expect(
        (await repository.mediaCollections()).map((item) => item.itemCount),
        [12, 12],
      );
    },
  );

  test(
    'only latest local attempt is previewed and older abort cannot hide it',
    () async {
      final older = await repository.beginPeerSnapshot(firstPeer, 'older', 1);
      await repository.stageMediaPage(older, [media('older')]);
      await repository.saveStagedThumbnail(
        older,
        'older',
        Uint8List.fromList([1]),
      );
      expect((await repository.listMedia()).single.id, 'older');
      final newer = await repository.beginPeerSnapshot(firstPeer, 'newer', 1);
      await repository.stageMediaPage(newer, [media('newer')]);
      await repository.saveStagedThumbnail(
        newer,
        'newer',
        Uint8List.fromList([2]),
      );
      expect((await repository.listMedia()).single.id, 'newer');
      await repository.abortPeerSnapshot(older);
      expect((await repository.listMedia()).single.id, 'newer');
      await repository.commitPeerSnapshot(newer);
      expect((await repository.listMedia()).single.id, 'newer');
    },
  );

  test(
    'a competing commit invalidates any preview based on the old generation',
    () async {
      final older = await repository.beginPeerSnapshot(firstPeer, 'older', 1);
      await repository.stageMediaPage(older, [media('committed')]);
      await repository.saveStagedThumbnail(
        older,
        'committed',
        Uint8List.fromList([1]),
      );
      final newer = await repository.beginPeerSnapshot(firstPeer, 'newer', 1);
      await repository.stageMediaPage(newer, [media('preview')]);
      await repository.saveStagedThumbnail(
        newer,
        'preview',
        Uint8List.fromList([2]),
      );
      expect((await repository.listMedia()).single.id, 'preview');
      await repository.commitPeerSnapshot(older);
      expect((await repository.listMedia()).single.id, 'committed');
      expect(await repository.getMedia(firstPeer.id, 'preview'), isNull);
      await expectLater(
        repository.commitPeerSnapshot(newer),
        throwsA(isA<SnapshotConflictException>()),
      );
      await repository.abortPeerSnapshot(newer);
      expect((await repository.listMedia()).single.id, 'committed');
    },
  );

  test(
    'incomplete and duplicate-across-page stages never erase committed rows',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [media('old')]);
      final session = await repository.beginPeerSnapshot(
        firstPeer,
        'partial',
        2,
      );
      await repository.stageMediaPage(session, [media('old')]);
      await expectLater(
        repository.stageMediaPage(session, [media('old')]),
        throwsFormatException,
      );
      await expectLater(
        repository.commitPeerSnapshot(session),
        throwsFormatException,
      );
      await repository.abortPeerSnapshot(session);
      expect((await repository.listMediaPage()).items.single.id, 'old');
    },
  );

  test(
    'page checkpoint is atomic and claiming invalidates the previous owner',
    () async {
      final session = await repository.beginPeerSnapshot(
        firstPeer,
        'revision',
        3,
      );
      await repository.stageMediaPage(session, [
        media('a'),
        media('b'),
      ], nextPageToken: 'revision:2');
      await repository.saveStagedThumbnail(
        session,
        'a',
        Uint8List.fromList([7]),
      );
      final first = (await repository.findPeerSnapshot(firstPeer))!;
      expect(first.receivedCount, 2);
      expect(first.readyCount, 1);
      expect(first.metadataComplete, false);
      expect(first.nextPageToken, 'revision:2');
      expect(
        (await repository.pendingSnapshotMedia(session, limit: 1)).single.id,
        'b',
      );
      // Duplicate metadata and an invalid final count roll back both rows and cursor.
      await expectLater(
        repository.stageMediaPage(session, [
          media('b'),
        ], nextPageToken: 'wrong'),
        throwsFormatException,
      );
      await expectLater(
        repository.stageMediaPage(session, [], metadataComplete: true),
        throwsFormatException,
      );
      expect(
        (await repository.findPeerSnapshot(firstPeer))!.nextPageToken,
        'revision:2',
      );
      final claimed = (await repository.findPeerSnapshot(
        firstPeer.copyWith(port: 5000),
        claim: true,
      ))!;
      expect(claimed.sessionId, isNot(session));
      await expectLater(
        repository.findPeerSnapshot(
          firstPeer,
          claim: true,
          expectedSessionId: session,
        ),
        throwsA(isA<SnapshotConflictException>()),
      );
      expect(claimed.readyCount, 1);
      expect((await repository.getMedia(firstPeer.id, 'a'))!.thumbnail, [7]);
      await expectLater(
        repository.saveStagedThumbnail(session, 'b', Uint8List.fromList([8])),
        throwsA(isA<SnapshotConflictException>()),
      );
      await expectLater(
        repository.stageMediaPage(session, [media('c')]),
        throwsA(isA<SnapshotConflictException>()),
      );
      await expectLater(
        repository.commitPeerSnapshot(session),
        throwsA(isA<SnapshotConflictException>()),
      );
      await repository.abortPeerSnapshot(session);
      expect(
        (await repository.findPeerSnapshot(firstPeer))!.sessionId,
        claimed.sessionId,
      );
      await repository.saveStagedThumbnail(
        claimed.sessionId,
        'b',
        Uint8List.fromList([8]),
      );
      await repository.stageMediaPage(claimed.sessionId, [
        media('c'),
      ], metadataComplete: true);
      await repository.saveStagedThumbnail(
        claimed.sessionId,
        'c',
        Uint8List.fromList([9]),
      );
      final completed = (await repository.findPeerSnapshot(firstPeer))!;
      expect(completed.metadataComplete, true);
      expect(completed.nextPageToken, isNull);
      expect(completed.readyCount, 3);
      await repository.commitPeerSnapshot(claimed.sessionId);
      expect(await repository.findPeerSnapshot(firstPeer), isNull);
      expect((await repository.listPeers()).single.port, 5000);
    },
  );

  test(
    'new revision reuses complete staged thumbnails only when metadata matches',
    () async {
      final old = await repository.beginPeerSnapshot(firstPeer, 'old', 3);
      await repository.stageMediaPage(old, [
        media('a'),
        media('b'),
        media('c'),
      ]);
      await repository.saveStagedThumbnail(old, 'a', Uint8List.fromList([7]));
      await repository.saveStagedThumbnail(old, 'b', Uint8List(0));
      final next = await repository.beginPeerSnapshot(firstPeer, 'next', 3);
      final missing = await repository.stageMediaPage(next, [
        media('a'),
        media('b'),
        media('c', modified: 456),
      ], metadataComplete: true);
      expect(missing.single.id, 'c');
      expect((await repository.getMedia(firstPeer.id, 'a'))!.thumbnail, [7]);
      expect(
        (await repository.getMedia(firstPeer.id, 'b'))!.thumbnail,
        isEmpty,
      );
      expect((await repository.findPeerSnapshot(firstPeer))!.readyCount, 2);
      await repository.saveStagedThumbnail(next, 'c', Uint8List.fromList([9]));
      await repository.commitPeerSnapshot(next);
      expect(await repository.findPeerSnapshot(firstPeer), isNull);
    },
  );

  test(
    'keyset pagination traverses tie timestamps and peer IDs without missing or duplicate rows',
    () async {
      await repository.replacePeerSnapshot(
        firstPeer,
        List.generate(39, (i) => media('id-$i', modified: i % 3)),
      );
      await repository.replacePeerSnapshot(
        secondPeer,
        List.generate(
          39,
          (i) => media('id-$i', deviceId: secondPeer.id, modified: i % 3),
        ),
      );
      final keys = <String>[];
      MediaCursor? cursor;
      do {
        final page = await repository.listMediaPage(after: cursor, limit: 7);
        expect(page.items.length, lessThanOrEqualTo(7));
        expect(page.totalCount, 78);
        keys.addAll(page.items.map((item) => item.key));
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(keys.length, 78);
      expect(keys.toSet().length, 78);
      final peerPage = await repository.listMediaPage(
        deviceId: secondPeer.id,
        limit: 200,
      );
      expect(peerPage.totalCount, 39);
      expect(
        peerPage.items.every((item) => item.deviceId == secondPeer.id),
        true,
      );
      expect(peerPage.nextCursor, null);
      await expectLater(
        repository.listMediaPage(limit: 201),
        throwsArgumentError,
      );
    },
  );

  test(
    'an older concurrent sync cannot overwrite a newer committed snapshot',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [media('kept')]);
      final older = await repository.beginPeerSnapshot(firstPeer, 'older', 1);
      final newer = await repository.beginPeerSnapshot(firstPeer, 'newer', 1);
      await repository.stageMediaPage(older, [media('kept')]);
      await repository.stageMediaPage(newer, [media('kept')]);
      await repository.commitPeerSnapshot(newer);
      await expectLater(
        repository.commitPeerSnapshot(older),
        throwsA(isA<SnapshotConflictException>()),
      );
      await repository.abortPeerSnapshot(older);
      expect(await repository.peerRevision(firstPeer.id), 'newer');
    },
  );

  test(
    'opening a second engine connection does not delete an active synchronization stage',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'tamayura-multiple-engine-',
      );
      final path = '${folder.path}/library.db';
      final first = await TamayuraRepository.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      TamayuraRepository? second;
      try {
        final session = await first.beginPeerSnapshot(firstPeer, 'active', 1);
        await first.stageMediaPage(session, [media('photo')]);
        second = await TamayuraRepository.open(
          path: path,
          factory: databaseFactoryFfiNoIsolate,
        );
        await first.saveStagedThumbnail(
          session,
          'photo',
          Uint8List.fromList([5]),
        );
        expect((await first.listMediaPage()).items.single.thumbnail, [5]);
        expect(await second.countMedia(), 1);
        expect((await second.mediaCollections()).single.itemCount, 1);
        await first.commitPeerSnapshot(session);
        expect((await second.listMediaPage()).items.single.thumbnail, [5]);
        await second.close();
        second = null;
        expect(
          await first.countMedia(),
          1,
          reason:
              'Closing a background engine must not close the UI connection',
        );
      } finally {
        await second?.close();
        await first.close();
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'collections preserve same-name roots and counts beyond the first page',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [
        ...List.generate(
          70,
          (i) => media(
            'camera-$i',
            sharedFolderId: 'internal',
            sharedFolderName: 'Camera',
            relativePath: '2026/Trip/camera-$i.jpg',
            modified: i,
            thumbnail: [i],
          ),
        ),
        media(
          'sd-photo',
          sharedFolderId: 'sd-card',
          sharedFolderName: 'Camera',
          name: 'camera-0.jpg',
          relativePath: '2026/Trip/camera-0.jpg',
        ),
      ]);
      await repository.replacePeerSnapshot(secondPeer, [
        media(
          'other-photo',
          deviceId: secondPeer.id,
          sharedFolderId: 'internal',
          sharedFolderName: 'Camera',
        ),
      ]);
      final collections = await repository.mediaCollections();
      expect(collections, hasLength(3));
      expect(collections.map((collection) => collection.key).toSet(), {
        '${firstPeer.id}/internal',
        '${firstPeer.id}/sd-card',
        '${secondPeer.id}/internal',
      });
      final camera = collections.firstWhere(
        (collection) => collection.key == '${firstPeer.id}/internal',
      );
      expect(camera.itemCount, 70);
      expect(camera.thumbnail, [69]);
      expect(
        await repository.mediaCollections(deviceId: firstPeer.id),
        hasLength(2),
      );
      final seen = <String>[];
      MediaCursor? cursor;
      do {
        final page = await repository.listMediaPage(
          deviceId: firstPeer.id,
          sharedFolderId: 'internal',
          limit: 13,
          after: cursor,
        );
        expect(page.totalCount, 70);
        expect(
          page.items.every((item) => item.sharedFolderId == 'internal'),
          isTrue,
        );
        seen.addAll(page.items.map((item) => item.id));
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(seen.toSet(), {for (var i = 0; i < 70; i++) 'camera-$i'});
      expect(seen, hasLength(70));
      expect(
        (await repository.getMedia(firstPeer.id, 'camera-0'))!.relativePath,
        '2026/Trip/camera-0.jpg',
      );
      expect(
        (await repository.listMediaPage(sharedFolderId: 'internal')).totalCount,
        71,
      );
    },
  );

  test(
    'staged collection moves appear with thumbnails and deletions wait for commit',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [media('photo')]);
      final session = await repository.beginPeerSnapshot(
        firstPeer,
        'new-root',
        1,
      );
      final moved = media(
        'photo',
        sharedFolderId: 'archive',
        sharedFolderName: 'Archive',
        relativePath: '2026/photo.jpg',
      );
      expect(await repository.stageMediaPage(session, [moved]), hasLength(1));
      expect(
        (await repository.mediaCollections()).single.sharedFolderId,
        'camera',
      );
      await repository.saveStagedThumbnail(
        session,
        moved.id,
        Uint8List.fromList([9]),
      );
      expect(
        (await repository.mediaCollections()).single.sharedFolderId,
        'archive',
      );
      await repository.commitPeerSnapshot(session);
      final collection = (await repository.mediaCollections()).single;
      expect(collection.key, '${firstPeer.id}/archive');
      expect(collection.thumbnail, [9]);
      expect(
        (await repository.listMediaPage()).items.single.relativePath,
        '2026/photo.jpg',
      );
      final removal = await repository.beginPeerSnapshot(firstPeer, 'empty', 0);
      expect(await repository.mediaCollections(), hasLength(1));
      await repository.commitPeerSnapshot(removal);
      expect(await repository.mediaCollections(), isEmpty);
    },
  );

  test(
    'missing roots and unsafe paths leave offline collections intact',
    () async {
      await repository.replacePeerSnapshot(firstPeer, [media('original')]);
      for (final path in [
        '',
        '../photo.jpg',
        '/photo.jpg',
        'a//photo.jpg',
        'a/./photo.jpg',
        r'a\photo.jpg',
        'C:/photo.jpg',
        'a/other.jpg',
      ]) {
        final invalid = media('photo', relativePath: path);
        await expectLater(
          repository.replacePeerSnapshot(firstPeer, [invalid]),
          throwsFormatException,
        );
        final session = await repository.beginPeerSnapshot(
          firstPeer,
          'bad-path',
          1,
        );
        await expectLater(
          repository.stageMediaPage(session, [invalid]),
          throwsFormatException,
        );
        await repository.abortPeerSnapshot(session);
      }
      await expectLater(
        repository.replacePeerSnapshot(firstPeer, [
          media('photo', sharedFolderId: ''),
        ]),
        throwsFormatException,
      );
      expect((await repository.mediaCollections()).single.itemCount, 1);
      expect((await repository.listMediaPage()).items.single.id, 'original');
    },
  );
}
