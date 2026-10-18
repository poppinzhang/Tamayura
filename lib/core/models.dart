import 'dart:typed_data';

import '../l10n/app_locale.dart';

class SharedFolder {
  const SharedFolder({required this.id, required this.uri, required this.name});

  final String id;
  final String uri;
  final String name;

  Map<String, String> toJson() => {'id': id, 'uri': uri, 'name': name};

  factory SharedFolder.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final uri = json['uri'];
    final name = json['name'];
    if (id is! String ||
        id.isEmpty ||
        uri is! String ||
        uri.isEmpty ||
        name is! String ||
        name.isEmpty) {
      throw FormatException(AppLocale.strings.errorSharedFolderConfig);
    }
    return SharedFolder(id: id, uri: uri, name: name);
  }
}

/// A media path is relative to one shared root and uses protocol '/' separators.
List<String> mediaPathSegments(String relativePath) {
  if (relativePath.isEmpty ||
      relativePath.length > 4096 ||
      relativePath.contains('\\') ||
      RegExp(r'^[a-zA-Z]:|[\x00-\x1f\x7f-\x9f]').hasMatch(relativePath)) {
    throw FormatException(AppLocale.strings.errorMediaPath);
  }
  final segments = relativePath.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw FormatException(AppLocale.strings.errorMediaPath);
  }
  return segments;
}

void validateMediaLocation(MediaMetadata item) {
  if (item.sharedFolderId.isEmpty ||
      item.sharedFolderId.length > 512 ||
      mediaPathSegments(item.sharedFolderId).length != 1 ||
      mediaPathSegments(item.sharedFolderName).length != 1 ||
      mediaPathSegments(item.relativePath).last != item.name) {
    throw FormatException(AppLocale.strings.errorMediaFolderPath);
  }
}

/// Whether the user allows synchronizing a remembered device's album.
/// A device found by discovery waits for confirmation; addresses entered or
/// scanned by the user are approved by that action.
enum PeerSyncApproval { pending, approved, declined }

class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.lastSeen,
    this.lastSync,
    this.lastSuccessfulSync,
    this.syncApproval = PeerSyncApproval.approved,
    this.lastSyncFailed = false,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final DateTime? lastSeen;

  /// Start of the latest synchronization attempt, including failed attempts.
  final DateTime? lastSync;

  /// Completion of the latest successful catalog synchronization.
  final DateTime? lastSuccessfulSync;

  /// Read from storage only; peer writes never change the user's decision.
  final PeerSyncApproval syncApproval;

  /// The latest recorded attempt failed or was interrupted. Read-only, like
  /// [syncApproval]: attempts and successful commits maintain it in storage.
  final bool lastSyncFailed;

  Peer copyWith({
    String? name,
    String? host,
    int? port,
    DateTime? lastSeen,
    DateTime? lastSync,
    DateTime? lastSuccessfulSync,
  }) => Peer(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    lastSeen: lastSeen ?? this.lastSeen,
    lastSync: lastSync ?? this.lastSync,
    lastSuccessfulSync: lastSuccessfulSync ?? this.lastSuccessfulSync,
    syncApproval: syncApproval,
    lastSyncFailed: lastSyncFailed,
  );
}

class MediaMetadata {
  const MediaMetadata({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.modifiedMs,
    this.sharedFolderId = '',
    this.sharedFolderName = '',
    this.relativePath = '',
  });

  final String id;
  final String deviceId;
  final String name;
  final String mimeType;
  final int size;
  final int modifiedMs;
  final String sharedFolderId;
  final String sharedFolderName;
  final String relativePath;
  String get key => '$deviceId/$id';
  bool get isVideo => mimeType.startsWith('video/');

  bool hasSameMetadata(MediaMetadata other) =>
      id == other.id &&
      deviceId == other.deviceId &&
      name == other.name &&
      mimeType == other.mimeType &&
      size == other.size &&
      modifiedMs == other.modifiedMs &&
      sharedFolderId == other.sharedFolderId &&
      sharedFolderName == other.sharedFolderName &&
      relativePath == other.relativePath;

  MediaItem withThumbnail(Uint8List bytes) => MediaItem(
    id: id,
    deviceId: deviceId,
    name: name,
    mimeType: mimeType,
    size: size,
    modifiedMs: modifiedMs,
    sharedFolderId: sharedFolderId,
    sharedFolderName: sharedFolderName,
    relativePath: relativePath,
    thumbnail: bytes,
  );
}

class MediaItem extends MediaMetadata {
  const MediaItem({
    required super.id,
    required super.deviceId,
    required super.name,
    required super.mimeType,
    required super.size,
    required super.modifiedMs,
    super.sharedFolderId,
    super.sharedFolderName,
    super.relativePath,
    required this.thumbnail,
  });
  final Uint8List thumbnail;
}

