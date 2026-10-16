import 'dart:typed_data';

import 'models.dart';

/// Storage boundary for catalog synchronization. This interface has no Flutter
/// or SQLite dependency, so gRPC peers also run in a plain Dart process.
abstract interface class CatalogRepository {
  Future<String?> peerRevision(String deviceId);
  Future<void> markPeerSynced(Peer peer);
  Future<SnapshotCheckpoint?> findPeerSnapshot(
    Peer peer, {
    bool claim = false,
    String? expectedSessionId,
  });
  Future<List<MediaMetadata>> pendingSnapshotMedia(
    String sessionId, {
    int limit = 200,
  });
  Future<String> beginPeerSnapshot(
    Peer peer,
    String revision,
    int expectedCount,
  );
  Future<List<MediaMetadata>> stageMediaPage(
    String sessionId,
    List<MediaMetadata> items, {
    String? nextPageToken,
    bool metadataComplete = false,
  });
  Future<void> saveStagedThumbnail(
    String sessionId,
    String mediaId,
    Uint8List bytes,
  );
  Future<SnapshotCommit> commitPeerSnapshot(String sessionId);
  Future<void> abortPeerSnapshot(String sessionId);
}

/// Durable metadata pagination and thumbnail progress for one peer revision.
class SnapshotCheckpoint {
  const SnapshotCheckpoint({
    required this.sessionId,
    required this.revision,
    required this.totalCount,
    required this.receivedCount,
    required this.readyCount,
    required this.metadataComplete,
    this.nextPageToken,
  });

  final String sessionId;
  final String revision;
  final int totalCount;
  final int receivedCount;
  final int readyCount;
  final String? nextPageToken;
  final bool metadataComplete;
}
