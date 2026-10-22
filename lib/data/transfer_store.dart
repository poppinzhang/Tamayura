import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../core/models.dart';
import '../core/transfer_task.dart';
import '../l10n/app_locale.dart';
import '../network/downloader.dart' show MediaDownloader, safeMediaFilename;
import 'database_version.dart';
import 'platform_database.dart';

/// Shared by the UI and independent Android job engines. Claims and progress
/// updates are conditional so an old worker cannot overwrite a newer attempt.
class TransferStore {
  TransferStore._(this._db);
  final Database _db;
  static Future<TransferStore> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final f = factory ?? await platformDatabaseFactory();
    final db = await f.openDatabase(
      path ?? p.join(await f.getDatabasesPath(), 'tamayura_transfers.db'),
      options: OpenDatabaseOptions(
        version: 3, // v1.0.0 compatibility baseline.
        singleInstance: false,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA busy_timeout = 5000');
        },
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: rejectUnsupportedDatabaseVersion,
        onDowngrade: rejectUnsupportedDatabaseVersion,
      ),
    );
    return TransferStore._(db);
  }

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE transfers (
            id TEXT PRIMARY KEY, device_id TEXT NOT NULL, media_id TEXT NOT NULL,
            peer_name TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL,
            name TEXT NOT NULL, mime_type TEXT NOT NULL, size INTEGER NOT NULL,
            modified_ms INTEGER NOT NULL, thumbnail BLOB NOT NULL,
            shared_folder_id TEXT NOT NULL, shared_folder_name TEXT NOT NULL,
            relative_path TEXT NOT NULL, destination_directories TEXT NOT NULL,
            directory_uri TEXT NOT NULL, state TEXT NOT NULL,
            received INTEGER NOT NULL DEFAULT 0, attempt INTEGER NOT NULL DEFAULT 1,
            saved_uri TEXT, error TEXT, run_token TEXT, updated_ms INTEGER NOT NULL,
            outage_since_ms INTEGER,
            UNIQUE(device_id, media_id))''');
    await db.execute(
      'CREATE INDEX transfers_recency ON transfers(updated_ms DESC)',
    );
    await db.execute('''CREATE TABLE destination_directories (
            scope TEXT NOT NULL, identity TEXT NOT NULL, component TEXT NOT NULL,
            name_key TEXT NOT NULL,
            PRIMARY KEY(scope, identity), UNIQUE(scope, name_key)
          )''');
  }

  Future<TransferTask?> get(String id) async {
    final rows = await _db.query('transfers', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : TransferTask.fromRow(rows.single);
  }

  Future<TransferTask?> forMedia(String deviceId, String mediaId) async {
    final rows = await _db.query(
      'transfers',
      where: 'device_id = ? AND media_id = ?',
      whereArgs: [deviceId, mediaId],
    );
    return rows.isEmpty ? null : TransferTask.fromRow(rows.single);
  }

  Future<List<TransferTask>> recent() async {
    // Keep every unfinished task reachable so its storage can be released.
    final rows = await _db.rawQuery(
      "SELECT * FROM transfers WHERE state != 'completed' OR id IN (SELECT id FROM transfers ORDER BY updated_ms DESC LIMIT 100) ORDER BY updated_ms DESC",
    );
    return rows.map(TransferTask.fromRow).toList();
  }

  Future<TransferTask> enqueue(
    Peer peer,
    MediaItem item,
    String directoryUri,
  ) async {
    if (peer.id != item.deviceId) {
      throw FormatException(AppLocale.strings.errorTransferTarget);
    }
    validateMediaLocation(item);
    final segments = mediaPathSegments(item.relativePath);
    final id = await _db.transaction((txn) async {
      final rows = await txn.query(
        'transfers',
        where: 'device_id = ? AND media_id = ?',
        whereArgs: [peer.id, item.id],
      );
      final old = rows.isEmpty ? null : TransferTask.fromRow(rows.single);
      if (old?.state == DownloadState.discarded) {
        throw StateError(AppLocale.strings.errorStagingNotCleaned);
      }
      if (old?.active == true || old?.state == DownloadState.completed) {
        return old!.id;
      }
      final id = old?.id ?? const Uuid().v4();
      final directories = <String>[];
      // Persist identity-to-name assignments. Ordinary names stay readable;
      // equal names (including case/sanitization collisions) get a suffix.
      final scope = <String>[directoryUri];
      Future<void> allocate(String identity, String name) async {
        directories.add(
          await _directoryComponent(txn, jsonEncode(scope), identity, name),
        );
        scope.add(identity);
      }

      await allocate(peer.id, peer.name);
      await allocate(item.sharedFolderId, item.sharedFolderName);
      for (final segment in segments.take(segments.length - 1)) {
        await allocate(segment, segment);
      }
      await txn.insert('transfers', {
        'id': id,
        'device_id': peer.id,
        'media_id': item.id,
        'peer_name': peer.name,
        'host': peer.host,
        'port': peer.port,
        'name': item.name,
        'mime_type': item.mimeType,
        'size': item.size,
        'modified_ms': item.modifiedMs,
        'thumbnail': item.thumbnail,
        'shared_folder_id': item.sharedFolderId,
        'shared_folder_name': item.sharedFolderName,
        'relative_path': item.relativePath,
        'destination_directories': jsonEncode(directories),
        'directory_uri': directoryUri,
        'state': 'queued',
        'received': old?.item.hasSameMetadata(item) == true ? old!.received : 0,
        'attempt': (old?.attempt ?? 0) + 1,
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return id;
    });
    return (await get(id))!;
  }

  static Future<String> _directoryComponent(
    Transaction txn,
    String scope,
    String identity,
    String name,
  ) async {
    final previous = await txn.query(
      'destination_directories',
      where: 'scope = ? AND identity = ?',
      whereArgs: [scope, identity],
    );
    if (previous.isNotEmpty) return previous.single['component'] as String;
    var base = safeMediaFilename(name).replaceAll(RegExp(r'[. ]+$'), '');
    if (base.isEmpty) base = AppLocale.strings.fallbackFolderName;
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(base)) {
      base = '_$base';
    }
    var component = base;
    for (var suffix = 2; ; suffix++) {
      final collision = await txn.query(
        'destination_directories',
        columns: ['identity'],
        // SQLite NOCASE folds ASCII only; SAF may be backed by exFAT.
        where: 'scope = ? AND name_key = ?',
        whereArgs: [scope, component.toLowerCase()],
      );
      if (collision.isEmpty) break;
      component = '$base ($suffix)';
    }
    await txn.insert('destination_directories', {
      'scope': scope,
      'identity': identity,
      'component': component,
      'name_key': component.toLowerCase(),
    });
    return component;
  }

  Future<TransferTask?> claim(String id, String runToken) async {
    final count = await _db.update(
      'transfers',
      {
        'state': 'downloading',
        'run_token': runToken,
        'error': null,
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: "id = ? AND state IN ('queued','downloading','saving')",
      whereArgs: [id],
    );
    return count == 0 ? null : get(id);
  }

  Future<bool> update(
    String id,
    Map<String, Object?> values, {
    String? runToken,
  }) async {
    final count = await _db.update(
      'transfers',
      {...values, 'updated_ms': DateTime.now().millisecondsSinceEpoch},
      where: runToken == null
          ? 'id = ?'
          : "id = ? AND run_token = ? AND state NOT IN ('cancelled','discarded')",
      whereArgs: runToken == null ? [id] : [id, runToken],
    );
    return count != 0;
  }

  Future<void> failSetup(String id, int attempt, String error) async {
    await _db.update(
      'transfers',
      {
        'state': 'failed',
        'error': error,
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where:
          "id = ? AND attempt = ? AND state IN ('queued','downloading','saving')",
      whereArgs: [id, attempt],
    );
  }

  Future<void> cancel(String id) async {
    await _db.update(
      'transfers',
      {
        'state': 'cancelled',
        'run_token': null,
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: "id = ? AND state IN ('queued','downloading','saving')",
      whereArgs: [id],
    );
  }

  /// Fence the old worker before asking its scheduler to stop. Keep a durable
  /// tombstone until deletion succeeds, including across process termination.
  Future<bool> requestDiscard(String id) async =>
      await _db.update(
        'transfers',
        {
          'state': 'discarded',
          'run_token': null,
          'error': null,
          'updated_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: "id = ? AND state != 'completed'",
        whereArgs: [id],
      ) !=
      0;

  /// Call only after the scheduler and native writer have released their files.
  Future<void> finishDiscard(String id, Directory directory) async {
    try {
      await _db.transaction((txn) async {
        final rows = await txn.query(
          'transfers',
          where: 'id = ?',
          whereArgs: [id],
        );
        if (rows.firstOrNull?['state'] != 'discarded') return;
        await MediaDownloader.discard(directory, id);
        await txn.delete(
          'transfers',
          where: "id = ? AND state = 'discarded'",
          whereArgs: [id],
        );
      });
    } catch (_) {
      await _db.update(
        'transfers',
        {'error': AppLocale.strings.errorStagingCleanupFailed},
        where: "id = ? AND state = 'discarded'",
        whereArgs: [id],
      );
      rethrow;
    }
  }

  /// Recover completed/discarded jobs and orphan folders on startup. Preserve
  /// queued, failed and paused downloads, including tasks older than UI history.
  Future<void> cleanupStaging(
    Directory directory, {
    required Set<String> activeIds,
  }) async {
    Object? failure;
    final entries = await directory.exists()
        ? directory.list(followLinks: false)
        : const Stream<FileSystemEntity>.empty();
    await for (final entry in entries) {
      if (entry is! Directory) continue;
      final id = p.basename(entry.path);
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id) ||
          activeIds.contains(id)) {
        continue;
      }
      try {
        await _db.transaction((txn) async {
          final rows = await txn.query(
            'transfers',
            where: 'id = ?',
            whereArgs: [id],
          );
          final state = rows.firstOrNull?['state'];
          if (state != null && state != 'completed' && state != 'discarded') {
            return;
          }
          await MediaDownloader.discard(directory, id);
          if (state == 'discarded') {
            await txn.delete(
              'transfers',
              where: "id = ? AND state = 'discarded'",
              whereArgs: [id],
            );
          }
        });
      } catch (error) {
        failure ??= error;
      }
    }
    // A discard may have crashed after deleting the folder but before its row.
    final pending = await _db.query(
      'transfers',
      columns: ['id'],
      where: "state = 'discarded'",
    );
    for (final row in pending) {
      final id = row['id']! as String;
      if (activeIds.contains(id)) continue;
      try {
        await finishDiscard(id, directory);
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }

  Future<void> invalidate(String deviceId, String mediaId) async {
    await _db.update(
      'transfers',
      {
        'state': 'failed',
        'saved_uri': null,
        'error': AppLocale.strings.errorFileDeletedRedownload,
      },
      where: 'device_id = ? AND media_id = ?',
      whereArgs: [deviceId, mediaId],
    );
  }

  /// Remove the completed task after deleting its export. Query by identity,
  /// since completed tasks older than recent history still prevent enqueueing.
  Future<void> removeCompleted(String deviceId, String mediaId) async {
    await _db.delete(
      'transfers',
      where: "device_id = ? AND media_id = ? AND state = 'completed'",
      whereArgs: [deviceId, mediaId],
    );
  }

  Future<void> reconcile(
    Set<String> scheduledIds, {
    List<TransferTask>? candidates,
  }) async {
    for (final task in candidates ?? await recent()) {
      if (task.active && !scheduledIds.contains(task.id)) {
        await _db.update(
          'transfers',
          {
            'state': 'failed',
            'run_token': null,
            'error': AppLocale.strings.errorTaskInterrupted,
            'updated_ms': DateTime.now().millisecondsSinceEpoch,
          },
          where:
              "id = ? AND updated_ms = ? AND attempt = ? AND ${task.runToken == null ? 'run_token IS NULL' : 'run_token = ?'} AND state IN ('queued','downloading','saving')",
          whereArgs: [
            task.id,
            task.updatedMs,
            task.attempt,
            if (task.runToken != null) task.runToken!,
          ],
        );
      }
    }
  }

  Future<void> close() => _db.close();
}
