import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import 'media_rpc.dart';

const parallelDownloadThreshold = 50 * 1024 * 1024;

class DownloadRange {
  const DownloadRange(this.offset, this.length);
  final int offset;
  final int length;
}

/// Every byte is covered once, including sizes not divisible by four.
List<DownloadRange> downloadRanges(int size) {
  if (size < 0) throw ArgumentError.value(size, 'size');
  final count = size > parallelDownloadThreshold ? 4 : 1;
  return List.generate(count, (index) {
    final start = size * index ~/ count;
    final end = size * (index + 1) ~/ count;
    return DownloadRange(start, end - start);
  });
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

class DownloadCancellation {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};
  bool get cancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  void check() {
    if (_cancelled) throw const DownloadCancelled();
  }

  void addListener(void Function() listener) {
    _listeners.add(listener);
    if (_cancelled) listener();
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

class MediaDownloader {
  MediaDownloader({MediaTransferClient Function(Peer)? clientFactory})
    : _clientFactory = clientFactory ?? MediaRpcClient.new;
  final MediaTransferClient Function(Peer) _clientFactory;

  Future<File> download({
    required Peer peer,
    required MediaItem item,
    required Directory directory,
    void Function(int, int)? onProgress,
  }) async {
    final taskId = const Uuid().v4();
    try {
      final file = await downloadResumable(
        peer: peer,
        item: item,
        directory: directory,
        taskId: taskId,
        onProgress: onProgress,
      );
      final name = safeMediaFilename(item.name);
      return await file.rename(
        p.join(
          directory.path,
          '${p.basenameWithoutExtension(name)}-$taskId${p.extension(name)}',
        ),
      );
    } finally {
      await discard(directory, taskId);
    }
  }

  static Directory _staging(Directory directory, String taskId) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(taskId)) {
      throw ArgumentError.value(taskId, 'taskId');
    }
    return Directory(p.join(directory.path, taskId));
  }

  static Future<void> discard(Directory directory, String taskId) async {
    final staging = _staging(directory, taskId);
    if (await staging.exists()) await staging.delete(recursive: true);
  }

  /// Each durable part is its own resume cursor. Keep parts on interruption;
  /// callers discard them only after the exported URI is committed to SQLite.
  Future<File> downloadResumable({
    required Peer peer,
    required MediaItem item,
    required Directory directory,
    required String taskId,
    DownloadCancellation? cancellation,
    void Function(int, int)? onProgress,
  }) async {
    if (peer.id != item.deviceId) {
      throw ArgumentError('Media belongs to a different device');
    }
    final cancel = cancellation ?? DownloadCancellation();
    cancel.check();
    final ranges = downloadRanges(item.size);
    final staging = _staging(directory, taskId);
    final manifest = File(p.join(staging.path, 'manifest.json'));
    final signature = jsonEncode([
      item.deviceId,
      item.id,
      item.size,
      item.modifiedMs,
    ]);
    if (await staging.exists()) {
      if (!await manifest.exists() ||
          await manifest.readAsString() != signature) {
        await staging.delete(recursive: true);
      }
    }
    await staging.create(recursive: true);
    await manifest.writeAsString(signature, flush: true);
    final parts = List.generate(
      ranges.length,
      (i) => File(p.join(staging.path, '$i.part')),
    );
    final sizes = <int>[];
    for (var i = 0; i < parts.length; i++) {
      var size = await parts[i].exists() ? await parts[i].length() : 0;
      if (size > ranges[i].length) {
        await parts[i].delete();
        size = 0;
      }
      sizes.add(size);
    }
    var received = sizes.fold(0, (a, b) => a + b);
    final clients = <MediaTransferClient>[];
    Future<void> closeClients() => Future.wait(
      clients.map((c) async {
        try {
          await c.close();
        } catch (_) {
          /* Preserve first failure. */
        }
      }),
    );
    void stop() {
      unawaited(closeClients());
    }

    cancel.addListener(stop);
    var failed = false;
    Object? firstError;
    StackTrace? firstStack;
    try {
      onProgress?.call(received, item.size);
      await Future.wait(
        ranges.indexed.map((entry) async {
          final (index, range) = entry;
          var size = sizes[index];
          if (size == range.length) {
            if (!await parts[index].exists()) await parts[index].create();
            return;
          }
          cancel.check();
          final client = _clientFactory(peer);
          clients.add(client);
          final output = await parts[index].open(mode: FileMode.append);
          try {
            await for (final chunk in client.readRange(
              item.id,
              range.offset + size,
              range.length - size,
            )) {
              cancel.check();
              if (failed) throw const DownloadCancelled();
              if (chunk.isEmpty || chunk.length > range.length - size) {
                throw const FormatException('收到的文件分片大小有误，请刷新后重试');
              }
              await output.writeFrom(chunk);
              size += chunk.length;
              received += chunk.length;
              onProgress?.call(received, item.size);
            }
            cancel.check();
            if (size != range.length) {
              throw const FormatException('文件分片未传输完整，请重试继续下载');
            }
          } catch (error, stack) {
            firstError ??= error;
            firstStack ??= stack;
            failed = true;
            await closeClients();
          } finally {
            await output.flush();
            await output.close();
          }
        }),
      );
      cancel.check();
      if (firstError != null) {
        Error.throwWithStackTrace(firstError!, firstStack!);
      }
      final combined = File(p.join(staging.path, 'complete.partial'));
      final output = await combined.open(mode: FileMode.write);
      try {
        for (final part in parts) {
          await for (final bytes in part.openRead()) {
            cancel.check();
            await output.writeFrom(bytes);
          }
        }
        await output.flush();
      } finally {
        await output.close();
      }
      cancel.check();
      if (await combined.length() != item.size) {
        throw const FormatException('下载文件大小与目录记录不符，请刷新后重试');
      }
      return combined;
    } finally {
      cancel.removeListener(stop);
      await closeClients();
    }
  }
}

/// Remote names never become paths and cannot escape the download directory.
String safeMediaFilename(String name) {
  var clean = p
      .basename(name.replaceAll('\\', '/'))
      .replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (clean.isEmpty || clean == '.' || clean == '..') return 'media';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³]) *(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(clean)) {
    clean = '_$clean';
  }
  // Count UTF-8 bytes, not characters, to leave room for the unique suffix on
  // filesystems with a 255-byte component limit (including non-ASCII names).
  if (utf8.encode(clean).length <= 180) return clean;
  final extension = p.extension(clean);
  final suffix = utf8.encode(extension).length <= 24 ? extension : '';
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in p.basenameWithoutExtension(clean).runes) {
    final character = String.fromCharCode(rune);
    final count = utf8.encode(character).length;
    if (bytes + count > 180 - utf8.encode(suffix).length) break;
    buffer.write(character);
    bytes += count;
  }
  return '$buffer$suffix';
}
