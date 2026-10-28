import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import '../core/models.dart';
import '../core/catalog_repository.dart';
import '../l10n/app_locale.dart';
import 'generated/media.pbgrpc.dart' as wire;

const mediaProtocolVersion = 4;
const maxCatalogPageSize = 500;

/// One FileChunk payload, read from the native adapter in a single call.
const mediaChunkSize = mediaReadChunkBytes;
const maxThumbnailBytes = 512 * 1024;

/// grpc-dart never pauses a server stream for HTTP/2 flow control: chunks the
/// network has not sent yet are queued in memory. Each ReadFile request is
/// therefore limited, and receivers request a large range one window at a time.
const maxReadWindowBytes = 8 * 1024 * 1024;

class MediaRpcServer {
  MediaRpcServer({
    required Peer identity,
    required LocalMediaSource source,
    void Function()? onCatalogChanged,
  }) : _service = _MediaService(identity, source, onCatalogChanged);

  final _MediaService _service;
  Server? _server;
  int _lifecycleGeneration = 0;

  int get port => _server?.port ?? 0;
  List<MediaMetadata> get localMedia =>
      List.unmodifiable(_service.snapshot.values);
  int get localMediaCount => _service.snapshot.length;
  String get revision => _service.revision;
  Object? get scanError => _service.scanError;
  Object? get restoreError => _service.restoreError;
  bool get scanning => _service.scanning;

  /// Completes when the current catalog work finishes or is superseded. Errors
  /// are exposed by [scanError] and [restoreError], never by this future.
  Future<void> get catalogReady => _service.catalogReady;

  /// Refresh the display name without changing identity or interrupting reads.
  void updateDeviceName(String name) {
    _service.identity = _service.identity.copyWith(name: name);
  }

  Future<void> start({int port = 0, bool backgroundScan = false}) async {
    if (_server != null) throw StateError('Server is already running');
    final generation = ++_lifecycleGeneration;
    _CatalogWork? backgroundWork;
    if (backgroundScan) {
      backgroundWork = _service.beginBackgroundRefresh();
    } else {
      try {
        await refresh();
      } catch (_) {
        // Receiving from other devices must still work if this device's shared
        // directory permission expired. ListMedia reports the scan failure.
      }
    }
    if (generation != _lifecycleGeneration) return;
    final server = _InterruptibleServer(services: [_service]);
    try {
      await server.serve(address: InternetAddress.anyIPv4, port: port);
      if (generation != _lifecycleGeneration) {
        await server.shutdown();
        return;
      }
      _server = server;
      if (backgroundWork != null) {
        unawaited(_service.restoreAndRefresh(backgroundWork));
      }
    } catch (_) {
      await server.shutdown();
      if (backgroundWork != null) _service.cancelWork(backgroundWork);
      if (generation != _lifecycleGeneration) return;
      rethrow;
    }
  }

  /// Failed scans revoke sharing and produce an RPC error, so callers preserve
  /// their offline snapshot instead of interpreting failure as an empty folder.
  Future<void> refresh() => _service.refresh();

  /// Revoke an obsolete catalog before changing shared folders. Unlike a valid
  /// empty scan, this makes catalog/thumbnail RPCs unavailable until a new
  /// snapshot is published, so peers keep their cached media. Original files in
  /// retained folders remain readable; all other files are revoked immediately.
  void invalidateCatalog({Set<String> retainSharedFolderIds = const {}}) =>
      _service.invalidateCatalog(retainSharedFolderIds);

  Future<void> stop() async {
    _lifecycleGeneration++;
    _service.invalidateRefresh();
    final server = _server;
    _server = null;
    await server?.shutdown();
  }
}

/// gRPC's default shutdown drains transfers and can wait forever for a paused
/// reader. Track connections through its public serving hook and terminate
/// active transports when sharing stops, including flow-controlled responses.
class _InterruptibleServer extends Server {
  _InterruptibleServer({required super.services}) : super.create();

  final _active = <Future<void> Function()>{};
  Future<void>? _shutdown;
  bool _stopping = false;

  @override
  Future<void> serveConnection({
    required connection,
    clientCertificate,
    remoteAddress,
  }) async {
    Future<void> terminate() async => connection.terminate();
    if (_stopping) {
      await terminate();
      return;
    }
    connection.onActiveStateChanged = (active) {
      if (active) {
        _active.add(terminate);
      } else {
        _active.remove(terminate);
      }
    };
    await super.serveConnection(
      connection: connection,
      clientCertificate: clientCertificate,
      remoteAddress: remoteAddress,
    );
  }

