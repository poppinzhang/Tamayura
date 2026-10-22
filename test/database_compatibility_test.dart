import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/l10n/app_locale.dart';

import 'controller_test.dart' show FakeBridge;

const _peer = Peer(
  id: 'source',
  name: 'Source',
  host: '127.0.0.1',
  port: 50728,
);

MediaItem _item(String id) => MediaItem(
  id: id,
  deviceId: _peer.id,
  name: '$id.jpg',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 10,
  modifiedMs: 123,
  thumbnail: Uint8List.fromList([1, 2, 3]),
);

Future<TamayuraRepository> _openCatalog(String path) =>
    TamayuraRepository.open(path: path, factory: databaseFactoryFfi);

Future<TransferStore> _openTransfers(String path) =>
    TransferStore.open(path: path, factory: databaseFactoryFfi);

Future<Database> _inspect(String path) => databaseFactoryFfi.openDatabase(
  path,
  options: OpenDatabaseOptions(singleInstance: false),
);

Future<void> _setVersion(String path, int version) async {
  final database = await _inspect(path);
  try {
    await database.setVersion(version);
  } finally {
    await database.close();
  }
}

Future<Map<String, Object>> _snapshot(String path) async {
  final database = await _inspect(path);
  try {
    final schema = await database.rawQuery(
      'SELECT * FROM sqlite_master ORDER BY type, name',
    );
    return {
      'version': await database.getVersion(),
      'schema': schema,
      for (final table in schema.where((row) => row['type'] == 'table'))
        table['name']! as String: await database.query(
          table['name']! as String,
          orderBy: 'rowid',
        ),
    };
  } finally {
    await database.close();
  }
}

class _StartupBridge extends FakeBridge {
  _StartupBridge(this.directory);
  final String directory;
  int transferDirectoryReads = 0;
  int scheduledTransferReads = 0;

  @override
  Future<String> transferDirectory() async {
    transferDirectoryReads++;
    return directory;
  }

  @override
  Future<List<String>> scheduledTransferIds() async {
    scheduledTransferReads++;
    return [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temporary;
  late String catalogPath;
  late String transferPath;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tamayura-schema-test-');
    catalogPath = '${temporary.path}/catalog.db';
    transferPath = '${temporary.path}/transfers.db';
    final repository = await _openCatalog(catalogPath);
    try {
      await repository.setSetting('language', 'ja');
      await repository.setSetting('sharedFolders', '[]');
      await repository.replacePeerSnapshot(_peer, [_item('saved')]);
      await repository.saveDownload(
        DownloadRecord(
          deviceId: _peer.id,
          mediaId: 'saved',
          uri: 'content://received/saved.jpg',
          completedAt: DateTime(2026),
        ),
      );
      final session = await repository.beginPeerSnapshot(_peer, 'next', 1);
      await repository.stageMediaPage(session, [_item('next')]);
      await repository.saveStagedThumbnail(
        session,
        'next',
        Uint8List.fromList([4, 5, 6]),
      );
    } finally {
      await repository.close();
    }
    final transfers = await _openTransfers(transferPath);
    try {
      final task = await transfers.enqueue(
        _peer,
        _item('next'),
        'content://received',
      );
      await transfers.update(task.id, {'received': 3, 'state': 'failed'});
    } finally {
      await transfers.close();
    }
  });

  tearDown(() => temporary.delete(recursive: true));

  test('v1.0.0 schemas reopen without modifying existing user data', () async {
    final catalogBefore = await _snapshot(catalogPath);
    final transfersBefore = await _snapshot(transferPath);
    expect(catalogBefore['version'], 7);
    expect(transfersBefore['version'], 3);

    final repository = await _openCatalog(catalogPath);
    final transfers = await _openTransfers(transferPath);
    try {
      expect(await repository.getSetting('language'), 'ja');
      expect((await repository.listPeers()).single.id, _peer.id);
      expect(await repository.getDownload(_peer.id, 'saved'), isNotNull);
      expect(await repository.findPeerSnapshot(_peer), isNotNull);
      expect((await transfers.recent()).single.received, 3);
    } finally {
      await repository.close();
      await transfers.close();
    }

    expect(await _snapshot(catalogPath), catalogBefore);
    expect(await _snapshot(transferPath), transfersBefore);
  });

  for (final (name, currentVersion) in [('catalog', 7), ('transfers', 3)]) {
    for (final version in [1, currentVersion - 1, currentVersion + 1, 99]) {
      test('$name rejects schema $version and preserves all data', () async {
        final path = name == 'catalog' ? catalogPath : transferPath;
        await _setVersion(path, version);
        final before = await _snapshot(path);
        final opening = name == 'catalog'
            ? _openCatalog(path)
            : _openTransfers(path);

        await expectLater(
          opening,
          throwsA(
            isA<FormatException>().having(
              (error) => describeError(error),
              'user-visible error',
              AppLocale.strings.errorDatabaseVersionUnsupported,
            ),
          ),
        );
        expect(await _snapshot(path), before);
      });
    }
  }

  for (final incompatibleStore in ['catalog', 'transfers']) {
    test(
      'incompatible $incompatibleStore stops startup before cleanup',
      () async {
        await _setVersion(
          incompatibleStore == 'catalog' ? catalogPath : transferPath,
          99,
        );
        final catalogBefore = await _snapshot(catalogPath);
        final transfersBefore = await _snapshot(transferPath);
        final staging = await Directory('${temporary.path}/staging').create();
        final part = await File(
          '${staging.path}/retained.part',
        ).writeAsBytes([4, 5, 6]);
        final bridge = _StartupBridge(staging.path);
        final controller = AppController(
          bridge: bridge,
          preferredPort: 0,
          openRepository: () => _openCatalog(catalogPath),
          openTransfers: () => _openTransfers(transferPath),
        );
        try {
          await controller.initialize();
          expect(
            controller.error,
            AppLocale.strings.errorDatabaseVersionUnsupported,
          );
          expect(controller.loading, isFalse);
          expect(bridge.transferDirectoryReads, 0);
          expect(bridge.scheduledTransferReads, 0);
        } finally {
          await controller.shutdown();
          await bridge.events.close();
        }
        expect(await part.readAsBytes(), [4, 5, 6]);
        expect(await _snapshot(catalogPath), catalogBefore);
        expect(await _snapshot(transferPath), transfersBefore);
      },
    );
  }
}
