import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../app/errors.dart';
import '../core/models.dart';
import '../core/transfer_task.dart';
import '../data/repository.dart';
import '../data/transfer_store.dart';
import '../l10n/app_locale.dart';
import '../network/downloader.dart';
import '../network/media_rpc.dart';
import '../platform/android_bridge.dart';
import '../platform/platform_bridge.dart';

/// Runs inside the JobService's own FlutterEngine, independent of the activity.
Future<void> runBackgroundTransfer() async {
  const channel = MethodChannel('tamayura/background');
  const bridge = AndroidBridge();
  final cancellation = DownloadCancellation();
  var userCancelled = false;
  channel.setMethodCallHandler((call) async {
    if (call.method == 'stop') {
      userCancelled = (call.arguments as Map?)?['cancelled'] == true;
      cancellation.cancel();
    }
  });
  TransferStore? store;
  TamayuraRepository? repository;
  String? taskId;
  int? attempt;
  try {
    final args = await channel.invokeMapMethod<String, dynamic>('ready');
    // Stored task errors use the interface language saved by the app.
    AppLocale.language = AppLanguage.parse(args?['language'] as String?);
    final id = args?['taskId'] as String?;
    if (id == null) throw StateError(AppLocale.strings.errorTaskIdMissing);
    taskId = id;
    store = await TransferStore.open();
    attempt = (await store.get(id))?.attempt;
    cancellation.check();
    repository = await TamayuraRepository.open();
    final runner = TransferRunner(
      store: store,
      repository: repository,
      bridge: bridge,
      directory: Directory(await bridge.transferDirectory()),
      progress: (received, total, name) async {
        await channel.invokeMethod<void>('progress', {
          'received': received,
          'total': total,
          'name': name,
        });
      },
    );
    final outcome = await runner.run(
      id,
      cancellation: cancellation,
      isUserCancelled: () => userCancelled,
    );
    final result = await store.get(id);
    await store.close();
    store = null;
    await repository.close();
    repository = null;
    await channel.invokeMethod<void>('complete', {
      'success': result?.state == DownloadState.completed,
      'cancelled': result?.state == DownloadState.cancelled,
      'error': result?.error,
      // JobScheduler applies its backoff before running the task again.
      'retry': outcome == TransferOutcome.retryLater,
    });
  } catch (error) {
    if (taskId != null &&
        attempt != null &&
        store != null &&
        !cancellation.cancelled &&
        !(error is PlatformException && error.code == 'TRANSFER_STOPPED')) {
      await store.failSetup(taskId, attempt, describeError(error));
    }
    await store?.close();
    store = null;
    await repository?.close();
    repository = null;
    await channel.invokeMethod<void>('complete', {
      'success': false,
      'error': describeError(error),
    });
  } finally {
    channel.setMethodCallHandler(null);
    await store?.close();
    await repository?.close();
  }
}

/// Consecutive attempts without new bytes before a run stops retrying locally.
const transferIdleAttempts = 3;

/// How long a temporarily unreachable peer is retried automatically. Bytes
/// arriving restart the window; afterwards the task fails for manual retry.
const transferOutageWindow = Duration(minutes: 30);

/// Leave room for filesystem metadata and the task/database updates.
const transferSpaceReserve = 16 * 1024 * 1024;

enum TransferOutcome {
  /// Completed, failed, cancelled, paused by the system or superseded.
  finished,

  /// The peer is temporarily unreachable; the task is queued for a later run.
  retryLater,
}

class TransferRunner {
  TransferRunner({
    required this.store,
    required this.repository,
    required this.bridge,
    required this.directory,
    this.progress,
    MediaRpcClient Function(Peer)? clientFactory,
    this.retryDelay = const Duration(seconds: 1),
    this.stallTimeout = defaultStallTimeout,
    this.outageWindow = transferOutageWindow,
    DateTime Function()? clock,
  }) : clientFactory = clientFactory ?? MediaRpcClient.new,
       _now = clock ?? DateTime.now;
  final TransferStore store;
  final TamayuraRepository repository;
  final PlatformBridge bridge;
  final Directory directory;
  final Future<void> Function(int, int, String)? progress;
  final MediaRpcClient Function(Peer) clientFactory;
  final Duration retryDelay, stallTimeout, outageWindow;
  final DateTime Function() _now;

