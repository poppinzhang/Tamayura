import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/core/transfer_task.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/media_rpc.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository, StubRpcClient;

const _timeout = Duration(seconds: 5);

class _ThumbnailGate {
  final requested = Completer<void>();
  final release = Completer<void>();
  final returned = Completer<void>();

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

/// Delay individual real RPC responses without pausing SQLite or the UI timer.
class _GatedSource implements LocalMediaSource {
  _GatedSource(this.deviceId, this.items);

  final String deviceId;
  List<MediaMetadata> items;
  final gates = <String, _ThumbnailGate>{};
  final failures = <String>{};
  final thumbnailRequests = <String>[];

  _ThumbnailGate hold(String id) => gates[id] = _ThumbnailGate();

  void releaseAll() {
    for (final gate in gates.values) {
      gate.open();
    }
  }

  @override
  Future<List<MediaMetadata>> scan() async => items;

  @override
  Future<Uint8List> readThumbnail(String id) async {
    thumbnailRequests.add(id);
    final gate = gates[id];
    try {
      if (gate != null) {
        if (!gate.requested.isCompleted) gate.requested.complete();
        await gate.release.future;
      }
      if (failures.contains(id)) throw StateError('thumbnail unavailable');
      return Uint8List.fromList([1, 2, 3]);
    } finally {
      if (gate != null && !gate.returned.isCompleted) gate.returned.complete();
    }
  }

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      Uint8List(length);
}

/// Preserve the real synchronization path while delaying page download lookups.
class _SyncGatedRepository extends GatedRepository {
  _SyncGatedRepository(super.inner);

  Future<void> Function(List<MediaCollection>)? afterCollectionsRead;
  void Function(String mediaId)? afterThumbnailSaved;

  @override
  Future<List<MediaCollection>> mediaCollections({String? deviceId}) async {
    final collections = await inner.mediaCollections(deviceId: deviceId);
    await afterCollectionsRead?.call(collections);
    return collections;
  }

  @override
  Future<void> upsertPeer(Peer peer) => inner.upsertPeer(peer);

  @override
  Future<String?> peerRevision(String deviceId) => inner.peerRevision(deviceId);

  @override
  Future<void> markPeerSynced(Peer peer) => inner.markPeerSynced(peer);

  @override
  Future<String> beginPeerSnapshot(
    Peer peer,
    String revision,
    int expectedCount,
  ) => inner.beginPeerSnapshot(peer, revision, expectedCount);

  @override
  Future<List<MediaMetadata>> stageMediaPage(
    String sessionId,
    List<MediaMetadata> items, {
    String? nextPageToken,
    bool metadataComplete = false,
  }) => inner.stageMediaPage(
    sessionId,
    items,
    nextPageToken: nextPageToken,
    metadataComplete: metadataComplete,
  );

  @override
  Future<List<MediaMetadata>> pendingSnapshotMedia(
    String sessionId, {
    int limit = 200,
  }) => inner.pendingSnapshotMedia(sessionId, limit: limit);

  @override
  Future<void> saveStagedThumbnail(
    String sessionId,
    String mediaId,
    Uint8List bytes,
  ) async {
    await inner.saveStagedThumbnail(sessionId, mediaId, bytes);
    afterThumbnailSaved?.call(mediaId);
  }

  @override
  Future<SnapshotCommit> commitPeerSnapshot(String sessionId) =>
      inner.commitPeerSnapshot(sessionId);

  @override
  Future<void> abortPeerSnapshot(String sessionId) =>
      inner.abortPeerSnapshot(sessionId);

  @override
  Future<void> replacePeerSnapshot(Peer peer, List<MediaItem> items) =>
      inner.replacePeerSnapshot(peer, items);
}

MediaMetadata _photo(
  String deviceId,
  String id, {
  String folder = 'camera',
  int modified = 1,
}) => MediaMetadata(
  id: id,
  deviceId: deviceId,
  name: '$id.jpg',
  sharedFolderId: folder,
  sharedFolderName: folder,
  relativePath: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 10000000,
  modifiedMs: modified,
);

Future<void> _until(
  AppController model,
  bool Function() condition, {
  required String reason,
}) async {
  if (condition()) return;
  final changed = Completer<void>();
  void listener() {
    if (!changed.isCompleted && condition()) changed.complete();
  }

  model.addListener(listener);
  try {
    listener();
    await changed.future.timeout(
      _timeout,
      onTimeout: () => throw TestFailure(reason),
    );
  } finally {
    model.removeListener(listener);
  }
}

SyncProgress? _progress(AppController model, String peerId) =>
    model.syncProgress.where((value) => value.peerId == peerId).firstOrNull;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late TamayuraRepository db;
  late _SyncGatedRepository repository;
  late TransferStore tasks;
  late FakeBridge bridge;
  late AppController model;
  late Directory temporary;
  late List<(_GatedSource, MediaRpcServer)> servers;
  MediaRpcClient Function(Peer)? clientFactory;

