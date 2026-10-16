import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';

const _peer = Peer(
  id: 'source',
  name: 'Source',
  host: '192.168.1.2',
  port: 4000,
);
const _otherPeer = Peer(
  id: 'other-source',
  name: 'Other source',
  host: '192.168.1.3',
  port: 4000,
);

MediaItem _media(
  String id, {
  String deviceId = 'source',
  int modified = 123,
  Uint8List? thumbnail,
}) => MediaItem(
  id: id,
  deviceId: deviceId,
  name: '$id.jpg',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 123,
  modifiedMs: modified,
  thumbnail: thumbnail ?? Uint8List.fromList([1, 2, 3]),
);

void main() {
  sqfliteFfiInit();
  late Directory folder;
  late String path;
  late TamayuraRepository repository;
  late Database inspection;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('tamayura-thumbnails-');
    path = '${folder.path}/library.db';
    repository = await TamayuraRepository.open(
      path: path,
      factory: databaseFactoryFfi,
    );
    inspection = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false, readOnly: true),
    );
  });
  tearDown(() async {
    await inspection.close();
    await repository.close();
    await folder.delete(recursive: true);
  });

  Future<int> countThumbnails() async => Sqflite.firstIntValue(
    await inspection.rawQuery('SELECT COUNT(*) FROM thumbnails'),
  )!;

  Future<int?> stagedId(String session, String mediaId) async =>
      (await inspection.query(
            'sync_media',
            columns: ['thumbnail_id'],
            where: 'session_id = ? AND id = ?',
            whereArgs: [session, mediaId],
          )).single['thumbnail_id']
          as int?;

  Future<int> committedId(String mediaId) async =>
      (await inspection.query(
            'media',
            columns: ['thumbnail_id'],
            where: 'device_id = ? AND id = ?',
            whereArgs: [_peer.id, mediaId],
          )).single['thumbnail_id']
          as int;

  Future<int> allocatedBytes() async {
    final pages = Sqflite.firstIntValue(
      await inspection.rawQuery('PRAGMA page_count'),
    )!;
    final pageSize = Sqflite.firstIntValue(
      await inspection.rawQuery('PRAGMA page_size'),
    )!;
    return pages * pageSize;
  }

  test(
    'initial commit and reopen keep one stored BLOB, including empty images',
    () async {
      final session = await repository.beginPeerSnapshot(_peer, 'first', 2);
      await repository.stageMediaPage(session, [
        _media('photo'),
        _media('empty'),
      ], metadataComplete: true);
      expect(await countThumbnails(), 0);
      expect(await stagedId(session, 'empty'), isNull);
      await repository.saveStagedThumbnail(
        session,
        'photo',
        Uint8List.fromList([9]),
      );
      await repository.saveStagedThumbnail(session, 'empty', Uint8List(0));
      final photoId = await stagedId(session, 'photo');
      final emptyId = await stagedId(session, 'empty');
      expect(emptyId, isNotNull);
      expect(await countThumbnails(), 2);

      await repository.close();
      repository = await TamayuraRepository.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      final checkpoint = await repository.findPeerSnapshot(_peer, claim: true);
      expect(checkpoint!.readyCount, 2);
      expect(
        await repository.pendingSnapshotMedia(checkpoint.sessionId),
        isEmpty,
      );
      expect(await stagedId(checkpoint.sessionId, 'photo'), photoId);
      expect(
        (await repository.getMedia(_peer.id, 'empty'))!.thumbnail,
        isEmpty,
      );
      await repository.commitPeerSnapshot(checkpoint.sessionId);
      expect(await committedId('photo'), photoId);
      expect(await committedId('empty'), emptyId);
      expect(await countThumbnails(), 2);

      final next = await repository.beginPeerSnapshot(_peer, 'next', 2);
      expect(
        await repository.stageMediaPage(next, [
          _media('photo'),
          _media('empty'),
        ], metadataComplete: true),
        isEmpty,
      );
      expect(await stagedId(next, 'empty'), emptyId);
      await repository.abortPeerSnapshot(next);
      expect(await countThumbnails(), 2);
      expect(await inspection.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test(
    'revision reuse and abort preserve every remaining stage reference',
    () async {
      final first = await repository.beginPeerSnapshot(_peer, 'first', 1);
      await repository.stageMediaPage(first, [_media('photo')]);
      await repository.saveStagedThumbnail(
        first,
        'photo',
        Uint8List.fromList([7]),
      );
      final imageId = await stagedId(first, 'photo');
      final next = await repository.beginPeerSnapshot(_peer, 'next', 1);
      expect(
        await repository.stageMediaPage(next, [
          _media('photo'),
        ], metadataComplete: true),
        isEmpty,
      );
      expect(await stagedId(next, 'photo'), imageId);
      expect(await countThumbnails(), 1);
      await repository.abortPeerSnapshot(first);
      expect(await countThumbnails(), 1);
      expect((await repository.getMedia(_peer.id, 'photo'))!.thumbnail, [7]);
      await repository.commitPeerSnapshot(next);
      expect(await committedId('photo'), imageId);
      expect(await countThumbnails(), 1);
    },
  );

  test(
    'staged replacement never mutates an image used by another session',
    () async {
      final first = await repository.beginPeerSnapshot(_peer, 'first', 1);
      await repository.stageMediaPage(first, [_media('photo')]);
      await repository.saveStagedThumbnail(
        first,
        'photo',
        Uint8List.fromList([7]),
      );
      final next = await repository.beginPeerSnapshot(_peer, 'next', 1);
      await repository.stageMediaPage(next, [
        _media('photo'),
      ], metadataComplete: true);
      final originalId = await stagedId(next, 'photo');
      await repository.saveStagedThumbnail(
        first,
        'photo',
        Uint8List.fromList([8]),
      );
      expect(await stagedId(first, 'photo'), isNot(originalId));
      expect(await stagedId(next, 'photo'), originalId);
      expect(await countThumbnails(), 2);
      expect((await repository.getMedia(_peer.id, 'photo'))!.thumbnail, [7]);
      await repository.abortPeerSnapshot(first);
      expect(await countThumbnails(), 1);
      await repository.commitPeerSnapshot(next);
      expect((await repository.getMedia(_peer.id, 'photo'))!.thumbnail, [7]);
    },
  );

  test('changed image rollback frees only the uncommitted bytes', () async {
    await repository.replacePeerSnapshot(_peer, [_media('photo')]);
    final originalId = await committedId('photo');
    final session = await repository.beginPeerSnapshot(_peer, 'changed', 1);
    final changed = _media('photo', modified: 456);
    expect(await repository.stageMediaPage(session, [changed]), [changed]);
    expect(await stagedId(session, 'photo'), isNull);
    await repository.saveStagedThumbnail(
      session,
      'photo',
      Uint8List.fromList([9]),
    );
    expect(await countThumbnails(), 2);
    expect((await repository.getMedia(_peer.id, 'photo'))!.thumbnail, [9]);
    await repository.abortPeerSnapshot(session);
    expect(await countThumbnails(), 1);
    expect(await committedId('photo'), originalId);
    expect((await repository.getMedia(_peer.id, 'photo'))!.thumbnail, [
      1,
      2,
      3,
    ]);
  });

  test(
    'failed and stale writes do not leak or remove thumbnail bytes',
    () async {
      await repository.replacePeerSnapshot(_peer, [_media('kept')]);
      final old = await repository.beginPeerSnapshot(_peer, 'old', 2);
      await repository.stageMediaPage(old, [_media('kept'), _media('missing')]);
      await expectLater(
        repository.saveStagedThumbnail(old, 'unknown', Uint8List.fromList([8])),
        throwsA(isA<SnapshotConflictException>()),
      );
      await expectLater(
        repository.commitPeerSnapshot(old),
        throwsA(isA<FormatException>()),
      );
      expect(await countThumbnails(), 1);
      final next = await repository.beginPeerSnapshot(_peer, 'next', 1);
      await repository.stageMediaPage(next, [
        _media('kept'),
      ], metadataComplete: true);
      await repository.commitPeerSnapshot(next);
      await expectLater(
        repository.saveStagedThumbnail(old, 'missing', Uint8List.fromList([8])),
        throwsA(isA<SnapshotConflictException>()),
      );
      await repository.abortPeerSnapshot(old);
      expect(await countThumbnails(), 1);
      expect((await repository.getMedia(_peer.id, 'kept'))!.thumbnail, [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'catalog deletion collects unused images without affecting another peer',
    () async {
      await repository.replacePeerSnapshot(_peer, [_media('photo')]);
      await repository.replacePeerSnapshot(_otherPeer, [
        _media('photo', deviceId: _otherPeer.id),
      ]);
      final obsolete = await repository.beginPeerSnapshot(_peer, 'obsolete', 1);
      await repository.stageMediaPage(obsolete, [_media('partial')]);
      await repository.saveStagedThumbnail(
        obsolete,
        'partial',
        Uint8List.fromList([8]),
      );
      expect(await countThumbnails(), 3);
      final session = await repository.beginPeerSnapshot(_peer, 'removed', 0);
      await repository.stageMediaPage(session, [], metadataComplete: true);
      await repository.commitPeerSnapshot(session);
      expect(await countThumbnails(), 1);
      expect(await repository.getMedia(_peer.id, 'photo'), isNull);
      expect((await repository.getMedia(_otherPeer.id, 'photo'))!.thumbnail, [
        1,
        2,
        3,
      ]);
      await repository.replacePeerSnapshot(_otherPeer, []);
      expect(await countThumbnails(), 0);
    },
  );

  test(
    '5000-image incremental staging writes metadata and one new image only',
    () async {
      const imageCount = 5000;
      const imageSize = 20 * 1024;
      final bytes = Uint8List(imageSize)..fillRange(0, imageSize, 42);
      final original = List.generate(
        imageCount,
        (index) => _media('photo-$index', thumbnail: bytes),
      );
      await repository.replacePeerSnapshot(_peer, original);
      final baselineBytes = await allocatedBytes();
      final session = await repository.beginPeerSnapshot(
        _peer,
        'one-added',
        imageCount + 1,
      );
      final updated = [...original, _media('new', thumbnail: bytes)];
      final missing = <MediaMetadata>[];
      for (var offset = 0; offset < updated.length; offset += 500) {
        final end = offset + 500 < updated.length
            ? offset + 500
            : updated.length;
        missing.addAll(
          await repository.stageMediaPage(
            session,
            updated.sublist(offset, end),
            metadataComplete: end == updated.length,
          ),
        );
      }
      expect(missing.map((item) => item.id), ['new']);
      expect(await countThumbnails(), imageCount);
      expect(
        Sqflite.firstIntValue(
          await inspection.rawQuery(
            '''SELECT COUNT(*) FROM sync_media s JOIN media m
          ON m.device_id = ? AND m.id = s.id
          WHERE s.session_id = ? AND s.thumbnail_id = m.thumbnail_id''',
            [_peer.id, session],
          ),
        ),
        imageCount,
      );
      final stagedBytes = await allocatedBytes();
      // A generous allowance for metadata/index page sizes, still far below the
      // roughly 100 MiB required to duplicate all 5000 thumbnail BLOBs.
      expect(stagedBytes - baselineBytes, lessThan(8 * 1024 * 1024));
      await repository.saveStagedThumbnail(session, 'new', bytes);
      expect(await countThumbnails(), imageCount + 1);
      final addedImageId = await stagedId(session, 'new');
      await repository.commitPeerSnapshot(session);
      expect(await committedId('new'), addedImageId);
      expect(await repository.countMedia(), imageCount + 1);
      expect(await countThumbnails(), imageCount + 1);
      expect(
        Sqflite.firstIntValue(
          await inspection.rawQuery(
            'SELECT SUM(length(bytes)) FROM thumbnails',
          ),
        ),
        (imageCount + 1) * imageSize,
      );
      final committedBytes = await allocatedBytes();
      expect(committedBytes - baselineBytes, lessThan(8 * 1024 * 1024));
      expect(await inspection.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      // Report actual allocation growth alongside the regression threshold.
      // ignore: avoid_print
      print(
        '5000 x 20 KiB thumbnails: staging grew ${stagedBytes - baselineBytes} '
        'bytes; committed growth ${committedBytes - baselineBytes} bytes.',
      );
    },
  );
}
