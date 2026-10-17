import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository, StubRpcClient;

class _SortRepository extends GatedRepository {
  _SortRepository(super.inner);

  int pageReads = 0;
  Future<void> Function(MediaSortOrder order, MediaCursor? after)?
  beforePageRead;

  @override
  Future<MediaPage> listMediaPage({
    String? deviceId,
    String? sharedFolderId,
    MediaSortOrder sortOrder = MediaSortOrder.dateDescending,
    MediaCursor? after,
    int limit = 60,
  }) async {
    pageReads++;
    await beforePageRead?.call(sortOrder, after);
    return super.listMediaPage(
      deviceId: deviceId,
      sharedFolderId: sharedFolderId,
      sortOrder: sortOrder,
      after: after,
      limit: limit,
    );
  }
}

const _phoneA = Peer(
  id: 'phone-a',
  name: 'Phone A',
  host: '192.0.2.1',
  port: 50728,
);
const _phoneB = Peer(
  id: 'phone-b',
  name: 'Phone B',
  host: '192.0.2.2',
  port: 50728,
);

List<MediaItem> _photos(String device, String folder, int count) =>
    List.generate(count, (index) {
      final name = 'photo-${index.toString().padLeft(3, '0')}.jpg';
      return MediaItem(
        id: '$folder-$index',
        deviceId: device,
        name: name,
        sharedFolderId: folder,
        sharedFolderName: folder,
        relativePath: 'photos/$name',
        mimeType: 'image/jpeg',
        size: 3,
        // Unique dates unrelated to name order distinguish all four choices.
        modifiedMs: 100000 + ((index * 37) % count),
        thumbnail: Uint8List(0),
      );
    });

