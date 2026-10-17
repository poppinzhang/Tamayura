import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';

const _firstPeer = Peer(
  id: 'device-a',
  name: 'First device',
  host: 'localhost',
  port: 4000,
);
const _secondPeer = Peer(
  id: 'device-b',
  name: 'Second device',
  host: 'localhost',
  port: 4001,
);

MediaItem _media(
  String id,
  String name,
  int date, {
  String deviceId = 'device-a',
  String folder = 'camera',
}) => MediaItem(
  id: id,
  deviceId: deviceId,
  name: name,
  mimeType: 'image/jpeg',
  size: 100,
  modifiedMs: date,
  sharedFolderId: folder,
  sharedFolderName: folder,
  relativePath: '$id/$name',
  thumbnail: Uint8List.fromList([1, 2, 3]),
);

final _catalog = [
  _media('zeta', 'Zebra.jpg', 300),
  _media('tie-b', 'same.jpg', 200),
  _media('tie-a', 'same.jpg', 200),
  _media('lower', 'alpha.jpg', 100),
  _media('numeric-10', 'img10.jpg', 50, folder: 'holiday'),
  _media('numeric-2', 'img2.jpg', 60, folder: 'holiday'),
  _media('tie-b', 'same.jpg', 200, deviceId: _secondPeer.id),
  _media('accent', 'é.jpg', 400, deviceId: _secondPeer.id),
  _media('upper', 'Alpha.jpg', 0, deviceId: _secondPeer.id, folder: 'holiday'),
];

const _expected = {
  MediaSortOrder.nameAscending: [
    'device-b/upper',
    'device-a/zeta',
    'device-a/lower',
    'device-a/numeric-10',
    'device-a/numeric-2',
    'device-a/tie-a',
    'device-a/tie-b',
    'device-b/tie-b',
    'device-b/accent',
  ],
  MediaSortOrder.nameDescending: [
    'device-b/accent',
    'device-a/tie-a',
    'device-a/tie-b',
    'device-b/tie-b',
    'device-a/numeric-2',
    'device-a/numeric-10',
    'device-a/lower',
    'device-a/zeta',
    'device-b/upper',
  ],
  MediaSortOrder.dateAscending: [
    'device-b/upper',
    'device-a/numeric-10',
    'device-a/numeric-2',
    'device-a/lower',
    'device-a/tie-a',
    'device-a/tie-b',
    'device-b/tie-b',
    'device-a/zeta',
    'device-b/accent',
  ],
  MediaSortOrder.dateDescending: [
    'device-b/accent',
    'device-a/zeta',
    'device-a/tie-a',
    'device-a/tie-b',
    'device-b/tie-b',
    'device-a/lower',
    'device-a/numeric-2',
    'device-a/numeric-10',
    'device-b/upper',
  ],
};

Future<void> _seed(TamayuraRepository repository) async {
  for (final peer in [_firstPeer, _secondPeer]) {
    await repository.replacePeerSnapshot(
      peer,
      _catalog.where((item) => item.deviceId == peer.id).toList(),
    );
  }
}