  @override
  Future<void> shutdown() => _shutdown ??= _stop();

  Future<void> _stop() async {
    _stopping = true;
    final terminating = _active
        .toList()
        .map((terminate) => terminate())
        .toList();
    _active.clear();
    await Future.wait([...terminating, super.shutdown()]);
  }
}

class _CatalogWork {
  final completed = Completer<void>();

  void finish() {
    if (!completed.isCompleted) completed.complete();
  }
}

class _MediaService extends wire.MediaLibraryServiceBase {
  _MediaService(this.identity, this.source, this.onCatalogChanged);

  Peer identity;
  final LocalMediaSource source;
  final void Function()? onCatalogChanged;
  Map<String, MediaMetadata> snapshot = {};
  List<MediaMetadata> _ordered = [];
  String revision = '';
  Object? scanError;
  Object? restoreError;
  bool _catalogAvailable = false;
  bool _filesAvailable = false;
  _CatalogWork? _work;
  bool get scanning => _work != null && !_work!.completed.isCompleted;
  Future<void> get catalogReady => _work?.completed.future ?? Future.value();
  int _thumbnailActive = 0;
  final _thumbnailWaiters = <Completer<void>>[];

  // A provider may finish after stop() has returned or another scan has begun.
  // Keep the last completed snapshot, but revoke every pending scan's commit.
  void invalidateRefresh() {
    final work = _work;
    if (work != null) cancelWork(work);
  }

  void cancelWork(_CatalogWork work) {
    if (!_current(work)) return;
    work.finish();
    onCatalogChanged?.call();
  }

  void invalidateCatalog(Set<String> retainedFolders) {
    // Revoke removed folders synchronously, before any new scan or hashing.
    // Retained originals remain readable while the new revision is prepared.
    _work?.finish();
    final canRetain = _filesAvailable && scanError == null;
    snapshot = Map.unmodifiable({
      for (final item in snapshot.values)
        if (canRetain && retainedFolders.contains(item.sharedFolderId))
          item.id: item,
    });
    _ordered = [];
    revision = '';
    _catalogAvailable = false;
    _filesAvailable = snapshot.isNotEmpty;
    onCatalogChanged?.call();
  }

  bool _current(_CatalogWork work) =>
      identical(_work, work) && !work.completed.isCompleted;

  _CatalogWork _beginWork() {
    _work?.finish();
    final work = _CatalogWork();
    _work = work;
    onCatalogChanged?.call();
    return work;
  }

  _CatalogWork beginBackgroundRefresh() {
    restoreError = null;
    scanError = null;
    // A previous process/session's Dart snapshot does not prove native access
    // still exists. Revalidate it through restore before serving it again.
    _catalogAvailable = false;
    _filesAvailable = false;
    return _beginWork();
  }

  Future<void> restoreAndRefresh(_CatalogWork work) async {
    try {
      if (!_current(work)) return;
      final restorable = source;
      if (restorable is RestorableLocalMediaSource) {
        try {
          final restored = await restorable.restore();
          if (!_current(work)) return;
          if (restored != null) {
            final prepared = await _prepareCatalog(
              restored,
              identity.id,
              strict: true,
            );
            if (!_current(work)) return;
            _publish(prepared);
          }
        } catch (error) {
          if (!_current(work)) return;
          // A successful rescan must not erase a cache diagnostic before the
          // controller has had a chance to display it.
          restoreError = error;
          onCatalogChanged?.call();
        }
      }
      if (!_current(work)) return;
      await _scan(work);
    } catch (_) {
      // Background startup remains reachable; _scan records the current error.
    } finally {
      cancelWork(work);
    }
  }

  Future<void> refresh() async {
    restoreError = null;
    final work = _beginWork();
    try {
      await _scan(work);
    } finally {
      cancelWork(work);
    }
  }

  void _publish(_PreparedCatalog catalog) {
    snapshot = catalog.byId;
    _ordered = catalog.ordered;
    revision = catalog.revision;
    _catalogAvailable = true;
    _filesAvailable = true;
    scanError = null;
    onCatalogChanged?.call();
  }

