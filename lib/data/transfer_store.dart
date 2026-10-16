import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../core/models.dart';
import '../core/transfer_task.dart';
import '../network/downloader.dart' show safeMediaFilename;
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
        version: 2,
        singleInstance: false,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA busy_timeout = 5000');
        },
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: (db, _, _) async {
          // Pre-1.0 databases are disposable; only the current schema is kept.
          await db.execute('DROP TABLE IF EXISTS transfers');
          await db.execute('DROP TABLE IF EXISTS destination_directories');
          await _createSchema(db);
        },
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
    // Include every active job even when the recent history exceeds 100 entries.
    final rows = await _db.rawQuery(
      "SELECT * FROM transfers WHERE state IN ('queued','downloading','saving') OR id IN (SELECT id FROM transfers ORDER BY updated_ms DESC LIMIT 100) ORDER BY updated_ms DESC",
    );
    return rows.map(TransferTask.fromRow).toList();
  }

  Future<TransferTask> enqueue(
    Peer peer,
    MediaItem item,
    String directoryUri,
  ) async {
    if (peer.id != item.deviceId) {
      throw const FormatException('媒体所属设备或共享目录无效，请刷新相册');
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
    if (base.isEmpty) base = '目录';
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
          : "id = ? AND run_token = ? AND state != 'cancelled'",
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

  Future<void> invalidate(String deviceId, String mediaId) async {
    await _db.update(
      'transfers',
      {'state': 'failed', 'saved_uri': null, 'error': '文件已删除，请重新下载'},
      where: 'device_id = ? AND media_id = ?',
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
            'error': '任务已中断，点重试继续下载',
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
