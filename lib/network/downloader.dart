import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../l10n/app_locale.dart';
import 'media_rpc.dart';

const parallelDownloadThreshold = 50 * 1024 * 1024;

/// Sleep, Wi-Fi loss or a peer leaving the LAN rarely delivers a TCP reset.
/// A range receiving no bytes for this long is closed and retried instead.
const defaultStallTimeout = Duration(seconds: 30);

/// No bytes arrived within the stall timeout; the peer or LAN went silent.
class TransferStalled implements Exception {
  const TransferStalled();
  @override
  String toString() => 'TransferStalled: no data from the peer';
}

/// The peer or LAN is temporarily unreachable, so retrying later can succeed.
/// Missing files, changed sizes and invalid data need the user's attention.
bool isTransientTransferError(Object error) {
  if (error is TransferStalled || error is SocketException) return true;
  if (error is! GrpcError) return false;
  return switch (error.code) {
    StatusCode.unavailable ||
    StatusCode.deadlineExceeded ||
    StatusCode.cancelled ||
    // grpc-dart reports a connection terminated mid-stream as UNKNOWN.
    StatusCode.unknown => true,
    _ => false,
  };
}

class DownloadRange {
  const DownloadRange(this.offset, this.length);
  final int offset;
  final int length;
}

/// Complete ranges in file order. Native storage streams them into the chosen
/// destination without creating another full-size file in private storage.
class DownloadParts {
  DownloadParts(List<File> files, this.totalSize)
    : files = List.unmodifiable(files);
  final List<File> files;
  final int totalSize;
  List<String> get paths => files.map((file) => file.path).toList();

  Stream<List<int>> openRead() async* {
    for (final file in files) {
      yield* file.openRead();
    }
  }
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

  /// Waits for [delay] unless cancelled first, then throws [DownloadCancelled].
  Future<void> sleep(Duration delay) async {
    final woken = Completer<void>();
    void wake() {
      if (!woken.isCompleted) woken.complete();
    }

    final timer = Timer(delay, wake);
    addListener(wake);
    try {
      await woken.future;
    } finally {
      timer.cancel();
      removeListener(wake);
    }
    check();
  }
}

class MediaDownloader {
  MediaDownloader({
    MediaTransferClient Function(Peer)? clientFactory,
    this.stallTimeout = defaultStallTimeout,
  }) : _clientFactory = clientFactory ?? MediaRpcClient.new;
  final MediaTransferClient Function(Peer) _clientFactory;
  final Duration stallTimeout;

  Future<File> download({
    required Peer peer,
    required MediaItem item,
    required Directory directory,
    void Function(int, int)? onProgress,
  }) async {
    final taskId = const Uuid().v4();
    File? destination;
    try {
      final parts = await downloadResumable(
        peer: peer,
        item: item,
        directory: directory,
        taskId: taskId,
        onProgress: onProgress,
      );
      final name = safeMediaFilename(item.name);
      destination = File(
        p.join(
          directory.path,
          '${p.basenameWithoutExtension(name)}-$taskId${p.extension(name)}',
        ),
      );
      final output = await destination.open(mode: FileMode.write);
      try {
        await for (final bytes in parts.openRead()) {
          await output.writeFrom(bytes);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      return destination;
    } catch (_) {
      if (destination != null && await destination.exists()) {
        await destination.delete();
      }
      rethrow;
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

  static String _signature(MediaItem item) =>
      jsonEncode([item.deviceId, item.id, item.size, item.modifiedMs]);

  static List<File> _parts(Directory staging, int count) => List.generate(
    count,
    (index) => File(p.join(staging.path, '$index.part')),
  );

  /// Only actual files matching the current media metadata count as progress.
  /// SQLite progress can lag behind disk writes or outlive missing temp files.
  static Future<int> stagedBytes({
    required MediaItem item,
    required Directory directory,
    required String taskId,
  }) async {
    final staging = _staging(directory, taskId);
    final manifest = File(p.join(staging.path, 'manifest.json'));
    if (!await manifest.exists() ||
        await manifest.readAsString() != _signature(item)) {
      return 0;
    }
    final ranges = downloadRanges(item.size);
    final parts = _parts(staging, ranges.length);
    var received = 0;
    for (var index = 0; index < parts.length; index++) {
      final size = await parts[index].exists()
          ? await parts[index].length()
          : 0;
      if (size <= ranges[index].length) received += size;
    }
    return received;
  }

  /// A failed export can be retried entirely offline once every range exists.
  static Future<DownloadParts?> completedParts({
    required MediaItem item,
    required Directory directory,
    required String taskId,
  }) async {
    final staging = _staging(directory, taskId);
    final manifest = File(p.join(staging.path, 'manifest.json'));
    if (!await manifest.exists() ||
        await manifest.readAsString() != _signature(item)) {
      return null;
    }
    final ranges = downloadRanges(item.size);
    final parts = _parts(staging, ranges.length);
    for (var index = 0; index < parts.length; index++) {
      if (!await parts[index].exists() ||
          await parts[index].length() != ranges[index].length) {
        return null;
      }
    }
    return DownloadParts(parts, item.size);
  }

  /// Each durable part is its own resume cursor. Keep parts on interruption;
  /// callers discard them only after the exported URI is committed to SQLite.
  Future<DownloadParts> downloadResumable({
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
    final signature = _signature(item);
    if (await staging.exists()) {
      if (!await manifest.exists() ||
          await manifest.readAsString() != signature) {
        await staging.delete(recursive: true);
      }
    }
    await staging.create(recursive: true);
    await manifest.writeAsString(signature, flush: true);
    final parts = _parts(staging, ranges.length);
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
          // Only arriving bytes prove the peer is alive; local disk writes do
          // not count. Close the channel before failing: cancelling a stream
          // on a silently dead connection can wait indefinitely.
          var stalled = false;
          Timer? watchdog;
          void arm() {
            watchdog?.cancel();
            watchdog = Timer(stallTimeout, () {
              stalled = true;
              unawaited(_closeQuietly(client));
            });
          }

          try {
            arm();
            await for (final chunk in client.readRange(
              item.id,
              range.offset + size,
              range.length - size,
            )) {
              watchdog?.cancel();
              cancel.check();
              if (failed) throw const DownloadCancelled();
              if (chunk.isEmpty || chunk.length > range.length - size) {
                throw FormatException(AppLocale.strings.errorChunkSize);
              }
              await output.writeFrom(chunk);
              size += chunk.length;
              received += chunk.length;
              onProgress?.call(received, item.size);
              arm();
            }
            watchdog?.cancel();
            cancel.check();
            if (stalled) throw const TransferStalled();
            if (size != range.length) {
              throw FormatException(AppLocale.strings.errorChunkIncomplete);
            }
          } catch (error, stack) {
            firstError ??= stalled && !cancel.cancelled
                ? const TransferStalled()
                : error;
            firstStack ??= stack;
            failed = true;
            await closeClients();
          } finally {
            watchdog?.cancel();
            await output.flush();
            await output.close();
          }
        }),
      );
      cancel.check();
      if (firstError != null) {
        Error.throwWithStackTrace(firstError!, firstStack!);
      }
      for (var index = 0; index < parts.length; index++) {
        if (await parts[index].length() != ranges[index].length) {
          throw FormatException(AppLocale.strings.errorDownloadSizeMismatch);
        }
      }
      return DownloadParts(parts, item.size);
    } finally {
      cancel.removeListener(stop);
      await closeClients();
    }
  }

  static Future<void> _closeQuietly(MediaTransferClient client) async {
    try {
      await client.close();
    } catch (_) {
      // The range reports the stall; a failing close adds nothing.
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