  Future<void> _scan(_CatalogWork work) async {
    try {
      final scanned = await source.scan();
      if (!_current(work)) return;
      final prepared = await _prepareCatalog(scanned, identity.id);
      if (!_current(work)) return;
      _publish(prepared);
    } catch (error) {
      if (!_current(work)) return;
      snapshot = {};
      _ordered = [];
      revision = '';
      _catalogAvailable = false;
      _filesAvailable = false;
      scanError = error;
      onCatalogChanged?.call();
      rethrow;
    }
  }

  @override
  Future<wire.DeviceIdentity> getIdentity(
    ServiceCall call,
    wire.Empty request,
  ) async => wire.DeviceIdentity(
    id: identity.id,
    name: identity.name,
    protocolVersion: mediaProtocolVersion,
  );

  void _checkRevision(String requested) {
    _checkAvailable(_catalogAvailable);
    if (requested.isNotEmpty && requested != revision) {
      throw const GrpcError.aborted(
        'Catalog revision expired; restart pagination',
      );
    }
  }

  void _checkAvailable(bool available) {
    if (scanError != null) {
      throw const GrpcError.failedPrecondition(
        'Shared folder is unavailable; refresh on the source device',
      );
    }
    if (!available) {
      throw const GrpcError.unavailable(
        'Shared catalog is being prepared; retry shortly',
      );
    }
  }

  @override
  Future<wire.CatalogResponse> listMediaPage(
    ServiceCall call,
    wire.CatalogRequest request,
  ) async {
    _checkRevision(request.revision);
    final size = request.pageSize == 0 ? 200 : request.pageSize;
    if (size > maxCatalogPageSize) {
      throw const GrpcError.invalidArgument('Catalog page is too large');
    }
    var offset = 0;
    if (request.pageToken.isNotEmpty) {
      final parts = request.pageToken.split(':');
      if (request.revision.isEmpty ||
          parts.length != 2 ||
          parts.first != revision) {
        throw const GrpcError.aborted('Catalog page token expired');
      }
      final parsed = int.tryParse(parts.last);
      if (parsed == null || parsed < 0 || parsed >= _ordered.length) {
        throw const GrpcError.invalidArgument('Invalid catalog page token');
      }
      offset = parsed;
    }
    if (request.pageToken.isEmpty && request.knownRevision == revision) {
      return wire.CatalogResponse(
        revision: revision,
        totalCount: _ordered.length,
        notModified: true,
      );
    }
    final end = (offset + size).clamp(0, _ordered.length);
    return wire.CatalogResponse(
      revision: revision,
      totalCount: _ordered.length,
      nextPageToken: end < _ordered.length ? '$revision:$end' : '',
      items: _ordered
          .sublist(offset, end)
          .map(
            (item) => wire.MediaEntry(
              id: item.id,
              name: item.name,
              mimeType: item.mimeType,
              size: Int64(item.size),
              modifiedMs: Int64(item.modifiedMs),
              sharedFolderId: item.sharedFolderId,
              sharedFolderName: item.sharedFolderName,
              relativePath: item.relativePath,
            ),
          ),
    );
  }

  Future<void> _acquireThumbnailSlot() async {
    if (_thumbnailActive < 4) {
      _thumbnailActive++;
      return;
    }
    final pending = Completer<void>();
    _thumbnailWaiters.add(pending);
    await pending.future;
  }

  void _releaseThumbnailSlot() {
    if (_thumbnailWaiters.isEmpty) {
      _thumbnailActive--;
    } else {
      _thumbnailWaiters.removeAt(0).complete();
    }
  }

  @override
  Future<wire.ThumbnailResponse> getThumbnail(
    ServiceCall call,
    wire.ThumbnailRequest request,
  ) async {
    if (request.revision.isEmpty) {
      throw const GrpcError.invalidArgument(
        'Thumbnail requests require a catalog revision',
      );
    }
    _checkRevision(request.revision);
    if (!snapshot.containsKey(request.id)) {
      throw const GrpcError.notFound('Media is not shared');
    }
    await _acquireThumbnailSlot();
    try {
      _checkRevision(request.revision);
      if (call.isCanceled || call.trailers == null) {
        throw const GrpcError.cancelled();
      }
      Uint8List bytes;
      try {
        bytes = await source.readThumbnail(request.id);
      } catch (_) {
        // Report a catalog that changed or failed meanwhile as such.
        _checkRevision(request.revision);
        // Sources return empty bytes for one missing or undecodable file.
        // A thrown error is a permission, catalog or resource failure that can
        // recover, so receivers must retry instead of caching a blank preview.
        throw const GrpcError.unavailable(
          'Thumbnail source is temporarily unavailable; retry shortly',
        );
      }
      if (call.isCanceled || call.trailers == null) {
        throw const GrpcError.cancelled();
      }
      _checkRevision(request.revision);
      if (bytes.length > maxThumbnailBytes) {
        // Retrying cannot shrink this file's preview; it simply has none.
        throw const GrpcError.notFound('Thumbnail is unavailable');
      }
      return wire.ThumbnailResponse(
        revision: revision,
        id: request.id,
        data: bytes,
      );
    } finally {
      _releaseThumbnailSlot();
    }
  }