List<MediaItem> _sorted(List<MediaItem> items, MediaSortOrder order) {
  final result = [...items];
  result.sort((left, right) {
    final comparison = switch (order) {
      MediaSortOrder.nameAscending ||
      MediaSortOrder.nameDescending => left.name.compareTo(right.name),
      MediaSortOrder.dateAscending || MediaSortOrder.dateDescending =>
        left.modifiedMs.compareTo(right.modifiedMs),
    };
    return switch (order) {
      MediaSortOrder.nameAscending ||
      MediaSortOrder.dateAscending => comparison,
      MediaSortOrder.nameDescending ||
      MediaSortOrder.dateDescending => -comparison,
    };
  });
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late TamayuraRepository db;
  late _SortRepository repository;
  late FakeBridge bridge;
  late TransferStore tasks;
  late AppController model;
  late Directory temporary;
  late List<MediaItem> mainPhotos;
  late List<MediaItem> otherPhotos;
  late List<MediaItem> phoneBPhotos;

  setUp(() async {
    db = await TamayuraRepository.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    mainPhotos = _photos(_phoneA.id, 'camera', 121);
    otherPhotos = _photos(_phoneA.id, 'other', 7);
    phoneBPhotos = _photos(_phoneB.id, 'camera', 9);
    await db.replacePeerSnapshot(_phoneA, [
      ...mainPhotos.reversed,
      ...otherPhotos,
    ]);
    await db.replacePeerSnapshot(_phoneB, phoneBPhotos);
    repository = _SortRepository(db);
    bridge = FakeBridge();
    temporary = await Directory.systemTemp.createTemp('tamayura-album-sort-');
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: databaseFactoryFfi,
    );
    model = AppController(
      bridge: bridge,
      preferredPort: 0,
      openRepository: () async => repository,
      openTransfers: () async => tasks,
      clientFactory: (peer) => StubRpcClient(
        peer,
        onIdentity: () async {
          throw const SocketException('offline cached device');
        },
      ),
    );
    model.setForeground(false);
    await model.initialize();
    await model.selectCollection('${_phoneA.id}/camera');
  });

  tearDown(() async {
    await model.shutdown();
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  for (final order in MediaSortOrder.values) {
    test(
      '$order sorts the entire selected collection before pagination',
      () async {
        final expected = _sorted(
          mainPhotos,
          order,
        ).map((item) => item.key).toList();
        await model.setMediaSortOrder(order);
        expect(model.mediaSortOrder, order);
        expect(model.mediaSortOrderChanging, isFalse);
        expect(model.totalMediaCount, 121);
        expect(model.media.map((item) => item.key), expected.take(60));
        expect(model.hasMoreMedia, isTrue);

        await model.loadMoreMedia();
        expect(model.media.map((item) => item.key), expected.take(120));
        expect(model.hasMoreMedia, isTrue);
        await model.loadMoreMedia();
        expect(model.media.map((item) => item.key), expected);
        expect(model.media.map((item) => item.key).toSet(), hasLength(121));
        expect(model.hasMoreMedia, isFalse);
        expect(model.error, isNull);
      },
    );
  }

  test(
    'switching order restarts a fully loaded collection at the first page',
    () async {
      expect(model.mediaSortOrder, MediaSortOrder.dateDescending);
      await model.loadMoreMedia();
      await model.loadMoreMedia();
      expect(model.media, hasLength(121));

      await model.setMediaSortOrder(MediaSortOrder.nameDescending);
      final expected = _sorted(
        mainPhotos,
        MediaSortOrder.nameDescending,
      ).map((item) => item.key).toList();
      expect(model.media.map((item) => item.key), expected.take(60));
      expect(model.totalMediaCount, 121);
      expect(model.hasMoreMedia, isTrue);
      await model.loadMoreMedia();
      expect(model.media.map((item) => item.key), expected.take(120));
      await model.loadMoreMedia();
      expect(model.media.map((item) => item.key), expected);
    },
  );

  test(
    'reselecting the current order preserves pages without a read or notification',
    () async {
      await model.loadMoreMedia();
      final pageReads = repository.pageReads;
      final expected = model.media.map((item) => item.key).toList();
      var notifications = 0;
      model.addListener(() => notifications++);

      await model.setMediaSortOrder(MediaSortOrder.dateDescending);

      expect(repository.pageReads, pageReads);
      expect(notifications, 0);
      expect(model.media.map((item) => item.key), expected);
      expect(model.media, hasLength(120));
      expect(model.hasMoreMedia, isTrue);
    },
  );

  test(
    'session order survives collection, device, and refresh changes',
    () async {
      const order = MediaSortOrder.nameDescending;
      var settingWrites = 0;
      repository.beforeSettingWrite = (_, _) async => settingWrites++;
      await model.setMediaSortOrder(order);
      expect(settingWrites, 0, reason: 'Album sorting is a session preference');

      await model.selectCollection('${_phoneA.id}/other');
      expect(model.mediaSortOrder, order);
      expect(
        model.media.map((item) => item.key),
        _sorted(otherPhotos, order).map((item) => item.key),
      );
      await model.selectDevice(_phoneB.id);
      await model.selectCollection('${_phoneB.id}/camera');
      expect(model.mediaSortOrder, order);
      expect(
        model.media.map((item) => item.key),
        _sorted(phoneBPhotos, order).map((item) => item.key),
      );
      await model.refresh();
      expect(model.mediaSortOrder, order);
      expect(
        model.media.map((item) => item.key),
        _sorted(phoneBPhotos, order).map((item) => item.key),
      );
      await model.selectDevice(_phoneA.id);
      await model.selectCollection('${_phoneA.id}/camera');
      expect(model.mediaSortOrder, order);
      expect(
        model.media.map((item) => item.key),
        _sorted(mainPhotos, order).take(60).map((item) => item.key),
      );
    },
  );

  test(
    'pending sort keeps the current page and blocks overlapping sort and page reads',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final oldPage = model.media.map((item) => item.key).toList();
      final observed = <bool>[];
      model.addListener(() => observed.add(model.mediaSortOrderChanging));
      repository.beforePageRead = (order, after) async {
        if (order == MediaSortOrder.nameDescending && after == null) {
          entered.complete();
          await release.future;
        }
      };
      final changing = model.setMediaSortOrder(MediaSortOrder.nameDescending);
      try {
        await entered.future.timeout(const Duration(seconds: 3));
        expect(model.mediaSortOrderChanging, isTrue);
        expect(model.mediaSortOrder, MediaSortOrder.dateDescending);
        expect(model.media.map((item) => item.key), oldPage);
        final pageReads = repository.pageReads;
        await model.setMediaSortOrder(MediaSortOrder.dateAscending);
        await model.loadMoreMedia();
        expect(repository.pageReads, pageReads);
      } finally {
        release.complete();
        await changing;
      }
      expect(model.mediaSortOrderChanging, isFalse);
      expect(model.mediaSortOrder, MediaSortOrder.nameDescending);
      expect(observed, containsAllInOrder([true, false]));
      expect(
        model.media.map((item) => item.key),
        _sorted(
          mainPhotos,
          MediaSortOrder.nameDescending,
        ).take(60).map((item) => item.key),
      );
    },
  );

  test(
    'a page already appending cannot contaminate a newly sorted collection',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final firstOldPageItem = _sorted(
        mainPhotos,
        MediaSortOrder.dateDescending,
      )[60];
      repository.beforeDownloadRead = (device, id) async {
        if (device == firstOldPageItem.deviceId &&
            id == firstOldPageItem.id &&
            !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final loading = model.loadMoreMedia();
      final expected = _sorted(
        mainPhotos,
        MediaSortOrder.nameDescending,
      ).map((item) => item.key).toList();
      try {
        await entered.future.timeout(const Duration(seconds: 3));
        expect(model.loadingMoreMedia, isTrue);
        await model.setMediaSortOrder(MediaSortOrder.nameDescending);
        expect(model.media.map((item) => item.key), expected.take(60));
      } finally {
        release.complete();
        await loading;
      }
      expect(model.media.map((item) => item.key), expected.take(60));
      expect(model.loadingMoreMedia, isFalse);
      await model.loadMoreMedia();
      expect(model.media.map((item) => item.key), expected.take(120));
      expect(model.error, isNull);
    },
  );

  test(
    'a stale page failure does not replace a successful sort with an error',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      repository.beforePageRead = (order, after) async {
        if (after != null && order == MediaSortOrder.dateDescending) {
          entered.complete();
          await release.future;
          throw StateError('old page read failed');
        }
      };
      final loading = model.loadMoreMedia();
      try {
        await entered.future.timeout(const Duration(seconds: 3));
        await model.setMediaSortOrder(MediaSortOrder.nameDescending);
      } finally {
        release.complete();
        await loading;
      }
      expect(model.mediaSortOrder, MediaSortOrder.nameDescending);
      expect(model.media, hasLength(60));
      expect(model.error, isNull);
      expect(model.loadingMoreMedia, isFalse);
    },
  );

  test(
    'failed sort preserves the prior page and cursor and can be retried',
    () async {
      final expectedOld = _sorted(
        mainPhotos,
        MediaSortOrder.dateDescending,
      ).map((item) => item.key).toList();
      repository.beforePageRead = (order, after) async {
        if (order == MediaSortOrder.nameDescending) {
          throw StateError('catalog read failed');
        }
      };
      await model.setMediaSortOrder(MediaSortOrder.nameDescending);
      expect(model.error, isNotNull);
      expect(model.mediaSortOrderChanging, isFalse);
      expect(model.mediaSortOrder, MediaSortOrder.dateDescending);
      expect(model.media.map((item) => item.key), expectedOld.take(60));
      expect(model.hasMoreMedia, isTrue);
      await model.loadMoreMedia();
      expect(model.media.map((item) => item.key), expectedOld.take(120));

      repository.beforePageRead = null;
      await model.setMediaSortOrder(MediaSortOrder.nameDescending);
      expect(model.error, isNull);
      expect(model.mediaSortOrderChanging, isFalse);
      expect(model.mediaSortOrder, MediaSortOrder.nameDescending);
      final expectedNew = _sorted(
        mainPhotos,
        MediaSortOrder.nameDescending,
      ).map((item) => item.key).toList();
      expect(model.media.map((item) => item.key), expectedNew.take(60));
      await model.loadMoreMedia();
      expect(model.media.map((item) => item.key), expectedNew.take(120));
    },
  );

  for (final switchDevice in [false, true]) {
    test(
      'pending sort applies to the latest ${switchDevice ? 'device' : 'collection'} filter',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        repository.beforePageRead = (order, after) async {
          if (order == MediaSortOrder.nameDescending && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final changing = model.setMediaSortOrder(MediaSortOrder.nameDescending);
        Future<void>? filtering;
        try {
          await entered.future.timeout(const Duration(seconds: 3));
          filtering = switchDevice
              ? model.selectDevice(_phoneB.id)
              : model.selectCollection('${_phoneA.id}/other');
        } finally {
          release.complete();
          await changing;
          await filtering;
        }
        expect(model.mediaSortOrder, MediaSortOrder.nameDescending);
        expect(model.mediaSortOrderChanging, isFalse);
        expect(
          model.selectedCollectionKey,
          switchDevice ? isNull : '${_phoneA.id}/other',
        );
        if (switchDevice) expect(model.selectedDeviceId, _phoneB.id);
        expect(
          model.media.map((item) => item.key),
          _sorted(
            switchDevice ? phoneBPhotos : otherPhotos,
            MediaSortOrder.nameDescending,
          ).map((item) => item.key),
        );
        expect(model.error, isNull);
      },
    );
  }

  test(
    'failed sort after collection removal retains the previous filter and cursor',
    () async {
      await model.selectDevice(_phoneA.id);
      await model.selectCollection('${_phoneA.id}/camera');
      await model.loadMoreMedia();
      final expectedOld = _sorted(
        mainPhotos,
        MediaSortOrder.dateDescending,
      ).map((item) => item.key).toList();
      final oldCollections = model.collections.map((item) => item.key).toList();
      await db.replacePeerSnapshot(_phoneA, otherPhotos);
      repository.beforePageRead = (order, after) async {
        if (order == MediaSortOrder.nameDescending) {
          throw StateError('catalog read failed after collection removal');
        }
      };

      await model.setMediaSortOrder(MediaSortOrder.nameDescending);

      expect(model.error, isNotNull);
      expect(model.mediaSortOrder, MediaSortOrder.dateDescending);
      expect(model.selectedCollectionKey, '${_phoneA.id}/camera');
      expect(model.collections.map((item) => item.key), oldCollections);
      expect(model.media.map((item) => item.key), expectedOld.take(120));
      expect(model.totalMediaCount, 121);
      expect(model.hasMoreMedia, isTrue);

      // If the folder returns, the preserved cursor still belongs to it.
      await db.replacePeerSnapshot(_phoneA, [...mainPhotos, ...otherPhotos]);
      repository.beforePageRead = null;
      await model.loadMoreMedia();
      expect(model.media.map((item) => item.key), expectedOld);
      expect(model.hasMoreMedia, isFalse);

      // A successful retry can then apply the missing-collection fallback.
      await db.replacePeerSnapshot(_phoneA, otherPhotos);
      await model.setMediaSortOrder(MediaSortOrder.nameDescending);
      expect(model.selectedCollectionKey, isNull);
      expect(model.mediaSortOrder, MediaSortOrder.nameDescending);
      expect(model.error, isNull);
      expect(
        model.media.map((item) => item.key),
        _sorted(
          otherPhotos,
          MediaSortOrder.nameDescending,
        ).map((item) => item.key),
      );
    },
  );
}
