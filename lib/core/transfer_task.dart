import 'dart:typed_data';
import 'dart:convert';
import 'models.dart';

enum DownloadState {
  queued,
  downloading,
  saving,
  completed,
  failed,
  cancelled,
  discarded,
}

class TransferTask {
  const TransferTask({
    required this.id,
    required this.peer,
    required this.item,
    required this.directoryUri,
    required this.destinationDirectories,
    required this.state,
    required this.received,
    required this.attempt,
    required this.updatedMs,
    this.savedUri,
    this.error,
    this.runToken,
    this.outageSinceMs,
  });
  final String id, directoryUri;
  final List<String> destinationDirectories;
  final Peer peer;
  final MediaItem item;
  final DownloadState state;
  final int received, attempt, updatedMs;
  final String? savedUri, error, runToken;

  /// When the peer first became unreachable without any bytes arriving since.
  final int? outageSinceMs;
  bool get active =>
      state == DownloadState.queued ||
      state == DownloadState.downloading ||
      state == DownloadState.saving;
  factory TransferTask.fromRow(Map<String, Object?> row) => TransferTask(
    id: row['id'] as String,
    peer: Peer(
      id: row['device_id'] as String,
      name: row['peer_name'] as String,
      host: row['host'] as String,
      port: row['port'] as int,
    ),
    item: MediaItem(
      id: row['media_id'] as String,
      deviceId: row['device_id'] as String,
      name: row['name'] as String,
      sharedFolderId: row['shared_folder_id'] as String,
      sharedFolderName: row['shared_folder_name'] as String,
      relativePath: row['relative_path'] as String,
      mimeType: row['mime_type'] as String,
      size: row['size'] as int,
      modifiedMs: row['modified_ms'] as int,
      thumbnail: row['thumbnail'] as Uint8List,
    ),
    directoryUri: row['directory_uri'] as String,
    destinationDirectories: List<String>.unmodifiable(
      (jsonDecode(row['destination_directories'] as String) as List)
          .cast<String>(),
    ),
    state: DownloadState.values.byName(row['state'] as String),
    received: row['received'] as int,
    attempt: row['attempt'] as int,
    updatedMs: row['updated_ms'] as int,
    savedUri: row['saved_uri'] as String?,
    error: row['error'] as String?,
    runToken: row['run_token'] as String?,
    outageSinceMs: row['outage_since_ms'] as int?,
  );
}