  Future<MediaRpcServer> serve(_GatedSource source) async {
    final server = MediaRpcServer(
      identity: Peer(
        id: source.deviceId,
        name: source.deviceId,
        host: '127.0.0.1',
        port: 0,
      ),
      source: source,
    );
    servers.add((source, server));
    await server.start();
    return server;
  }

  Future<void> connect(MediaRpcServer server) =>
      model.connect('192.168.1.8:${server.port}');

  AppController makeModel() => AppController(
    bridge: bridge,
    preferredPort: 0,
    openRepository: () async => repository,
    openTransfers: () async => tasks,
    // The public address parser accepts LAN addresses only. Route that valid
    // input to a real loopback gRPC channel for this integration fixture.
    clientFactory: (peer) =>
        clientFactory?.call(peer) ??
        MediaRpcClient(
          Peer(
            id: peer.id,
            name: peer.name,
            host: '127.0.0.1',
            port: peer.port,
          ),
        ),
  );

  setUp(() async {
    servers = [];
    clientFactory = null;
    temporary = await Directory.systemTemp.createTemp('tamayura-sync-ui-');
    db = await TamayuraRepository.open(
      path: '${temporary.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
    repository = _SyncGatedRepository(db);
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: databaseFactoryFfi,
    );
    bridge = FakeBridge();
    model = makeModel();
    await model.initialize();
    expect(model.error, isNull);
  });