Future<List<String>> _readAllPages(
  TamayuraRepository repository,
  MediaSortOrder order, {
  required int totalCount,
  String? deviceId,
  String? sharedFolderId,
  int limit = 2,
}) async {
  final keys = <String>[];
  MediaCursor? cursor;
  do {
    final page = await repository.listMediaPage(
      deviceId: deviceId,
      sharedFolderId: sharedFolderId,
      sortOrder: order,
      after: cursor,
      limit: limit,
    );
    expect(page.totalCount, totalCount);
    expect(page.items.length, lessThanOrEqualTo(limit));
    keys.addAll(page.items.map((item) => item.key));
    expect(keys.length, lessThanOrEqualTo(totalCount));
    cursor = page.nextCursor;
    if (cursor != null) {
      expect(page.items.length, limit);
      expect(cursor.sortOrder, order);
      expect(cursor.name, page.items.last.name);
      expect(cursor.modifiedMs, page.items.last.modifiedMs);
      expect(cursor.deviceId, page.items.last.deviceId);
      expect(cursor.mediaId, page.items.last.id);
    }
  } while (cursor != null);
  expect(keys, hasLength(totalCount));
  expect(keys.toSet(), hasLength(totalCount));
  return keys;
}

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

  for (final order in MediaSortOrder.values) {
    test(
      '$order sorts the entire library with stable paginated ties',
      () async {
        await _seed(repository);
        for (final limit in [1, 2, 3, 60]) {
          expect(
            await _readAllPages(
              repository,
              order,
              totalCount: _catalog.length,
              limit: limit,
            ),
            _expected[order],
          );
        }
      },
    );

    test(
      '$order preserves device and collection filters across pages',
      () async {
        await _seed(repository);
        for (final deviceId in [null, _firstPeer.id, _secondPeer.id]) {
          for (final folder in [null, 'camera', 'holiday', 'missing']) {
            final included = _catalog
                .where(
                  (item) =>
                      (deviceId == null || item.deviceId == deviceId) &&
                      (folder == null || item.sharedFolderId == folder),
                )
                .map((item) => item.key)
                .toSet();
            expect(
              await _readAllPages(
                repository,
                order,
                deviceId: deviceId,
                sharedFolderId: folder,
                totalCount: included.length,
                limit: 1,
              ),
              _expected[order]!.where(included.contains),
            );
          }
        }
      },
    );

    test('$order handles an empty catalog', () async {
      expect(await _readAllPages(repository, order, totalCount: 0), isEmpty);
    });

    test(
      '$order sorts ready staging metadata and committed media together',
      () async {
        await repository.replacePeerSnapshot(_firstPeer, [
          _media('kept', 'M.jpg', 50),
          _media('deleted', 'D.jpg', 15),
          _media('retained', 'L.jpg', 20, folder: 'holiday'),
        ]);
        await repository.replacePeerSnapshot(_secondPeer, [
          _media('remote', 'A.jpg', 30, deviceId: _secondPeer.id),
        ]);
        final session = await repository.beginPeerSnapshot(
          _firstPeer,
          'next',
          3,
        );
        final changed = _media('kept', 'Y.jpg', 45, folder: 'holiday');
        final added = _media('added', 'B.jpg', 40);
        final pending = _media('pending', 'C.jpg', 60);
        await repository.stageMediaPage(session, [changed, added, pending]);
        for (final ready in [changed, added]) {
          await repository.saveStagedThumbnail(
            session,
            ready.id,
            ready.thumbnail,
          );
        }
        final expected = switch (order) {
          MediaSortOrder.nameAscending => [
            'device-b/remote',
            'device-a/added',
            'device-a/deleted',
            'device-a/retained',
            'device-a/kept',
          ],
          MediaSortOrder.nameDescending => [
            'device-a/kept',
            'device-a/retained',
            'device-a/deleted',
            'device-a/added',
            'device-b/remote',
          ],
          MediaSortOrder.dateAscending => [
            'device-a/deleted',
            'device-a/retained',
            'device-b/remote',
            'device-a/added',
            'device-a/kept',
          ],
          MediaSortOrder.dateDescending => [
            'device-a/kept',
            'device-a/added',
            'device-b/remote',
            'device-a/retained',
            'device-a/deleted',
          ],
        };
        expect(await _readAllPages(repository, order, totalCount: 5), expected);
        expect(
          await _readAllPages(
            repository,
            order,
            deviceId: _firstPeer.id,
            sharedFolderId: 'holiday',
            totalCount: 2,
            limit: 1,
          ),
          expected.where(
            (key) => key == 'device-a/retained' || key == 'device-a/kept',
          ),
        );
      },
    );
  }

  test('the default remains date descending', () async {
    await _seed(repository);
    final page = await repository.listMediaPage();
    expect(
      page.items.map((item) => item.key),
      _expected[MediaSortOrder.dateDescending],
    );
  });

  test('a cursor cannot continue a different sort order', () async {
    await _seed(repository);
    final page = await repository.listMediaPage(
      sortOrder: MediaSortOrder.nameAscending,
      limit: 2,
    );
    for (final order in MediaSortOrder.values) {
      if (order == MediaSortOrder.nameAscending) continue;
      await expectLater(
        repository.listMediaPage(sortOrder: order, after: page.nextCursor),
        throwsArgumentError,
      );
    }
  });

  test('invalid page limits fail before querying', () async {
    for (final limit in [-1, 0, 201]) {
      await expectLater(
        repository.listMediaPage(
          sortOrder: MediaSortOrder.nameAscending,
          limit: limit,
        ),
        throwsArgumentError,
      );
    }
  });
}
