import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import '../core/models.dart';
import '../core/catalog_repository.dart';
import 'generated/media.pbgrpc.dart' as wire;

const mediaProtocolVersion = 3;
const maxCatalogPageSize = 500;
const mediaChunkSize = 256 * 1024;
const maxThumbnailBytes = 512 * 1024;

class MediaRpcServer {
  MediaRpcServer({required Peer identity, required LocalMediaSource source})
    : _service = _MediaService(identity, source);

  final _MediaService _service;
  Server? _server;
  int _lifecycleGeneration = 0;

  int get port => _server?.port ?? 0;
  List<MediaMetadata> get localMedia =>
      List.unmodifiable(_service.snapshot.values);
  String get revision => _service.revision;
  Object? get scanError => _service.scanError;

  /// Refresh the display name without changing identity or interrupting reads.
  void updateDeviceName(String name) {
    _service.identity = _service.identity.copyWith(name: name);
  }

  Future<void> start({int port = 0}) async {
    if (_server != null) throw StateError('Server is already running');
    final generation = ++_lifecycleGeneration;
    try {
      await refresh();
    } catch (_) {
      // Receiving from other devices must still work if this device's shared
      // directory permission expired. ListMedia reports the scan failure.
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
    } catch (_) {
      await server.shutdown();
      if (generation != _lifecycleGeneration) return;
      rethrow;
    }
  }

  /// Failed scans revoke sharing and produce an RPC error, so callers preserve
  /// their offline snapshot instead of interpreting failure as an empty folder.
  Future<void> refresh() => _service.refresh();

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

class _MediaService extends wire.MediaLibraryServiceBase {
  _MediaService(this.identity, this.source);

  Peer identity;
  final LocalMediaSource source;
  Map<String, MediaMetadata> snapshot = {};
  List<MediaMetadata> _ordered = [];
  String revision = '';
  Object? scanError;
  int _refreshGeneration = 0;
  int _thumbnailActive = 0;
  final _thumbnailWaiters = <Completer<void>>[];

  // A provider may finish after stop() has returned or another scan has begun.
  // Keep the last completed snapshot, but revoke every pending scan's commit.
  void invalidateRefresh() => _refreshGeneration++;

  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    try {
      final scanned = await source.scan();
      if (generation != _refreshGeneration) return;
      final next = <String, MediaMetadata>{};
      for (final item in scanned) {
        if (!_validMetadata(item) || next.containsKey(item.id)) {
          throw const FormatException('共享目录包含无效媒体信息，请重新选择目录');
        }
        // Never retain inline thumbnail bytes, even if a legacy adapter returns
        // MediaItem instances. The catalog is only a lightweight metadata index.
        next[item.id] = MediaMetadata(
          id: item.id,
          deviceId: identity.id,
          name: item.name,
          mimeType: item.mimeType,
          size: item.size,
          modifiedMs: item.modifiedMs,
          sharedFolderId: item.sharedFolderId,
          sharedFolderName: item.sharedFolderName,
          relativePath: item.relativePath,
        );
      }
      if (generation != _refreshGeneration) return;
      snapshot = Map.unmodifiable(next);
      _ordered = List.unmodifiable(
        next.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
      );
      // Identical catalogs retain their revision across source process restarts.
      // Encode one record at a time, avoiding a second whole-library buffer.
      final digest = _CatalogDigest();
      final sink = sha256.startChunkedConversion(digest);
      sink.add(utf8.encode(jsonEncode([mediaProtocolVersion, identity.id])));
      for (final item in _ordered) {
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
      revision = digest.value.toString();
      scanError = null;
    } catch (error) {
      if (generation != _refreshGeneration) return;
      snapshot = {};
      _ordered = [];
      revision = '';
      scanError = error;
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
    if (scanError != null) {
      throw const GrpcError.failedPrecondition(
        'Shared folder is unavailable; refresh on the source device',
      );
    }
    if (requested.isNotEmpty && requested != revision) {
      throw const GrpcError.aborted(
        'Catalog revision expired; restart pagination',
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
        throw const GrpcError.notFound('Thumbnail source is unavailable');
      }
      if (call.isCanceled || call.trailers == null) {
        throw const GrpcError.cancelled();
      }
      _checkRevision(request.revision);
      if (bytes.length > maxThumbnailBytes) {
        throw const GrpcError.resourceExhausted('Thumbnail is too large');
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
    var cursor = offset;
    final end = offset + length;
    while (cursor < end) {
      if (call.isCanceled || call.trailers == null) return;
      final wanted = (end - cursor).clamp(0, mediaChunkSize);
      Uint8List data;
      try {
        data = await source.readRange(item.id, cursor, wanted);
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
      throw const FormatException('对端不是兼容的 Tamayura 设备，请确认两端应用版本一致');
    }
    if (peer.id.isNotEmpty && peer.id != response.id) {
      throw const FormatException('此 IP 地址已由另一台设备使用，请重新发现设备');
    }
    return _identity = Peer(
      id: response.id,
      name: response.name,
      host: peer.host,
      port: peer.port,
      lastSeen: DateTime.now(),
      lastSync: peer.lastSync,
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
      throw const FormatException('对端目录分页信息无效，请刷新后重试');
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
      throw const FormatException('对端返回的媒体目录无效，请刷新后重试');
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
      throw const FormatException('对端缩略图无效，请刷新后重试');
    }
    return Uint8List.fromList(response.data);
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
            peer: device.copyWith(lastSync: DateTime.now()),
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
            throw const FormatException('对端目录数量不一致，请重试');
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
                final bytes = await thumbnail(item.id, revision: revision);
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
            throw const FormatException('对端目录版本发生变化，请重试');
          }
          received += page.items.length;
          if (received > total) throw const FormatException('对端目录数量不一致，请重试');
          final token = page.nextPageToken;
          if (token != null && !tokens.add(token)) {
            throw const FormatException('对端目录分页重复，请重试');
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
          throw const FormatException('媒体目录尚未接收完整，原有离线相册保持不变');
        }
        report(SyncPhase.committing);
        final committed = await repository.commitPeerSnapshot(stage);
        session = null;
        report(SyncPhase.completed);
        return SyncResult(
          peer: device.copyWith(lastSync: DateTime.now()),
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
    final response = _client.readFile(
      wire.ReadRequest(id: id, offset: Int64(offset), length: Int64(length)),
      options: CallOptions(timeout: const Duration(minutes: 30)),
    );
    await for (final chunk in response) {
      if (chunk.offset.toInt() != cursor ||
          chunk.data.isEmpty ||
          chunk.data.length > end - cursor) {
        throw const FormatException('收到的文件分片有误，请重新下载');
      }
      cursor += chunk.data.length;
      yield Uint8List.fromList(chunk.data);
    }
    if (cursor != end) throw const FormatException('文件传输提前结束，请重新下载');
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

class _CatalogDigest implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