class MediaCollection {
  const MediaCollection({
    required this.deviceId,
    required this.sharedFolderId,
    required this.sharedFolderName,
    required this.itemCount,
    required this.thumbnail,
  });

  final String deviceId;
  final String sharedFolderId;
  final String sharedFolderName;
  final int itemCount;
  final Uint8List thumbnail;
  String get key => '$deviceId/$sharedFolderId';
}

enum MediaSortOrder {
  nameAscending,
  nameDescending,
  dateAscending,
  dateDescending,
}

/// A complete album position index without thumbnail bytes or file payloads.
class MediaScrollEntry {
  const MediaScrollEntry({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.modified,
  });

  final String id, deviceId, name;
  final DateTime modified;
  String get key => '$deviceId/$id';
}

class MediaCursor {
  const MediaCursor({
    required this.modifiedMs,
    required this.deviceId,
    required this.mediaId,
    this.name = '',
    this.sortOrder = MediaSortOrder.dateDescending,
  });
  final int modifiedMs;
  final String deviceId;
  final String mediaId;
  final String name;
  final MediaSortOrder sortOrder;
}

class MediaPage {
  const MediaPage({
    required this.items,
    required this.totalCount,
    this.nextCursor,
  });
  final List<MediaItem> items;
  final int totalCount;
  final MediaCursor? nextCursor;
}

class CatalogPage {
  const CatalogPage({
    required this.revision,
    required this.items,
    required this.totalCount,
    this.nextPageToken,
    this.notModified = false,
  });
  final String revision;
  final List<MediaMetadata> items;
  final int totalCount;
  final String? nextPageToken;
  final bool notModified;
}

class SnapshotCommit {
  const SnapshotCommit({
    required this.totalCount,
    required this.addedCount,
    required this.deletedCount,
  });
  final int totalCount;
  final int addedCount;
  final int deletedCount;
}

enum SyncPhase { connecting, receiving, committing, completed, failed }

/// Progress belongs to one catalog attempt; a revision retry resets its counts.
class SyncProgress {
  const SyncProgress({
    required this.peerId,
    required this.peerName,
    required this.phase,
    this.totalCount,
    this.receivedCount = 0,
    this.readyCount = 0,
    this.attempt = 0,
    this.error,
    this.sessionId,
  });

  final String peerId;
  final String peerName;
  final SyncPhase phase;
  final int? totalCount;
  final int receivedCount;

  /// Includes unchanged entries whose cached thumbnails can be reused.
  final int readyCount;
  final int attempt;
  final String? error;

  /// Runtime identity shared across endpoint resolution and catalog retries.
  /// Restored checkpoints have no active session; this is never persisted.
  final Object? sessionId;
}

class SyncResult extends SnapshotCommit {
  const SyncResult({
    required this.peer,
    required this.revision,
    required super.totalCount,
    required super.addedCount,
    required super.deletedCount,
    required this.thumbnailRequests,
  });
  final Peer peer;
  final String revision;
  final int thumbnailRequests;
}

class SnapshotConflictException implements Exception {
  const SnapshotConflictException();
  @override
  String toString() => AppLocale.strings.errorCatalogChanged;
}

/// Largest original-file range read from a native adapter in one call, and
/// the payload of one gRPC file chunk. Larger reads amortize per-call
/// authorization and path resolution; tune it with real-device measurements.
const mediaReadChunkBytes = 2 * 1024 * 1024;

/// Native adapters keep file identifiers opaque and scoped to the shared folder.
abstract class LocalMediaSource {
  /// Lists shareable media. Leave out a file that cannot be read or named
  /// safely; throw only when a shared folder itself cannot be scanned.
  Future<List<MediaMetadata>> scan();

  /// Returns empty bytes when this one file is missing, changed or cannot be
  /// decoded. Throw for permission, catalog or resource failures: peers retry
  /// those later instead of storing an empty preview.
  Future<Uint8List> readThumbnail(String id);

  /// Throws [MediaSourceInterrupted] when the catalog changed during the read,
  /// so peers retry instead of treating the file as deleted.
  Future<Uint8List> readRange(String id, int offset, int length);
}

/// The shared catalog was replaced or revoked while a read was in progress.
class MediaSourceInterrupted implements Exception {
  const MediaSourceInterrupted();
  @override
  String toString() => AppLocale.strings.errorSharedFoldersChanged;
}

class DownloadRecord {
  const DownloadRecord({
    required this.deviceId,
    required this.mediaId,
    required this.uri,
    required this.completedAt,
  });

  final String deviceId;
  final String mediaId;
  final String uri;
  final DateTime completedAt;
}