  @override
  Stream<wire.FileChunk> readFile(
    ServiceCall call,
    wire.ReadRequest request,
  ) async* {
    _checkAvailable(_filesAvailable);
    final item = snapshot[request.id];
    if (item == null) throw const GrpcError.notFound('Media is not shared');
    final offset = request.offset.toInt();
    final length = request.length.toInt();
    if (offset < 0 ||
        length < 0 ||
        offset > item.size ||
        length > item.size - offset) {
      throw const GrpcError.outOfRange(
        'Requested range is outside the media file',
      );
    }
    if (length > maxReadWindowBytes) {
      throw const GrpcError.invalidArgument(
        'Requested range exceeds the read window',
      );
    }
    var cursor = offset;
    final end = offset + length;
    while (cursor < end) {
      if (call.isCanceled || call.trailers == null) return;
      final wanted = (end - cursor).clamp(0, mediaChunkSize);
      Uint8List data;
      try {
        data = await source.readRange(item.id, cursor, wanted);
      } on MediaSourceInterrupted {
        // The source replaced its catalog or revoked a grant mid-read. The
        // receiver retries; a then-missing file fails as NOT_FOUND.
        throw const GrpcError.unavailable(
          'Shared catalog changed during the read; retry shortly',
        );
      } catch (_) {
        throw const GrpcError.notFound(
          'Shared file is unavailable; refresh the library',
        );
      }
      if (call.isCanceled || call.trailers == null) return;
      if (data.length != wanted) {
        throw const GrpcError.dataLoss(
          'Shared file size has changed; refresh the library',
        );
      }
      yield wire.FileChunk(offset: Int64(cursor), data: data);
      cursor += data.length;
    }
  }
}

abstract class MediaTransferClient {
  Stream<Uint8List> readRange(String id, int offset, int length);
  Future<void> close();
}

class MediaRpcClient implements MediaTransferClient {
  MediaRpcClient(
    this.peer, {
    Duration metadataTimeout = const Duration(minutes: 2),
  }) : _metadataTimeout = metadataTimeout,
       _channel = ClientChannel(
         peer.host,
         port: peer.port,
         options: const ChannelOptions(
           credentials: ChannelCredentials.insecure(),
         ),
       ) {
    _client = wire.MediaLibraryClient(_channel);
  }

  final Peer peer;
  final Duration _metadataTimeout;
  final ClientChannel _channel;
  late final wire.MediaLibraryClient _client;
  Peer? _identity;

  Future<Peer> identity() async {
    final response = await _client.getIdentity(
      wire.Empty(),
      options: CallOptions(timeout: const Duration(seconds: 8)),
    );
    if (response.protocolVersion != mediaProtocolVersion ||
        response.id.isEmpty ||
        response.name.isEmpty) {
      throw FormatException(AppLocale.strings.errorIncompatiblePeer);
    }
    if (peer.id.isNotEmpty && peer.id != response.id) {
      throw FormatException(AppLocale.strings.errorAddressInUse);
    }
    return _identity = Peer(
      id: response.id,
      name: response.name,
      host: peer.host,
      port: peer.port,
      lastSeen: DateTime.now(),
      lastSync: peer.lastSync,
      lastSuccessfulSync: peer.lastSuccessfulSync,
    );
  }