  tearDown(() async {
    for (final (source, _) in servers) {
      source.releaseAll();
    }
    await model.shutdown();
    for (final (_, server) in servers) {
      await server.stop();
    }
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  test(
    'a failed first identity lookup retries the original manual address',
    () async {
      var identityCalls = 0;
      final progressEvents = <SyncProgress>[];
      void recordProgress() => progressEvents.addAll(model.syncProgress);
      model.addListener(recordProgress);
      addTearDown(() => model.removeListener(recordProgress));
      clientFactory = (candidate) => StubRpcClient(
        candidate,
        onIdentity: () async {
          if (identityCalls++ == 0) {
            throw const SocketException('temporarily unavailable');
          }
          return Peer(
            id: 'phone',
            name: 'Phone',
            host: candidate.host,
            port: candidate.port,
          );
        },
      );
      await model.connect('192.168.1.8:50728');
      expect(model.devices, isEmpty);
      expect((await db.listPeers()), isEmpty);
      final failed = model.syncProgress.single;
      expect(failed.phase, SyncPhase.failed);
      expect(failed.peerId, '192.168.1.8:50728');
      expect(failed.sessionId, isNotNull);
      expect(progressEvents.first.phase, SyncPhase.connecting);
      expect(
        progressEvents.map((progress) => progress.sessionId),
        everyElement(same(failed.sessionId)),
      );
      progressEvents.clear();
      await model.retrySync(failed.peerId);
      expect(model.devices.single.id, 'phone');
      expect(model.syncProgress.single.peerId, 'phone');
      expect(model.syncProgress.single.phase, SyncPhase.completed);
      final retriedSession = model.syncProgress.single.sessionId;
      expect(retriedSession, isNotNull);
      expect(retriedSession, isNot(same(failed.sessionId)));
      expect(
        progressEvents.map((progress) => progress.sessionId),
        everyElement(same(retriedSession)),
      );
      expect(
        progressEvents
            .where((progress) => progress.phase == SyncPhase.connecting)
            .map((progress) => progress.peerId)
            .toSet(),
        {'192.168.1.8:50728', 'phone'},
      );
      expect(model.media.single.deviceId, 'phone');
      expect(model.error, isNull);
    },
  );

  test(
    'first sync reveals ready photos and progress before all thumbnails finish',
    () async {
      final progressEvents = <SyncProgress>[];
      void recordProgress() => progressEvents.addAll(model.syncProgress);
      model.addListener(recordProgress);
      addTearDown(() => model.removeListener(recordProgress));
      final source = _GatedSource('phone', [
        _photo('phone', 'a'),
        _photo('phone', 'b'),
      ]);
      final gate = source.hold('b');
      final server = await serve(source);
      final syncing = connect(server);
      try {
        await gate.requested.future.timeout(_timeout);
        await _until(
          model,
          () =>
              model.media.length == 1 &&
              model.collections.any((value) => value.key == 'phone/camera') &&
              _progress(model, 'phone')?.readyCount == 1,
          reason:
              'The first ready thumbnail must be visible while the second is pending',
        );
        expect(model.media.single.id, 'a');
        expect(model.media.single.thumbnail, [1, 2, 3]);
        expect(model.collections.single.key, 'phone/camera');
        expect(model.collections.single.thumbnail, [1, 2, 3]);
        expect(_progress(model, 'phone')?.phase, SyncPhase.receiving);
        expect(_progress(model, 'phone')?.totalCount, 2);
        expect(_progress(model, 'phone')?.receivedCount, 2);
        expect(model.busy, isFalse);
      } finally {
        gate.open();
        await syncing.timeout(_timeout);
      }
      expect(model.media.map((item) => item.id), containsAll(['a', 'b']));
      expect(_progress(model, 'phone')?.phase, SyncPhase.completed);
      expect(_progress(model, 'phone')?.readyCount, 2);
      final session = _progress(model, 'phone')!.sessionId;
      expect(session, isNotNull);
      expect(
        progressEvents.map((progress) => progress.sessionId),
        everyElement(same(session)),
      );
      expect(progressEvents.map((progress) => progress.phase).toSet(), {
        SyncPhase.connecting,
        SyncPhase.receiving,
        SyncPhase.committing,
        SyncPhase.completed,
      });
      expect(model.error, isNull);
    },
  );

  test(
    'a visible photo can choose a download folder and queue during first manual sync',
    () async {
      final source = _GatedSource('phone', [
        _photo('phone', 'a'),
        _photo('phone', 'b'),
      ]);
      final gate = source.hold('b');
      final server = await serve(source);
      final syncing = connect(server);
      try {
        await gate.requested.future.timeout(_timeout);
        await _until(
          model,
          () => model.media.length == 1,
          reason:
              'The first photo must be available before choosing its download folder',
        );
        expect(model.downloadFolder, isNull);
        bridge.selection = {'uri': 'content://downloads', 'name': 'Downloads'};
        final photo = model.media.single;
        await model.download(photo).timeout(_timeout);
        expect(model.downloadFolder, 'Downloads');
        expect(await db.getSetting('downloadUri'), 'content://downloads');
        expect(_progress(model, 'phone')?.phase, SyncPhase.receiving);
        expect(gate.release.isCompleted, isFalse);
        final queued = await tasks.forMedia(photo.deviceId, photo.id);
        expect(queued, isNotNull);
        expect(queued!.state, DownloadState.queued);
        expect(queued.directoryUri, 'content://downloads');
        expect(bridge.scheduled, contains(queued.id));
        expect(model.error, isNull);
      } finally {
        gate.open();
        await syncing.timeout(_timeout);
      }
    },
  );

  test(
    'incremental sync previews a new album while retaining the previous full cache',
    () async {
      final source = _GatedSource('phone', [
        _photo('phone', 'keep'),
        _photo('phone', 'removed'),
      ]);
      final server = await serve(source);
      await connect(server);
      source.items = [
        _photo('phone', 'keep'),
        _photo('phone', 'new-a', folder: 'holiday', modified: 2),
        _photo('phone', 'new-b', folder: 'holiday', modified: 2),
      ];
      final gate = source.hold('new-b');
      await server.refresh();
      final syncing = connect(server);
      try {
        await gate.requested.future.timeout(_timeout);
        await _until(
          model,
          () =>
              model.media.any((item) => item.id == 'new-a') &&
              model.collections.any((value) => value.key == 'phone/holiday'),
          reason:
              'A new album must be browsable before its last thumbnail arrives',
        );
        expect(model.media.map((item) => item.id).toSet(), {
          'keep',
          'removed',
          'new-a',
        });
        expect(
          model.collections.map((value) => value.key),
          contains('phone/holiday'),
        );
        expect(_progress(model, 'phone')?.readyCount, 2);
        expect(_progress(model, 'phone')?.totalCount, 3);
        await model.selectCollection('phone/holiday');
        expect(model.media.single.id, 'new-a');
      } finally {
        gate.open();
        await syncing.timeout(_timeout);
      }
      expect(model.selectedCollectionKey, 'phone/holiday');
      expect(model.media.map((item) => item.id).toSet(), {'new-a', 'new-b'});
      await model.selectCollection(null);
      expect(model.media.map((item) => item.id).toSet(), {
        'keep',
        'new-a',
        'new-b',
      });
      expect(_progress(model, 'phone')?.phase, SyncPhase.completed);
    },
  );

  test(
    'failed incremental sync retains photos and resumes only missing thumbnails',
    () async {
      final source = _GatedSource('phone', [_photo('phone', 'old')]);
      final server = await serve(source);
      await connect(server);
      source.items = [
        _photo('phone', 'new-a', folder: 'holiday'),
        _photo('phone', 'new-b', folder: 'holiday'),
      ];
      final firstThumbnail = source.hold('new-a');
      final gate = source.hold('new-b');
      source.failures.add('new-b');
      await server.refresh();
      final collectionsRead = Completer<void>();
      final releaseCollections = Completer<void>();
      final thumbnailSaved = Completer<void>();
      repository.afterCollectionsRead = (collections) async {
        if (!collectionsRead.isCompleted) {
          expect(collections.map((value) => value.key), ['phone/camera']);
          collectionsRead.complete();
          await releaseCollections.future;
        }
      };
      repository.afterThumbnailSaved = (mediaId) {
        if (mediaId == 'new-a' && !thumbnailSaved.isCompleted) {
          thumbnailSaved.complete();
        }
      };
      Object? receivingSession;
      final syncing = connect(server);
      try {
        await firstThumbnail.requested.future.timeout(_timeout);
        await gate.requested.future.timeout(_timeout);
        await collectionsRead.future.timeout(_timeout);
        // Force the thumbnail write between the collection and photo queries.
        // A visible photo alone does not mean its album entry is ready yet.
        firstThumbnail.open();
        await thumbnailSaved.future.timeout(_timeout);
        releaseCollections.complete();
        await _until(
          model,
          () =>
              model.media.any((item) => item.id == 'new-a') &&
              model.collections.any((value) => value.key == 'phone/holiday'),
          reason:
              'The photo and its album entry must be ready before selecting the album',
        );
        receivingSession = _progress(model, 'phone')!.sessionId;
        expect(receivingSession, isNotNull);
        expect(model.media.map((item) => item.id), contains('old'));
        await model.selectCollection('phone/holiday');
      } finally {
        firstThumbnail.open();
        if (!releaseCollections.isCompleted) releaseCollections.complete();
        gate.open();
        await syncing.timeout(_timeout);
      }
      expect(_progress(model, 'phone')?.phase, SyncPhase.failed);
      expect(_progress(model, 'phone')?.sessionId, same(receivingSession));
      expect(_progress(model, 'phone')?.error, isNotEmpty);
      expect(model.selectedCollectionKey, 'phone/holiday');
      expect(model.media.single.id, 'new-a');
      expect(model.collections.map((c) => c.key).toSet(), {
        'phone/camera',
        'phone/holiday',
      });
      source.failures.clear();
      source.thumbnailRequests.clear();
      await model.retrySync('phone').timeout(_timeout);
      expect(_progress(model, 'phone')?.phase, SyncPhase.completed);
      expect(_progress(model, 'phone')?.sessionId, isNotNull);
      expect(
        _progress(model, 'phone')?.sessionId,
        isNot(same(receivingSession)),
      );
      expect(model.media.map((item) => item.id).toSet(), {'new-a', 'new-b'});
      expect(source.thumbnailRequests, ['new-b']);
      await model.selectCollection(null);
      expect(model.media.map((item) => item.id).toSet(), {'new-a', 'new-b'});
      expect(model.error, isNull);
    },
  );

  test(
    'reopening offline retains incomplete photos and the continue-sync action',
    () async {
      final source = _GatedSource('phone', [
        _photo('phone', 'a'),
        _photo('phone', 'b'),
      ])..failures.add('b');
      final server = await serve(source);
      await connect(server);
      expect(model.media.single.id, 'a');
      await model.shutdown();
      db = await TamayuraRepository.open(
        path: '${temporary.path}/catalog.db',
        factory: databaseFactoryFfi,
      );
      repository = _SyncGatedRepository(db);
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      clientFactory = (peer) => StubRpcClient(
        peer,
        onIdentity: () async => throw const SocketException('offline'),
      );
      model = makeModel();
      await model.initialize();
      expect(model.media.single.id, 'a');
      expect(model.collections.single.itemCount, 1);
      expect(_progress(model, 'phone')?.phase, SyncPhase.failed);
      expect(_progress(model, 'phone')?.readyCount, 1);
      expect(_progress(model, 'phone')?.totalCount, 2);
      source.failures.clear();
      source.thumbnailRequests.clear();
      clientFactory = null;
      await model.retrySync('phone');
      expect(_progress(model, 'phone')?.phase, SyncPhase.completed);
      expect(model.media.map((item) => item.id).toSet(), {'a', 'b'});
      expect(source.thumbnailRequests, ['b']);
    },
  );

  test(
    'manual connection cannot duplicate a discovered peer snapshot',
    () async {
      final source = _GatedSource('phone', [
        _photo('phone', 'a'),
        _photo('phone', 'b'),
      ]);
      final gate = source.hold('b');
      final server = await serve(source);
      bridge.events.add({
        'type': 'found',
        'id': 'phone',
        'name': 'phone',
        'host': '192.168.1.8',
        'port': server.port,
      });
      try {
        await gate.requested.future.timeout(_timeout);
        await connect(server).timeout(_timeout);
        expect(model.syncProgress, hasLength(1));
        expect(_progress(model, 'phone')?.phase, SyncPhase.receiving);
        expect(source.thumbnailRequests.toSet(), {'a', 'b'});
        expect(source.thumbnailRequests, hasLength(2));
      } finally {
        gate.open();
      }
      await _until(
        model,
        () => _progress(model, 'phone')?.phase == SyncPhase.completed,
        reason: 'The discovered sync must finish without losing its checkpoint',
      );
    },
  );

  test(
    'progress refresh preserves loaded pages and respects device and album changes',
    () async {
      final source = _GatedSource('phone-a', [
        for (var i = 0; i < 125; i++)
          _photo(
            'phone-a',
            'old-${i.toString().padLeft(3, '0')}',
            modified: 1000 - i,
          ),
      ]);
      final server = await serve(source);
      await connect(server);
      final other = await serve(
        _GatedSource('phone-b', [_photo('phone-b', 'other')]),
      );
      await connect(other);
      await model.selectDevice('phone-a');
      await model.loadMoreMedia();
      expect(model.media, hasLength(120));
      source.items = [
        ...source.items,
        for (var i = 1; i <= 3; i++)
          _photo('phone-a', 'new-$i', folder: 'holiday', modified: 2000 + i),
      ];
      final second = source.hold('new-2');
      final third = source.hold('new-3');
      await server.refresh();
      final syncing = connect(server);
      try {
        await third.requested.future.timeout(_timeout);
        await _until(
          model,
          () => model.media.any((item) => item.id == 'new-1'),
          reason:
              'A pending incremental sync should refresh the already loaded pages',
        );
        expect(model.media, hasLength(120));
        expect(model.hasMoreMedia, isTrue);
        expect(model.media.map((item) => item.key).toSet(), hasLength(120));
        await model.selectDevice('phone-b');
        expect(model.media.single.id, 'other');
        second.open();
        await _until(
          model,
          () => (_progress(model, 'phone-a')?.readyCount ?? 0) >= 127,
          reason:
              'The newly released thumbnail must advance the other device progress',
        );
        expect(model.selectedDeviceId, 'phone-b');
        expect(model.media.single.deviceId, 'phone-b');
        await model.selectDevice('phone-a');
        await model.selectCollection('phone-a/holiday');
        expect(model.media.map((item) => item.id).toSet(), {'new-1', 'new-2'});
      } finally {
        second.open();
        third.open();
        await syncing.timeout(_timeout);
      }
      expect(model.selectedCollectionKey, 'phone-a/holiday');
      expect(model.media.map((item) => item.id).toSet(), {
        'new-1',
        'new-2',
        'new-3',
      });
      expect(model.totalMediaCount, 3);
    },
  );

  for (final nextDevice in <String?>[null, 'other', 'phone']) {
    final changeDevice = nextDevice == 'other';
    test(
      changeDevice
          ? 'changing device cancels pagination waiting for a progress refresh'
          : nextDevice == 'phone'
          ? 'pagination also waits for refreshes queued while it is waiting'
          : 'pagination waits for an in-flight progress refresh to restore its cursor',
      () async {
        final source = _GatedSource('phone', [
          for (var i = 0; i < 125; i++)
            _photo(
              'phone',
              'old-${i.toString().padLeft(3, '0')}',
              modified: 1000 - i,
            ),
        ]);
        final server = await serve(source);
        await connect(server);
        if (changeDevice) {
          final other = await serve(
            _GatedSource('other', [
              for (var i = 0; i < 65; i++) _photo('other', 'other-$i'),
            ]),
          );
          await connect(other);
        }
        await model.selectDevice('phone');
        source.items = [
          ...source.items,
          _photo('phone', 'new', modified: 2000),
        ];
        final thumbnail = source.hold('new');
        await server.refresh();
        final refreshEntered = Completer<void>();
        final releaseRefresh = Completer<void>();
        final queuedRefreshEntered = Completer<void>();
        final releaseQueuedRefresh = Completer<void>();
        repository.afterCollectionsRead = (_) async {
          if (!refreshEntered.isCompleted) {
            refreshEntered.complete();
            await releaseRefresh.future;
          } else if (nextDevice == 'phone' &&
              !queuedRefreshEntered.isCompleted) {
            queuedRefreshEntered.complete();
            await releaseQueuedRefresh.future;
          }
        };
        final syncing = connect(server);
        Future<void>? loadingPage;
        Future<void>? changingDevice;
        try {
          await thumbnail.requested.future.timeout(_timeout);
          await refreshEntered.future.timeout(_timeout);
          expect(model.media, hasLength(60));
          expect(model.hasMoreMedia, isFalse);
          loadingPage = model.loadMoreMedia();
          if (nextDevice != null) {
            changingDevice = model.selectDevice(nextDevice);
          }
          releaseRefresh.complete();
          if (nextDevice == 'phone') {
            await queuedRefreshEntered.future.timeout(_timeout);
            releaseQueuedRefresh.complete();
          }
          await loadingPage.timeout(_timeout);
          await changingDevice?.timeout(_timeout);
          expect(model.media, hasLength(changeDevice ? 60 : 120));
          expect(model.media.map((item) => item.deviceId).toSet(), {
            changeDevice ? 'other' : 'phone',
          });
          expect(model.hasMoreMedia, isTrue);
        } finally {
          if (!releaseRefresh.isCompleted) releaseRefresh.complete();
          if (!releaseQueuedRefresh.isCompleted) {
            releaseQueuedRefresh.complete();
          }
          thumbnail.open();
          await loadingPage?.timeout(_timeout);
          await changingDevice?.timeout(_timeout);
          await syncing.timeout(_timeout);
        }
        expect(model.media, hasLength(changeDevice ? 60 : 120));
      },
    );
  }

  test(
    'a throttled progress refresh cannot discard a page waiting on saved-file lookups',
    () async {
      final source = _GatedSource('phone', [
        for (var i = 0; i < 125; i++)
          _photo(
            'phone',
            'old-${i.toString().padLeft(3, '0')}',
            modified: 1000 - i,
          ),
      ]);
      final server = await serve(source);
      await connect(server);
      expect(model.media, hasLength(60));
      source.items = [
        ...source.items,
        _photo('phone', 'new-a', modified: 2000),
        _photo('phone', 'new-b', modified: 2001),
      ];
      final thumbnail = source.hold('new-b');
      await server.refresh();
      final pageEntered = Completer<void>();
      final pageRelease = Completer<void>();
      repository.beforeDownloadRead = (deviceId, mediaId) async {
        if (mediaId == 'old-060' && !pageEntered.isCompleted) {
          pageEntered.complete();
          await pageRelease.future;
        }
      };
      Future<void>? syncing;
      Future<void>? loadingPage;
      try {
        // Enter the page lookup before starting synchronization, so the test
        // does not race against the 250 ms throttle under parallel test load.
        await _until(
          model,
          () => model.hasMoreMedia && model.media.length == 60,
          reason: 'The cached first page must be ready before requesting more',
        );
        loadingPage = model.loadMoreMedia();
        await pageEntered.future.timeout(_timeout);
        syncing = connect(server);
        await thumbnail.requested.future.timeout(_timeout);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(model.loadingMoreMedia, isTrue);
        expect(_progress(model, 'phone')?.receivedCount, 127);
        pageRelease.complete();
        await loadingPage.timeout(_timeout);
        expect(model.media, hasLength(120));
        expect(model.media.map((photo) => photo.id), contains('old-119'));
        await _until(
          model,
          () => model.media.any((photo) => photo.id == 'new-a'),
          reason:
              'The deferred progress refresh must run after the page finishes',
        );
        expect(model.media, hasLength(120));
        expect(model.media.map((photo) => photo.key).toSet(), hasLength(120));
        expect(model.hasMoreMedia, isTrue);
      } finally {
        if (!pageRelease.isCompleted) pageRelease.complete();
        thumbnail.open();
        await loadingPage?.timeout(_timeout);
        await syncing?.timeout(_timeout);
      }
      expect(model.media, hasLength(120));
      expect(model.totalMediaCount, 127);
      expect(_progress(model, 'phone')?.phase, SyncPhase.completed);
    },
  );

  test('simultaneous discovered devices retain independent progress', () async {
    final sourceA = _GatedSource('phone-a', [
      _photo('phone-a', 'a'),
      _photo('phone-a', 'b'),
    ]);
    final sourceB = _GatedSource('phone-b', [
      _photo('phone-b', 'a'),
      _photo('phone-b', 'b'),
    ]);
    final gateA = sourceA.hold('b');
    final gateB = sourceB.hold('b');
    final serverA = await serve(sourceA);
    final serverB = await serve(sourceB);
    for (final (id, server) in [('phone-a', serverA), ('phone-b', serverB)]) {
      bridge.events.add({
        'type': 'found',
        'id': id,
        'name': id,
        'host': '192.168.1.8',
        'port': server.port,
      });
    }
    await Future.wait([
      gateA.requested.future,
      gateB.requested.future,
    ]).timeout(_timeout);
    await _until(
      model,
      () =>
          model.media.length == 2 &&
          model.syncProgress.every((p) => p.readyCount == 1),
      reason:
          'Both peers should independently expose a thumbnail while still syncing',
    );
    expect(model.syncProgress, hasLength(2));
    gateA.open();
    await _until(
      model,
      () => _progress(model, 'phone-a')?.phase == SyncPhase.completed,
      reason: 'The first peer should complete independently',
    );
    expect(_progress(model, 'phone-b')?.phase, SyncPhase.receiving);
    expect(_progress(model, 'phone-b')?.readyCount, 1);
    gateB.open();
    await _until(
      model,
      () =>
          model.media.length == 4 &&
          model.syncProgress.every((p) => p.phase == SyncPhase.completed),
      reason: 'Both completed device results should remain visible',
    );
  });

  for (final shutdown in [false, true]) {
    test(
      '${shutdown ? 'closing the controller' : 'suspending sharing'} prevents late progress from returning',
      () async {
        final source = _GatedSource('phone', [_photo('phone', 'old')]);
        final server = await serve(source);
        await connect(server);
        source.items = [_photo('phone', 'new-a'), _photo('phone', 'new-b')];
        final gate = source.hold('new-b');
        await server.refresh();
        final syncing = connect(server);
        try {
          await gate.requested.future.timeout(_timeout);
          await _until(
            model,
            () => model.media.any((item) => item.id == 'new-a'),
            reason:
                'The operation must have shown a preview before it is stopped',
          );
          if (shutdown) {
            await model.shutdown().timeout(_timeout);
          } else {
            await model.setForeground(false).timeout(_timeout);
          }
          await syncing.timeout(_timeout);
          expect(model.syncProgress, isEmpty);
          if (!shutdown) {
            expect(model.media.map((item) => item.id).toSet(), {
              'old',
              'new-a',
            });
            expect(model.collections.single.key, 'phone/camera');
          }
        } finally {
          gate.open();
          await gate.returned.future.timeout(_timeout);
          await syncing.timeout(_timeout);
        }
        expect(model.syncProgress, isEmpty);
        if (!shutdown) {
          expect(model.media.map((item) => item.id).toSet(), {'old', 'new-a'});
          source.thumbnailRequests.clear();
          await model.setForeground(true);
          await model.retrySync('phone').timeout(_timeout);
          expect(model.media.map((item) => item.id).toSet(), {
            'new-a',
            'new-b',
          });
          expect(source.thumbnailRequests, ['new-b']);
        }
      },
    );
  }
}