  Future<TransferOutcome> run(
    String id, {
    DownloadCancellation? cancellation,
    bool Function()? isUserCancelled,
  }) async {
    final cancel = cancellation ?? DownloadCancellation();
    if (cancel.cancelled) return TransferOutcome.finished;
    final token = const Uuid().v4();
    final task = await store.claim(id, token);
    if (task == null) return TransferOutcome.finished;
    var received = task.received;
    var outageSince = task.outageSinceMs;
    Future<void> progressTail = Future.value();
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    void recordProgress(int bytes, int total, {required bool newBytes}) {
      final recovered = newBytes && outageSince != null;
      if (newBytes) outageSince = null;
      received = bytes;
      final now = _now();
      if (!recovered &&
          now.difference(lastProgress).inMilliseconds < 400 &&
          bytes != total) {
        return;
      }
      lastProgress = now;
      // Persist recovery with its bytes, even inside the progress throttle, so
      // a system stop cannot carry a previous outage into the next worker.
      final progressOutage = outageSince;
      progressTail = progressTail.then((_) async {
        if (await store.update(id, {
          'received': bytes,
          'outage_since_ms': progressOutage,
        }, runToken: token)) {
          try {
            await progress?.call(bytes, total, task.item.name);
          } catch (_) {
            /* SQLite remains authoritative. */
          }
        }
      });
    }

    try {
      cancel.check();
      var peer = task.peer;
      for (final candidate in await repository.listPeers()) {
        if (candidate.id == peer.id) {
          peer = candidate;
          break;
        }
      }
      var completed = await MediaDownloader.completedParts(
        item: task.item,
        directory: directory,
        taskId: id,
      );
      final cached =
          completed?.totalSize ??
          await MediaDownloader.stagedBytes(
            item: task.item,
            directory: directory,
            taskId: id,
          );
      recordProgress(cached, task.item.size, newBytes: false);
      await _checkSpace(task.directoryUri, task.item.size, cached);
      var idleFailures = 0;
      while (completed == null) {
        cancel.check();
        var madeProgress = false;
        try {
          final client = clientFactory(peer);
          void stopIdentity() => unawaited(client.close());
          cancel.addListener(stopIdentity);
          try {
            final identity = await client.identity();
            if (identity.id != task.item.deviceId) {
              throw FormatException(AppLocale.strings.errorAddressOwnedByOther);
            }
          } finally {
            cancel.removeListener(stopIdentity);
            await client.close();
          }
          cancel.check();
          int? previousBytes;
          completed =
              await MediaDownloader(
                clientFactory: clientFactory,
                stallTimeout: stallTimeout,
              ).downloadResumable(
                peer: peer,
                item: task.item,
                directory: directory,
                taskId: id,
                cancellation: cancel,
                onProgress: (bytes, total) {
                  // The first callback reports existing parts, not new data.
                  final newBytes =
                      previousBytes != null && bytes > previousBytes!;
                  previousBytes = bytes;
                  madeProgress = madeProgress || newBytes;
                  recordProgress(bytes, total, newBytes: newBytes);
                },
              );
          break;
        } catch (error) {
          if (cancel.cancelled || !isTransientTransferError(error)) rethrow;
          // Bytes prove the link works, so only consecutive empty attempts
          // count. Part offsets persist; a retry fetches only missing bytes.
          idleFailures = madeProgress ? 0 : idleFailures + 1;
          if (idleFailures >= transferIdleAttempts) rethrow;
          await cancel.sleep(
            retryDelay * (1 << (idleFailures == 0 ? 0 : idleFailures - 1)),
          );
        }
      }
      cancel.check();
      await progressTail;
      // Other downloads or applications may have used space since preflight.
      await _checkSpace(task.directoryUri, task.item.size, task.item.size);
      cancel.check();
      if (!await store.update(id, {
        'state': 'saving',
        'received': task.item.size,
      }, runToken: token)) {
        return TransferOutcome.finished;
      }
      final uri = await bridge.saveDownload(
        sourcePaths: completed.paths,
        expectedSize: completed.totalSize,
        directoryUri: task.directoryUri,
        name: safeMediaFilename(task.item.name),
        mimeType: task.item.mimeType,
        directories: task.destinationDirectories,
      );
      // Persist the actual export even if cancellation races with its final copy.
      await repository.saveDownload(
        DownloadRecord(
          deviceId: peer.id,
          mediaId: task.item.id,
          uri: uri,
          completedAt: DateTime.now(),
        ),
      );
      final committed = await store.update(id, {
        'state': 'completed',
        'saved_uri': uri,
        'error': null,
        'received': task.item.size,
        'outage_since_ms': null,
      }, runToken: token);
      if (committed) {
        try {
          await MediaDownloader.discard(directory, id);
        } catch (_) {
          /* Safe to clean later. */
        }
      }
      return TransferOutcome.finished;
    } catch (error) {
      try {
        await progressTail;
      } catch (_) {
        /* Preserve transfer error. */
      }
      if (cancel.cancelled || error is DownloadCancelled) {
        await store.update(id, {
          'state': isUserCancelled?.call() == true ? 'cancelled' : 'queued',
          'received': received,
          'error': null,
          'outage_since_ms': outageSince,
        }, runToken: token);
        return TransferOutcome.finished;
      }
      if (isTransientTransferError(error)) {
        final now = _now().millisecondsSinceEpoch;
        // New network bytes clear the old outage; existing parts do not.
        final since = outageSince ?? now;
        if (now - since < outageWindow.inMilliseconds) {
          final waiting = await store.update(id, {
            'state': 'queued',
            'received': received,
            'error': AppLocale.strings.transferRetryLater(describeError(error)),
            'outage_since_ms': since,
          }, runToken: token);
          return waiting
              ? TransferOutcome.retryLater
              : TransferOutcome.finished;
        }
      }
      await store.update(id, {
        'state': 'failed',
        'received': received,
        'error': describeError(error),
        'outage_since_ms': null,
      }, runToken: token);
      return TransferOutcome.finished;
    }
  }

  Future<void> _checkSpace(String directoryUri, int size, int cached) async {
    final space = await bridge.transferSpace(directoryUri: directoryUri);
    final remaining = size - cached;
    void requireSpace(int? available, int needed, String location) {
      if (available != null && available < needed + transferSpaceReserve) {
        throw PlatformException(
          code: 'NO_SPACE',
          message: AppLocale.strings.errorSpaceInsufficient(location),
        );
      }
    }

    if (space.sameVolume == true) {
      final available = [
        space.stagingAvailableBytes,
        space.destinationAvailableBytes,
      ].whereType<int>().toList();
      requireSpace(
        available.isEmpty ? null : available.reduce((a, b) => a < b ? a : b),
        remaining + size,
        AppLocale.strings.spaceLocationDownloadDisk,
      );
    } else {
      // Providers may not expose a destination volume or its free capacity.
      // Known limits remain useful; actual write errors are still authoritative.
      requireSpace(
        space.stagingAvailableBytes,
        remaining,
        AppLocale.strings.spaceLocationStaging,
      );
      requireSpace(
        space.destinationAvailableBytes,
        size,
        AppLocale.strings.spaceLocationDestination,
      );
    }
  }
}