  Future<CatalogPage> listMediaPage({
    String? revision,
    String? pageToken,
    int pageSize = 200,
    String? knownRevision,
  }) async {
    if (pageSize < 1 || pageSize > maxCatalogPageSize) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
    final device = _identity ?? await identity();
    final response = await _client.listMediaPage(
      wire.CatalogRequest(
        revision: revision,
        pageToken: pageToken,
        pageSize: pageSize,
        knownRevision: knownRevision,
      ),
      options: CallOptions(timeout: _metadataTimeout),
    );
    if (response.revision.isEmpty ||
        (revision != null && revision != response.revision) ||
        response.items.length > pageSize ||
        (response.notModified &&
            (knownRevision != response.revision ||
                response.items.isNotEmpty ||
                response.nextPageToken.isNotEmpty)) ||
        (!response.notModified &&
            response.items.isEmpty &&
            response.nextPageToken.isNotEmpty)) {
      throw FormatException(AppLocale.strings.errorPeerPaging);
    }
    final items = response.items
        .map(
          (entry) => MediaMetadata(
            id: entry.id,
            deviceId: device.id,
            name: entry.name,
            mimeType: entry.mimeType,
            size: entry.size.toInt(),
            modifiedMs: entry.modifiedMs.toInt(),
            sharedFolderId: entry.sharedFolderId,
            sharedFolderName: entry.sharedFolderName,
            relativePath: entry.relativePath,
          ),
        )
        .toList();
    final ids = <String>{};
    if (items.any((item) => !_validMetadata(item) || !ids.add(item.id))) {
      throw FormatException(AppLocale.strings.errorPeerCatalogInvalid);
    }
    return CatalogPage(
      revision: response.revision,
      items: items,
      totalCount: response.totalCount,
      nextPageToken: response.nextPageToken.isEmpty
          ? null
          : response.nextPageToken,
      notModified: response.notModified,
    );
  }

  Future<Uint8List> thumbnail(String id, {required String revision}) async {
    _identity ??= await identity();
    final response = await _client.getThumbnail(
      wire.ThumbnailRequest(id: id, revision: revision),
      options: CallOptions(timeout: _metadataTimeout),
    );
    if (response.id != id ||
        response.revision != revision ||
        response.data.length > maxThumbnailBytes) {
      throw FormatException(AppLocale.strings.errorPeerThumbnail);
    }
    return Uint8List.fromList(response.data);
  }

  /// NOT_FOUND means the source lists this item but has no preview for it.
  /// Store a completed empty preview so one file cannot block the catalog;
  /// every other error leaves the item pending for a later attempt.
  Future<Uint8List> _thumbnailOrEmpty(String id, String revision) async {
    try {
      return await thumbnail(id, revision: revision);
    } on GrpcError catch (error) {
      if (error.code != StatusCode.notFound) rethrow;
      return Uint8List(0);
    }
  }

