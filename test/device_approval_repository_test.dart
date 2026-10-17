import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';

const _phone = Peer(
  id: 'phone',
  name: 'Phone',
  host: '192.168.1.2',
  port: 50728,
);
const _tablet = Peer(
  id: 'tablet',
  name: 'Tablet',
  host: '192.168.1.3',
  port: 50728,
);

MediaItem _media(String id, {String deviceId = 'phone', List<int>? bytes}) =>
    MediaItem(
      id: id,
      deviceId: deviceId,
      name: '$id.jpg',
      sharedFolderId: 'camera',
      sharedFolderName: 'Camera',
      relativePath: '$id.jpg',
      mimeType: 'image/jpeg',
      size: 123,
      modifiedMs: 1,
      thumbnail: Uint8List.fromList(bytes ?? [1, 2, 3]),
    );

void main() {
  sqfliteFfiInit();
  late Directory folder;
  late String path;
  late TamayuraRepository repository;
  late Database inspection;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('tamayura-approval-');
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

  Future<int> count(String sql, [List<Object?> arguments = const []]) async =>
      Sqflite.firstIntValue(await inspection.rawQuery(sql, arguments))!;

  Future<Peer> saved(String id) async =>
      (await repository.listPeers()).singleWhere((peer) => peer.id == id);

  group('sync approval', () {
    test(
      'discovered devices are pending; synced devices are approved',
      () async {
        expect(
          await repository.rememberDiscoveredPeer(_phone),
          PeerSyncApproval.pending,
        );
        await repository.upsertPeer(_tablet);
        expect((await saved('phone')).syncApproval, PeerSyncApproval.pending);
        expect((await saved('tablet')).syncApproval, PeerSyncApproval.approved);
      },
    );

    test('rediscovery updates the address but keeps the decision', () async {
      await repository.rememberDiscoveredPeer(_phone);
      expect(
        await repository.setPeerSyncApproval(
          'phone',
          PeerSyncApproval.declined,
        ),
        isTrue,
      );
      final moved = _phone.copyWith(host: '192.168.1.9', name: 'Renamed');
      expect(
        await repository.rememberDiscoveredPeer(moved),
        PeerSyncApproval.declined,
      );
      final peer = await saved('phone');
      expect(peer.host, moved.host);
      expect(peer.name, moved.name);
      expect(peer.syncApproval, PeerSyncApproval.declined);

      // Discovering an already approved device never demotes it.
      await repository.upsertPeer(_tablet);
      expect(
        await repository.rememberDiscoveredPeer(_tablet),
        PeerSyncApproval.approved,
      );
    });

    test('address and attempt writes never change the decision', () async {
      await repository.rememberDiscoveredPeer(_phone);
      await repository.upsertPeer(
        _phone.copyWith(host: '192.168.1.8', lastSync: DateTime(2026)),
      );
      await repository.markPeerSynced(_phone);
      expect((await saved('phone')).syncApproval, PeerSyncApproval.pending);
    });

    test('approval of an unknown device reports false', () async {
      expect(
        await repository.setPeerSyncApproval(
          'missing',
          PeerSyncApproval.approved,
        ),
        isFalse,
      );
      expect(await repository.listPeers(), isEmpty);
    });
  });

  group('last attempt failure', () {
    test('an attempt stays failed until a catalog commit succeeds', () async {
      await repository.upsertPeer(_phone);
      expect((await saved('phone')).lastSyncFailed, isFalse);
      await repository.upsertPeer(_phone.copyWith(lastSync: DateTime(2026)));
      expect((await saved('phone')).lastSyncFailed, isTrue);
      // Presence updates without an attempt time leave it unchanged.
      await repository.upsertPeer(_phone.copyWith(host: '192.168.1.7'));
      expect((await saved('phone')).lastSyncFailed, isTrue);

      final session = await repository.beginPeerSnapshot(_phone, 'one', 1);
      await repository.stageMediaPage(session, [_media('a')]);
      await repository.saveStagedThumbnail(session, 'a', Uint8List(0));
      expect((await saved('phone')).lastSyncFailed, isTrue);
      await repository.commitPeerSnapshot(session);
      expect((await saved('phone')).lastSyncFailed, isFalse);
    });

    test('an unchanged catalog confirmation also clears it', () async {
      await repository.upsertPeer(_phone.copyWith(lastSync: DateTime(2026)));
      await repository.markPeerSynced(_phone);
      expect((await saved('phone')).lastSyncFailed, isFalse);
    });

    test('the flag and decision survive reopening the database', () async {
      await repository.rememberDiscoveredPeer(_phone);
      await repository.setPeerSyncApproval('phone', PeerSyncApproval.approved);
      await repository.upsertPeer(_phone.copyWith(lastSync: DateTime(2026)));
      await repository.close();
      repository = await TamayuraRepository.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      final peer = await saved('phone');
      expect(peer.syncApproval, PeerSyncApproval.approved);
      expect(peer.lastSyncFailed, isTrue);
    });
  });

  group('forget', () {
    test(
      'removes the device, its catalog, stages and unused thumbnails',
      () async {
        await repository.replacePeerSnapshot(_phone, [
          _media('a', bytes: [1]),
          _media('b', bytes: [2]),
        ]);
        await repository.replacePeerSnapshot(_tablet, [
          _media('c', deviceId: 'tablet', bytes: [3]),
        ]);
        final stage = await repository.beginPeerSnapshot(_phone, 'next', 3);
        await repository.stageMediaPage(stage, [
          _media('a', bytes: [1]),
          _media('b', bytes: [2]),
          _media('new'),
        ]);
        await repository.saveStagedThumbnail(
          stage,
          'new',
          Uint8List.fromList([9, 9]),
        );
        await repository.saveDownload(
          DownloadRecord(
            deviceId: 'phone',
            mediaId: 'a',
            uri: 'file:///saved/a.jpg',
            completedAt: DateTime(2026),
          ),
        );
        expect(await count('SELECT COUNT(*) FROM thumbnails'), 4);
        // The preview stage is visible before forgetting.
        expect(await repository.countMedia(deviceId: 'phone'), 3);

        await repository.forgetPeer('phone');

        expect((await repository.listPeers()).map((peer) => peer.id), [
          'tablet',
        ]);
        expect(await repository.countMedia(deviceId: 'phone'), 0);
        expect(await repository.countMedia(), 1);
        expect(
          await count("SELECT COUNT(*) FROM media WHERE device_id = 'phone'"),
          0,
        );
        expect(await count('SELECT COUNT(*) FROM sync_sessions'), 0);
        expect(await count('SELECT COUNT(*) FROM sync_media'), 0);
        expect(
          await count('SELECT COUNT(*) FROM thumbnails'),
          1,
          reason: 'Only the other device still references a thumbnail',
        );
        expect(await inspection.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        expect(
          (await repository.getDownload('phone', 'a'))?.uri,
          'file:///saved/a.jpg',
          reason: 'Saved files and their history are kept',
        );
        expect(await repository.findPeerSnapshot(_phone), isNull);
        expect((await repository.mediaCollections()).single.deviceId, 'tablet');
      },
    );

    test('a forgotten device can be discovered again as new', () async {
      await repository.replacePeerSnapshot(_phone, [_media('a')]);
      await repository.forgetPeer('phone');
      expect(
        await repository.rememberDiscoveredPeer(_phone),
        PeerSyncApproval.pending,
      );
      final peer = await saved('phone');
      expect(peer.lastSuccessfulSync, isNull);
      expect(peer.lastSync, isNull);
      expect(await repository.peerRevision('phone'), isNull);
      expect(await repository.countMedia(deviceId: 'phone'), 0);
    });

    test('forgetting an unknown device is a no-op', () async {
      await repository.replacePeerSnapshot(_tablet, [
        _media('c', deviceId: 'tablet'),
      ]);
      await repository.forgetPeer('missing');
      expect(await repository.countMedia(), 1);
      expect(await count('SELECT COUNT(*) FROM thumbnails'), 1);
    });
  });
}
