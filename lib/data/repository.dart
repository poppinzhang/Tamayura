import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/catalog_repository.dart';
import 'platform_database.dart';

class _MediaReadView {
  const _MediaReadView({
    this.prefix = '',
    this.arguments = const [],
    this.table = 'media',
  });

  final String prefix;
  final List<Object?> arguments;
  final String table;

  String columns(String alias) => table == 'media'
      ? '$alias.*'
      : '$alias.*, ${thumbnail(alias)} AS thumbnail';

  String thumbnail(String alias) => table == 'media'
      ? '$alias.thumbnail'
      : '''CASE WHEN $alias.session_id IS NULL
          THEN (SELECT thumbnail FROM media m
            WHERE m.device_id = $alias.device_id AND m.id = $alias.id)
          ELSE (SELECT thumbnail FROM sync_media s
            WHERE s.session_id = $alias.session_id AND s.id = $alias.id)
        END''';
}

/// Stores thumbnails with their metadata so offline browsing needs no network.
class TamayuraRepository implements CatalogRepository {
  TamayuraRepository._(this._database);

  final Database _database;
  // The latest valid durable stage remains visible while disconnected.
  final Map<String, String> _previewSessions = {};

  static Future<TamayuraRepository> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final dbFactory = factory ?? await platformDatabaseFactory();
    final dbPath =
        path ?? p.join(await dbFactory.getDatabasesPath(), 'tamayura.db');
    final database = await dbFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 4,
        // UI and headless engines own independent connections and lifetimes.
        singleInstance: false,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.rawQuery('PRAGMA busy_timeout = 5000');
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, version) => _createSchema(db),
        onUpgrade: (db, oldVersion, newVersion) async {
          // Before v1.0.0 incompatible caches/settings are reset, not migrated.
          for (final table in [
            'sync_media',
            'sync_sessions',
            'media',
            'downloads',
            'peers',
            'settings',
          ]) {
            await db.execute('DROP TABLE IF EXISTS $table');
          }
          await _createSchema(db);
        },
      ),
    );
    final repository = TamayuraRepository._(database);
    final stages = await database.rawQuery(
      '''SELECT s.id, s.device_id FROM sync_sessions s
      LEFT JOIN peers p ON p.id = s.device_id
      WHERE s.base_generation = COALESCE(p.catalog_generation, 0)
      ORDER BY s.created_at DESC, s.rowid DESC''',
    );
    for (final stage in stages) {
      repository._previewSessions.putIfAbsent(
        stage['device_id']! as String,
        () => stage['id']! as String,
      );
    }
    return repository;
  }

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute('''CREATE TABLE peers (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, host TEXT NOT NULL,
      port INTEGER NOT NULL, last_seen INTEGER, last_sync INTEGER,
      catalog_revision TEXT NOT NULL DEFAULT '',
      catalog_generation INTEGER NOT NULL DEFAULT 0
    )''');
    await db.execute('''CREATE TABLE media (
      device_id TEXT NOT NULL REFERENCES peers(id) ON DELETE CASCADE,
      id TEXT NOT NULL, name TEXT NOT NULL, mime_type TEXT NOT NULL,
      size INTEGER NOT NULL CHECK(size >= 0), modified_ms INTEGER NOT NULL,
      shared_folder_id TEXT NOT NULL, shared_folder_name TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      thumbnail BLOB NOT NULL, thumbnail_cached INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (device_id, id),
      UNIQUE(device_id, shared_folder_id, relative_path)
    )''');
    // Download history survives a peer deleting the original media item.
    await db.execute('''CREATE TABLE downloads (
      device_id TEXT NOT NULL, media_id TEXT NOT NULL, uri TEXT NOT NULL,
      completed_at INTEGER NOT NULL, PRIMARY KEY (device_id, media_id)
    )''');
    await db.execute(
      'CREATE INDEX media_page_all ON media(modified_ms DESC, device_id, id)',
    );
    await db.execute(
      'CREATE INDEX media_page_peer ON media(device_id, modified_ms DESC, id)',
    );
    await db.execute(
      'CREATE INDEX media_page_collection ON media(device_id, shared_folder_id, modified_ms DESC, id)',
    );
    await db.execute('''CREATE TABLE sync_sessions (
      id TEXT PRIMARY KEY, device_id TEXT NOT NULL, name TEXT NOT NULL,
      host TEXT NOT NULL, port INTEGER NOT NULL, last_seen INTEGER,
      revision TEXT NOT NULL, expected_count INTEGER NOT NULL,
      base_generation INTEGER NOT NULL, created_at INTEGER NOT NULL,
      next_page_token TEXT, metadata_complete INTEGER NOT NULL DEFAULT 0
    )''');
    await db.execute(
      'CREATE INDEX sync_sessions_peer ON sync_sessions(device_id, created_at DESC)',
    );
    await db.execute('''CREATE TABLE sync_media (
      session_id TEXT NOT NULL REFERENCES sync_sessions(id) ON DELETE CASCADE ON UPDATE CASCADE,
      id TEXT NOT NULL, name TEXT NOT NULL, mime_type TEXT NOT NULL,
      size INTEGER NOT NULL CHECK(size >= 0), modified_ms INTEGER NOT NULL,
      shared_folder_id TEXT NOT NULL, shared_folder_name TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      thumbnail BLOB NOT NULL, thumbnail_cached INTEGER NOT NULL,
      PRIMARY KEY(session_id, id),
      UNIQUE(session_id, shared_folder_id, relative_path)
    )''');
  }

  Future<String?> getSetting(String key) async {
    final rows = await _database.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.single['value']! as String;
  }

  Future<void> setSetting(String key, String? value) async {
    if (value == null) {
      await _database.delete('settings', where: 'key = ?', whereArgs: [key]);
    } else {
      await _database.insert('settings', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<List<Peer>> listPeers() async {
    final rows = await _database.query(
      'peers',
      orderBy: 'name COLLATE NOCASE, id',
    );
    return rows.map(_peerFromRow).toList();
  }

  Future<void> upsertPeer(Peer peer) => _upsertPeer(_database, peer);

  // Do not use INSERT OR REPLACE: SQLite REPLACE deletes the parent row and
  // would cascade-delete all of its offline media while updating its address.
  static Future<void> _upsertPeer(DatabaseExecutor db, Peer peer) async {
    final values = <String, Object?>{
      'id': peer.id,
      'name': peer.name,
      'host': peer.host,
      'port': peer.port,
      if (peer.lastSeen != null)
        'last_seen': peer.lastSeen!.millisecondsSinceEpoch,
      if (peer.lastSync != null)
        'last_sync': peer.lastSync!.millisecondsSinceEpoch,
    };
    await db.insert(
      'peers',
      values,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await db.update('peers', values, where: 'id = ?', whereArgs: [peer.id]);
  }

  Future<List<MediaItem>> listMedia({String? deviceId}) async {
    final view = _mediaReadView();
    final rows = await _database.rawQuery(
      '${view.prefix}SELECT ${view.columns('v')} '
      'FROM ${view.table} v ${deviceId == null ? '' : 'WHERE device_id = ?'} '
      'ORDER BY modified_ms DESC, name COLLATE NOCASE, id',
      [...view.arguments, ?deviceId],
    );
    return rows.map(_mediaFromRow).toList();
  }

  Future<int> countMedia({String? deviceId, String? sharedFolderId}) async {
    final view = _mediaReadView();
    final conditions = [
      if (deviceId != null) 'device_id = ?',
      if (sharedFolderId != null) 'shared_folder_id = ?',
    ];
    return Sqflite.firstIntValue(
          await _database.rawQuery(
            '${view.prefix}SELECT COUNT(*) FROM ${view.table}${conditions.isEmpty ? '' : ' WHERE ${conditions.join(' AND ')}'}',
            [...view.arguments, ?deviceId, ?sharedFolderId],
          ),
        ) ??
        0;
  }

  /// Aggregate the whole offline library; read just one cover per shared root.
  Future<List<MediaCollection>> mediaCollections({String? deviceId}) async {
    final view = _mediaReadView();
    final rows = await _database.rawQuery(
      '''${view.prefix}SELECT grouped.device_id, grouped.shared_folder_id,
        grouped.shared_folder_name, grouped.item_count,
        (SELECT ${view.thumbnail('cover')} FROM ${view.table} cover
          WHERE cover.device_id = grouped.device_id
            AND cover.shared_folder_id = grouped.shared_folder_id
          ORDER BY cover.modified_ms DESC, cover.id LIMIT 1) AS thumbnail
      FROM (SELECT device_id, shared_folder_id, shared_folder_name,
        COUNT(*) AS item_count FROM ${view.table}
        ${deviceId == null ? '' : 'WHERE device_id = ?'}
        GROUP BY device_id, shared_folder_id) grouped
      ORDER BY grouped.shared_folder_name COLLATE NOCASE,
        grouped.device_id, grouped.shared_folder_id''',
      [...view.arguments, ?deviceId],
    );
    return rows
        .map(
          (row) => MediaCollection(
            deviceId: row['device_id']! as String,
            sharedFolderId: row['shared_folder_id']! as String,
            sharedFolderName: row['shared_folder_name']! as String,
            itemCount: row['item_count']! as int,
            thumbnail: Uint8List.fromList(row['thumbnail']! as List<int>),
          ),
        )
        .toList();
  }

  /// Keyset pagination never materializes the rest of the thumbnail library.
  Future<MediaPage> listMediaPage({
    String? deviceId,
    String? sharedFolderId,
    MediaCursor? after,
    int limit = 60,
  }) async {
    if (limit < 1 || limit > 200) throw ArgumentError.value(limit, 'limit');
    final view = _mediaReadView();
    final conditions = <String>[];
    final arguments = <Object?>[];
    if (deviceId != null) {
      conditions.add('device_id = ?');
      arguments.add(deviceId);
    }
    if (sharedFolderId != null) {
      conditions.add('shared_folder_id = ?');
      arguments.add(sharedFolderId);
    }
    if (after != null) {
      conditions.add(
        '(modified_ms < ? OR (modified_ms = ? AND (device_id > ? OR (device_id = ? AND id > ?))))',
      );
      arguments.addAll([
        after.modifiedMs,
        after.modifiedMs,
        after.deviceId,
        after.deviceId,
        after.mediaId,
      ]);
    }
    final rows = await _database.rawQuery(
      '${view.prefix}SELECT ${view.columns('v')} '
      'FROM ${view.table} v '
      '${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'} '
      'ORDER BY modified_ms DESC, device_id, id LIMIT ?',
      [...view.arguments, ...arguments, limit + 1],
    );
    final hasMore = rows.length > limit;
    final items = rows.take(limit).map(_mediaFromRow).toList();
    final last = items.lastOrNull;
    return MediaPage(
      items: items,
      totalCount: await countMedia(
        deviceId: deviceId,
        sharedFolderId: sharedFolderId,
      ),
      nextCursor: hasMore && last != null
          ? MediaCursor(
              modifiedMs: last.modifiedMs,
              deviceId: last.deviceId,
              mediaId: last.id,
            )
          : null,
    );
  }

  Future<MediaItem?> getMedia(String deviceId, String id) async {
    final view = _mediaReadView();
    final rows = await _database.rawQuery(
      '${view.prefix}SELECT ${view.columns('v')} '
      'FROM ${view.table} v WHERE device_id = ? AND id = ? LIMIT 1',
      [...view.arguments, deviceId, id],
    );
    return rows.isEmpty ? null : _mediaFromRow(rows.single);
  }

  @override
  Future<String?> peerRevision(String deviceId) async {
    final rows = await _database.query(
      'peers',
      columns: ['catalog_revision'],
      where: 'id = ?',
      whereArgs: [deviceId],
    );
    final value = rows.firstOrNull?['catalog_revision'] as String?;
    return value == null || value.isEmpty ? null : value;
  }

  @override
  Future<void> markPeerSynced(Peer peer) =>
      upsertPeer(peer.copyWith(lastSync: DateTime.now()));

  @override
  Future<SnapshotCheckpoint?> findPeerSnapshot(
    Peer peer, {
    bool claim = false,
    String? expectedSessionId,
  }) async {
    final checkpoint = await _database.transaction((txn) async {
      final rows = await txn.rawQuery(
        '''SELECT s.* FROM sync_sessions s
        LEFT JOIN peers p ON p.id = s.device_id
        WHERE s.device_id = ? AND s.base_generation = COALESCE(p.catalog_generation, 0)
        ORDER BY s.created_at DESC, s.rowid DESC LIMIT 1''',
        [peer.id],
      );
      if (expectedSessionId != null &&
          (rows.isEmpty || rows.single['id'] != expectedSessionId)) {
        throw const SnapshotConflictException();
      }
      if (rows.isEmpty) return null;
      final row = rows.single;
      final previousId = row['id']! as String;
      final sessionId = claim ? const Uuid().v4() : previousId;
      if (claim) {
        // Changing the primary key cascades without copying thumbnail BLOBs.
        // Late operations from the previous owner can no longer mutate this stage.
        await txn.update(
          'sync_sessions',
          {
            'id': sessionId,
            'name': peer.name,
            'host': peer.host,
            'port': peer.port,
            'last_seen': peer.lastSeen?.millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [previousId],
        );
      }
      final counts = (await txn.rawQuery(
        '''SELECT COUNT(*) AS received,
        COALESCE(SUM(thumbnail_cached), 0) AS ready FROM sync_media
        WHERE session_id = ?''',
        [sessionId],
      )).single;
      return SnapshotCheckpoint(
        sessionId: sessionId,
        revision: row['revision']! as String,
        totalCount: row['expected_count']! as int,
        receivedCount: counts['received']! as int,
        readyCount: counts['ready']! as int,
        nextPageToken: row['next_page_token'] as String?,
        metadataComplete: row['metadata_complete'] == 1,
      );
    });
    if (checkpoint != null) _previewSessions[peer.id] = checkpoint.sessionId;
    return checkpoint;
  }

  @override
  Future<List<MediaMetadata>> pendingSnapshotMedia(
    String sessionId, {
    int limit = 200,
  }) async {
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    return _database.transaction((txn) async {
      final session = await _session(txn, sessionId);
      final rows = await txn.query(
        'sync_media',
        columns: [
          'id',
          'name',
          'mime_type',
          'size',
          'modified_ms',
          'shared_folder_id',
          'shared_folder_name',
          'relative_path',
        ],
        where: 'session_id = ? AND thumbnail_cached = 0',
        whereArgs: [sessionId],
        orderBy: 'id',
        limit: limit,
      );
      return rows
          .map(
            (row) => MediaMetadata(
              id: row['id']! as String,
              deviceId: session['device_id']! as String,
              name: row['name']! as String,
              mimeType: row['mime_type']! as String,
              size: row['size']! as int,
              modifiedMs: row['modified_ms']! as int,
              sharedFolderId: row['shared_folder_id']! as String,
              sharedFolderName: row['shared_folder_name']! as String,
              relativePath: row['relative_path']! as String,
            ),
          )
          .toList();
    });
  }

  @override
  Future<String> beginPeerSnapshot(
    Peer peer,
    String revision,
    int expectedCount,
  ) async {
    if (revision.isEmpty || expectedCount < 0) {
      throw const FormatException('无效的媒体目录版本');
    }
    final token = const Uuid().v4();
    await _database.transaction((txn) async {
      await _upsertPeer(txn, peer);
      final rows = await txn.query(
        'peers',
        columns: ['catalog_generation'],
        where: 'id = ?',
        whereArgs: [peer.id],
      );
      await txn.insert('sync_sessions', {
        'id': token,
        'device_id': peer.id,
        'name': peer.name,
        'host': peer.host,
        'port': peer.port,
        'last_seen': peer.lastSeen?.millisecondsSinceEpoch,
        'revision': revision,
        'expected_count': expectedCount,
        'base_generation': rows.firstOrNull?['catalog_generation'] ?? 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    });
    _previewSessions[peer.id] = token;
    return token;
  }

  /// Returns only the entries needing thumbnails. Unchanged bytes are copied
  /// inside SQLite, never loaded into Dart or requested from the other phone.
  @override
  Future<List<MediaMetadata>> stageMediaPage(
    String sessionId,
    List<MediaMetadata> items, {
    String? nextPageToken,
    bool metadataComplete = false,
  }) async {
    if (items.length > 500) {
      throw ArgumentError('Catalog page exceeds 500 entries');
    }
    if (nextPageToken == '' || metadataComplete && nextPageToken != null) {
      throw const FormatException('无效的媒体目录分页断点');
    }
    return _database.transaction((txn) async {
      final session = await _session(txn, sessionId);
      final deviceId = session['device_id']! as String;
      final ids = <String>{};
      final batch = txn.batch();
      for (final item in items) {
        validateMediaLocation(item);
        if (item.deviceId != deviceId ||
            item.id.isEmpty ||
            item.size < 0 ||
            !ids.add(item.id)) {
          throw const FormatException('对端媒体目录包含无效或重复的文件');
        }
        final same = <Object?>[
          deviceId,
          item.id,
          item.name,
          item.mimeType,
          item.size,
          item.modifiedMs,
          item.sharedFolderId,
          item.sharedFolderName,
          item.relativePath,
        ];
        const match =
            'device_id = ? AND id = ? AND name = ? AND mime_type = ? AND size = ? AND modified_ms = ? AND shared_folder_id = ? AND shared_folder_name = ? AND relative_path = ? AND thumbnail_cached = 1';
        const stagedMatch =
            's.device_id = ? AND m.id = ? AND m.name = ? AND m.mime_type = ? AND m.size = ? AND m.modified_ms = ? AND m.shared_folder_id = ? AND m.shared_folder_name = ? AND m.relative_path = ? AND m.thumbnail_cached = 1';
        const cached =
            '(SELECT thumbnail FROM media WHERE $match UNION ALL SELECT m.thumbnail FROM sync_media m JOIN sync_sessions s ON s.id = m.session_id WHERE $stagedMatch LIMIT 1)';
        batch.rawInsert(
          '''INSERT INTO sync_media(session_id,id,name,mime_type,size,modified_ms,shared_folder_id,shared_folder_name,relative_path,thumbnail,thumbnail_cached)
          VALUES(?,?,?,?,?,?,?,?,?,COALESCE($cached,?),
          CASE WHEN $cached IS NOT NULL THEN 1 ELSE 0 END)''',
          [
            sessionId,
            item.id,
            item.name,
            item.mimeType,
            item.size,
            item.modifiedMs,
            item.sharedFolderId,
            item.sharedFolderName,
            item.relativePath,
            ...same,
            ...same,
            Uint8List(0),
            ...same,
            ...same,
          ],
        );
      }
      try {
        await batch.commit(noResult: true);
      } on DatabaseException catch (error) {
        if (error.isUniqueConstraintError()) {
          throw const FormatException('对端媒体目录包含重复文件，请重试');
        }
        rethrow;
      }
      final count =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COUNT(*) FROM sync_media WHERE session_id = ?',
              [sessionId],
            ),
          ) ??
          0;
      if (count > (session['expected_count']! as int)) {
        throw const FormatException('对端媒体目录数量不一致，请重试');
      }
      if (metadataComplete && count != session['expected_count']) {
        throw const FormatException('媒体目录尚未接收完整，原有离线相册保持不变');
      }
      await txn.update(
        'sync_sessions',
        {
          'next_page_token': nextPageToken,
          'metadata_complete': metadataComplete ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [sessionId],
      );
      if (ids.isEmpty) return [];
      final missing = await txn.query(
        'sync_media',
        columns: ['id'],
        where:
            'session_id = ? AND thumbnail_cached = 0 AND id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: [sessionId, ...ids],
      );
      final missingIds = missing.map((row) => row['id']! as String).toSet();
      return items.where((item) => missingIds.contains(item.id)).toList();
    });
  }

  @override
  Future<void> saveStagedThumbnail(
    String sessionId,
    String mediaId,
    Uint8List bytes,
  ) async {
    if (bytes.length > 512 * 1024) throw const FormatException('缩略图超过允许大小');
    await _database.transaction((txn) async {
      await _session(txn, sessionId);
      final count = await txn.update(
        'sync_media',
        {'thumbnail': bytes, 'thumbnail_cached': 1},
        where: 'session_id = ? AND id = ?',
        whereArgs: [sessionId, mediaId],
      );
      if (count != 1) throw const SnapshotConflictException();
    });
  }

  @override
  Future<SnapshotCommit> commitPeerSnapshot(String sessionId) async {
    final result = await _database.transaction((txn) async {
      final session = await _session(txn, sessionId);
      final deviceId = session['device_id']! as String;
      final current = await txn.query(
        'peers',
        columns: ['catalog_generation'],
        where: 'id = ?',
        whereArgs: [deviceId],
      );
      if ((current.firstOrNull?['catalog_generation'] ?? 0) !=
          session['base_generation']) {
        throw const SnapshotConflictException();
      }
      final counts = (await txn.rawQuery(
        'SELECT COUNT(*) AS total, COALESCE(SUM(CASE WHEN thumbnail_cached = 0 THEN 1 ELSE 0 END),0) AS missing FROM sync_media WHERE session_id = ?',
        [sessionId],
      )).single;
      final total = counts['total']! as int;
      if (total != session['expected_count'] || counts['missing'] != 0) {
        throw const FormatException('媒体目录尚未接收完整，原有离线相册保持不变');
      }
      final added =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              '''SELECT COUNT(*) FROM sync_media s WHERE s.session_id = ?
      AND NOT EXISTS(SELECT 1 FROM media m WHERE m.device_id = ? AND m.id = s.id)''',
              [sessionId, deviceId],
            ),
          ) ??
          0;
      final deleted =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              '''SELECT COUNT(*) FROM media m WHERE m.device_id = ?
      AND NOT EXISTS(SELECT 1 FROM sync_media s WHERE s.session_id = ? AND s.id = m.id)''',
              [deviceId, sessionId],
            ),
          ) ??
          0;
      await _upsertPeer(
        txn,
        Peer(
          id: deviceId,
          name: session['name']! as String,
          host: session['host']! as String,
          port: session['port']! as int,
          lastSeen: session['last_seen'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  session['last_seen']! as int,
                ),
          lastSync: DateTime.now(),
        ),
      );
      await txn.update(
        'peers',
        {
          'catalog_revision': session['revision'],
          'catalog_generation': (session['base_generation']! as int) + 1,
        },
        where: 'id = ?',
        whereArgs: [deviceId],
      );
      await txn.rawDelete(
        '''DELETE FROM media WHERE device_id = ? AND NOT EXISTS
      (SELECT 1 FROM sync_media s WHERE s.session_id = ? AND s.id = media.id)''',
        [deviceId, sessionId],
      );
      // Rewriting only changed rows avoids touching every cached thumbnail on an
      // incremental update. Download history is deliberately independent.
      await txn.rawInsert(
        '''INSERT OR REPLACE INTO media(device_id,id,name,mime_type,size,modified_ms,shared_folder_id,shared_folder_name,relative_path,thumbnail,thumbnail_cached)
      SELECT ?,s.id,s.name,s.mime_type,s.size,s.modified_ms,s.shared_folder_id,s.shared_folder_name,s.relative_path,s.thumbnail,s.thumbnail_cached FROM sync_media s
      WHERE s.session_id = ? AND NOT EXISTS(SELECT 1 FROM media m WHERE m.device_id = ? AND m.id = s.id
        AND m.name = s.name AND m.mime_type = s.mime_type AND m.size = s.size AND m.modified_ms = s.modified_ms AND m.shared_folder_id = s.shared_folder_id AND m.shared_folder_name = s.shared_folder_name AND m.relative_path = s.relative_path AND m.thumbnail_cached = 1)''',
        [deviceId, sessionId, deviceId],
      );
      await txn.delete(
        'sync_sessions',
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );
      return SnapshotCommit(
        totalCount: total,
        addedCount: added,
        deletedCount: deleted,
      );
    });
    _removePreview(sessionId);
    return result;
  }

  @override
  Future<void> abortPeerSnapshot(String sessionId) async {
    // Stop previewing immediately even if on-disk stage cleanup fails.
    _removePreview(sessionId);
    await _database.delete(
      'sync_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  void _removePreview(String sessionId) =>
      _previewSessions.removeWhere((_, value) => value == sessionId);

  _MediaReadView _mediaReadView() {
    if (_previewSessions.isEmpty) return const _MediaReadView();
    final sessions = _previewSessions.values.toList(growable: false);
    const columns =
        'id, name, mime_type, size, modified_ms, shared_folder_id, shared_folder_name, relative_path';
    String qualified(String alias) =>
        columns.split(', ').map((column) => '$alias.$column').join(', ');
    return _MediaReadView(
      // Keep BLOBs out of the combined relation: pagination reads bytes only
      // for the requested page, and collection aggregation only for covers.
      prefix:
          '''WITH ready_media AS (
        SELECT s.device_id, ${qualified('m')}, s.id AS session_id
        FROM sync_media m JOIN sync_sessions s ON s.id = m.session_id
        LEFT JOIN peers p ON p.id = s.device_id
        WHERE s.id IN (${List.filled(sessions.length, '?').join(',')})
          AND m.thumbnail_cached = 1
          AND s.base_generation = COALESCE(p.catalog_generation, 0)
      ), visible_media AS (
        SELECT m.device_id, ${qualified('m')}, NULL AS session_id
        FROM media m WHERE NOT EXISTS (
          SELECT 1 FROM ready_media r
          WHERE r.device_id = m.device_id AND r.id = m.id)
        UNION ALL
        SELECT * FROM ready_media
      ) ''',
      arguments: sessions,
      table: 'visible_media',
    );
  }

  static Future<Map<String, Object?>> _session(
    DatabaseExecutor db,
    String id,
  ) async {
    final rows = await db.rawQuery(
      '''SELECT s.* FROM sync_sessions s
      LEFT JOIN peers p ON p.id = s.device_id
      WHERE s.id = ? AND s.base_generation = COALESCE(p.catalog_generation, 0)''',
      [id],
    );
    if (rows.isEmpty) throw const SnapshotConflictException();
    return rows.single;
  }

  /// Call only after receiving an entire, successfully completed RPC snapshot.
  /// Deletions and additions become visible together; failures roll back both.
  Future<void> replacePeerSnapshot(Peer peer, List<MediaItem> items) async {
    final ids = <String>{};
    for (final item in items) {
      validateMediaLocation(item);
      if (item.deviceId != peer.id ||
          item.id.isEmpty ||
          item.size < 0 ||
          !ids.add(item.id)) {
        throw const FormatException('对端媒体目录包含无效或重复的文件，请刷新后重试');
      }
    }
    await _database.transaction((txn) async {
      await _upsertPeer(txn, peer.copyWith(lastSync: DateTime.now()));
      await txn.rawUpdate(
        "UPDATE peers SET catalog_revision = '', catalog_generation = catalog_generation + 1 WHERE id = ?",
        [peer.id],
      );
      await txn.delete('media', where: 'device_id = ?', whereArgs: [peer.id]);
      final batch = txn.batch();
      for (final item in items) {
        batch.insert('media', {
          'device_id': item.deviceId,
          'id': item.id,
          'name': item.name,
          'mime_type': item.mimeType,
          'size': item.size,
          'modified_ms': item.modifiedMs,
          'shared_folder_id': item.sharedFolderId,
          'shared_folder_name': item.sharedFolderName,
          'relative_path': item.relativePath,
          'thumbnail': item.thumbnail,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> saveDownload(DownloadRecord record) async {
    await _database.insert('downloads', {
      'device_id': record.deviceId,
      'media_id': record.mediaId,
      'uri': record.uri,
      'completed_at': record.completedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<DownloadRecord?> getDownload(String deviceId, String mediaId) async {
    final rows = await _database.query(
      'downloads',
      where: 'device_id = ? AND media_id = ?',
      whereArgs: [deviceId, mediaId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return DownloadRecord(
      deviceId: deviceId,
      mediaId: mediaId,
      uri: row['uri']! as String,
      completedAt: DateTime.fromMillisecondsSinceEpoch(
        row['completed_at']! as int,
      ),
    );
  }

  Future<void> removeDownload(String deviceId, String mediaId) async {
    await _database.delete(
      'downloads',
      where: 'device_id = ? AND media_id = ?',
      whereArgs: [deviceId, mediaId],
    );
  }

  Future<void> close() => _database.close();

  static MediaItem _mediaFromRow(Map<String, Object?> row) => MediaItem(
    id: row['id']! as String,
    deviceId: row['device_id']! as String,
    name: row['name']! as String,
    mimeType: row['mime_type']! as String,
    size: row['size']! as int,
    modifiedMs: row['modified_ms']! as int,
    sharedFolderId: row['shared_folder_id']! as String,
    sharedFolderName: row['shared_folder_name']! as String,
    relativePath: row['relative_path']! as String,
    thumbnail: Uint8List.fromList(row['thumbnail']! as List<int>),
  );

  static Peer _peerFromRow(Map<String, Object?> row) => Peer(
    id: row['id']! as String,
    name: row['name']! as String,
    host: row['host']! as String,
    port: row['port']! as int,
    lastSeen: row['last_seen'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['last_seen']! as int),
    lastSync: row['last_sync'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['last_sync']! as int),
  );
}