  /// One metadata page and at most four thumbnail buffers are held at a time.
  /// Only a completed, revision-consistent stage can replace the offline cache.
  Future<SyncResult> synchronize(
    CatalogRepository repository, {
    int pageSize = 200,
    int maxRevisionRetries = 2,
    void Function(SyncProgress)? onProgress,
  }) async {
    if (maxRevisionRetries < 0) {
      throw ArgumentError.value(maxRevisionRetries, 'maxRevisionRetries');
    }
    final device = _identity ?? await identity();
    String? retrySessionId;
    for (var attempt = 0; ; attempt++) {
      String? session;
      var received = 0;
      var ready = 0;
      int? total;
      void report(SyncPhase phase) => onProgress?.call(
        SyncProgress(
          peerId: device.id,
          peerName: device.name,
          phase: phase,
          totalCount: total,
          receivedCount: received,
          readyCount: ready,
          attempt: attempt,
        ),
      );
      try {
        final checkpoint = await repository.findPeerSnapshot(
          device,
          claim: true,
          expectedSessionId: retrySessionId,
        );
        session = checkpoint?.sessionId;
        received = checkpoint?.receivedCount ?? 0;
        ready = checkpoint?.readyCount ?? 0;
        total = checkpoint?.totalCount;
        report(SyncPhase.connecting);
        final first = await listMediaPage(
          pageSize: pageSize,
          knownRevision:
              checkpoint?.revision ?? await repository.peerRevision(device.id),
        );
        total = first.totalCount;
        if (first.notModified && checkpoint == null) {
          await repository.markPeerSynced(device);
          received = total;
          ready = total;
          report(SyncPhase.completed);
          return SyncResult(
            peer: device,
            revision: first.revision,
            totalCount: first.totalCount,
            addedCount: 0,
            deletedCount: 0,
            thumbnailRequests: 0,
          );
        }
        final revision = first.revision;
        var thumbnailRequests = 0;
        CatalogPage? page;
        String? nextToken;
        var metadataComplete = false;
        if (first.notModified) {
          if (checkpoint!.totalCount != total) {
            throw FormatException(AppLocale.strings.errorPeerCatalogCount);
          }
          nextToken = checkpoint.nextPageToken;
          metadataComplete = checkpoint.metadataComplete;
        } else {
          session = await repository.beginPeerSnapshot(device, revision, total);
          received = 0;
          ready = 0;
          page = first;
        }
        final stage = session!;
        Future<void> receiveThumbnails(List<MediaMetadata> missing) async {
          for (var offset = 0; offset < missing.length; offset += 4) {
            // Wait for every in-flight write, including successful siblings of a
            // failed request, before releasing the stage to a subsequent attempt.
            await Future.wait(
              missing.skip(offset).take(4).map((item) async {
                final bytes = await _thumbnailOrEmpty(item.id, revision);
                thumbnailRequests++;
                await repository.saveStagedThumbnail(stage, item.id, bytes);
                ready++;
                report(SyncPhase.receiving);
              }),
            );
          }
        }

        if (first.notModified) {
          report(SyncPhase.receiving);
          while (true) {
            final missing = await repository.pendingSnapshotMedia(
              stage,
              limit: pageSize,
            );
            if (missing.isEmpty) break;
            await receiveThumbnails(missing);
          }
          if (!metadataComplete) {
            page = await listMediaPage(
              revision: revision,
              pageToken: nextToken,
              pageSize: pageSize,
            );
          }
        }
        final tokens = <String>{?nextToken};
        while (page != null) {
          if (page.revision != revision ||
              page.totalCount != total ||
              page.notModified) {
            throw FormatException(AppLocale.strings.errorPeerCatalogVersion);
          }
          received += page.items.length;
          if (received > total) {
            throw FormatException(AppLocale.strings.errorPeerCatalogCount);
          }
          final token = page.nextPageToken;
          if (token != null && !tokens.add(token)) {
            throw FormatException(
              AppLocale.strings.errorPeerCatalogPageRepeated,
            );
          }
          final missing = await repository.stageMediaPage(
            stage,
            page.items,
            nextPageToken: token,
            metadataComplete: token == null,
          );
          ready += page.items.length - missing.length;
          report(SyncPhase.receiving);
          await receiveThumbnails(missing);
          if (token == null) break;
          page = await listMediaPage(
            revision: revision,
            pageToken: token,
            pageSize: pageSize,
          );
        }
        if (received != total) {
          throw FormatException(AppLocale.strings.errorCatalogIncomplete);
        }
        report(SyncPhase.committing);
        final committed = await repository.commitPeerSnapshot(stage);
        session = null;
        report(SyncPhase.completed);
        return SyncResult(
          peer: device,
          revision: revision,
          totalCount: committed.totalCount,
          addedCount: committed.addedCount,
          deletedCount: committed.deletedCount,
          thumbnailRequests: thumbnailRequests,
        );
      } catch (error) {
        // Transport and source failures retain both pagination and ready media.
        // Invalid protocol data cannot be resumed; discard only this owner.
        if (session != null &&
            (error is FormatException ||
                error is GrpcError &&
                    error.code == StatusCode.invalidArgument)) {
          await repository.abortPeerSnapshot(session);
        }
        final expired = error is GrpcError && error.code == StatusCode.aborted;
        // Ownership/generation conflicts must not reclaim another attempt's stage.
        if (!expired || attempt >= maxRevisionRetries) rethrow;
        retrySessionId = session;
      }
    }
  }

  /// Compatibility helper for small fixtures. App browsing/sync uses bounded
  /// repository pages and synchronize(), never this whole-library convenience.
  Future<List<MediaItem>> listMedia() async {
    var page = await listMediaPage();
    final items = <MediaItem>[];
    final revision = page.revision;
    while (true) {
      for (final item in page.items) {
        items.add(
          item.withThumbnail(await thumbnail(item.id, revision: revision)),
        );
      }
      if (page.nextPageToken == null) return items;
      page = await listMediaPage(
        revision: revision,
        pageToken: page.nextPageToken,
      );
    }
  }

