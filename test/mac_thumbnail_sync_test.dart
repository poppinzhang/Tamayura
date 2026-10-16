import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/network/media_rpc.dart';

const _peer = Peer(id: 'mac-source', name: 'Mac', host: '127.0.0.1', port: 0);

class _Source implements LocalMediaSource {
  bool failMissingThumbnail = true;
  List<String> ids = ['available', 'deleted'];
  final requested = <String>[];

  @override
  Future<List<MediaMetadata>> scan() async => ids
      .map(
        (id) => MediaMetadata(
          id: id,
          deviceId: _peer.id,
          name: '$id.jpg',
          mimeType: 'image/jpeg',
          size: 100,
          modifiedMs: 1,
          sharedFolderId: 'photos',
          sharedFolderName: 'Photos',
          relativePath: '$id.jpg',
        ),
      )
      .toList();

  @override
  Future<Uint8List> readThumbnail(String id) async {
    requested.add(id);
    if (id == 'deleted') {
      if (failMissingThumbnail) throw const FileSystemException('File deleted');
      return Uint8List(0);
    }
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      throw const FileSystemException('File deleted');
}

void main() {
  sqfliteFfiInit();

  test(
    'an empty thumbnail completes an existing checkpoint and later scan removes the file',
    () async {
      final repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final source = _Source();
      final server = MediaRpcServer(identity: _peer, source: source);
      await server.start();
      final client = MediaRpcClient(_peer.copyWith(port: server.port));
      addTearDown(() async {
        await client.close();
        await server.stop();
        await repository.close();
      });

      await expectLater(
        client.synchronize(repository),
        throwsA(isA<GrpcError>()),
      );
      expect(await repository.findPeerSnapshot(_peer), isNotNull);
      source.failMissingThumbnail = false;
      source.requested.clear();

      final resumed = await client.synchronize(repository);
      expect(resumed.thumbnailRequests, 1);
      expect(source.requested, ['deleted']);
      expect(
        (await repository.getMedia(_peer.id, 'deleted'))!.thumbnail,
        isEmpty,
      );
      expect((await repository.getMedia(_peer.id, 'available'))!.thumbnail, [
        1,
        2,
        3,
      ]);
      expect(await repository.findPeerSnapshot(_peer), isNull);
      expect((await client.synchronize(repository)).thumbnailRequests, 0);

      source.ids = ['available'];
      await server.refresh();
      await client.synchronize(repository);
      expect(await repository.getMedia(_peer.id, 'deleted'), isNull);
      expect((await repository.listMedia()).single.id, 'available');
    },
  );
}