  @override
  Stream<Uint8List> readRange(String id, int offset, int length) async* {
    if (offset < 0 || length < 0) throw ArgumentError('Negative media range');
    // Verify the remembered device before disclosing or trusting its contents.
    _identity ??= await identity();
    var cursor = offset;
    final end = offset + length;
    // Request one bounded window at a time: the source then reads at most a
    // window ahead of what this receiver has consumed. An empty range still
    // makes one request so the source validates its offset.
    do {
      final windowEnd = end - cursor > maxReadWindowBytes
          ? cursor + maxReadWindowBytes
          : end;
      // No total deadline: a window on slow Wi-Fi may legitimately take longer
      // than any fixed bound. MediaDownloader's idle watchdog ends stalls.
      final response = _client.readFile(
        wire.ReadRequest(
          id: id,
          offset: Int64(cursor),
          length: Int64(windowEnd - cursor),
        ),
      );
      await for (final chunk in response) {
        if (chunk.offset.toInt() != cursor ||
            chunk.data.isEmpty ||
            chunk.data.length > windowEnd - cursor) {
          throw FormatException(AppLocale.strings.errorChunkInvalid);
        }
        cursor += chunk.data.length;
        yield Uint8List.fromList(chunk.data);
      }
      if (cursor != windowEnd) {
        throw FormatException(AppLocale.strings.errorTransferEnded);
      }
    } while (cursor < end);
  }

  @override
  Future<void> close() => _channel.terminate();
}

bool _validMetadata(MediaMetadata item) {
  try {
    validateMediaLocation(item);
  } on FormatException {
    return false;
  }
  return item.id.isNotEmpty &&
      item.id.length <= 512 &&
      item.name.isNotEmpty &&
      item.name.length <= 4096 &&
      item.mimeType.length <= 256 &&
      item.size >= 0;
}

class _PreparedCatalog {
  _PreparedCatalog(this.byId, this.ordered, this.revision);
  final Map<String, MediaMetadata> byId;
  final List<MediaMetadata> ordered;
  final String revision;
}

// Keep this closure outside the service: only immutable metadata and identity
// cross isolates, never the platform source, callbacks or active RPC transport.
Future<_PreparedCatalog> _prepareCatalog(
  List<MediaMetadata> scanned,
  String deviceId, {
  bool strict = false,
}) {
  // Small catalogs do not justify an isolate startup or its event-loop delay.
  // Future.sync preserves asynchronous error delivery for strict restoration.
  if (scanned.length < 256) {
    return Future.sync(() => _buildCatalog(scanned, deviceId, strict: strict));
  }
  return Isolate.run(() => _buildCatalog(scanned, deviceId, strict: strict));
}

class _InvalidRestoredCatalog implements Exception {
  @override
  String toString() => AppLocale.strings.errorLocalCatalogCorrupt;
}

_PreparedCatalog _buildCatalog(
  List<MediaMetadata> scanned,
  String deviceId, {
  required bool strict,
}) {
  final next = <String, MediaMetadata>{};
  final locations = <String>{};
  for (final item in scanned) {
    // Skip invalid or duplicate files without withholding other valid media.
    final location = jsonEncode([item.sharedFolderId, item.relativePath]);
    if (!_validMetadata(item) ||
        next.containsKey(item.id) ||
        !locations.add(location)) {
      if (strict) throw _InvalidRestoredCatalog();
      continue;
    }
    // Legacy sources can return MediaItem with thumbnails. Never retain those
    // bytes in the lightweight serving catalog.
    next[item.id] = MediaMetadata(
      id: item.id,
      deviceId: deviceId,
      name: item.name,
      mimeType: item.mimeType,
      size: item.size,
      modifiedMs: item.modifiedMs,
      sharedFolderId: item.sharedFolderId,
      sharedFolderName: item.sharedFolderName,
      relativePath: item.relativePath,
    );
  }
  final ordered = next.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  // Keep the v4 canonical encoding unchanged so existing released receivers
  // keep their revision and reuse thumbnails across source restarts.
  final digest = _CatalogDigest();
  final sink = sha256.startChunkedConversion(digest);
  sink.add(utf8.encode(jsonEncode([mediaProtocolVersion, deviceId])));
  for (final item in ordered) {
    sink.add(
      utf8.encode(
        jsonEncode([
          item.id,
          item.name,
          item.mimeType,
          item.size,
          item.modifiedMs,
          item.sharedFolderId,
          item.sharedFolderName,
          item.relativePath,
        ]),
      ),
    );
  }
  sink.close();
  return _PreparedCatalog(
    Map.unmodifiable(next),
    List.unmodifiable(ordered),
    digest.value.toString(),
  );
}

class _CatalogDigest implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
