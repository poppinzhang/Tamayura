import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:grpc/grpc.dart';
import 'package:uuid/uuid.dart';
import '../app/errors.dart';
import '../core/models.dart';
import '../core/transfer_task.dart';
import '../data/repository.dart';
import '../data/transfer_store.dart';
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
    final id = args?['taskId'] as String?;
    if (id == null) throw StateError('下载任务缺少 ID');
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
    await runner.run(
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

class TransferRunner {
  TransferRunner({
    required this.store,
    required this.repository,
    required this.bridge,
    required this.directory,
    this.progress,
    MediaRpcClient Function(Peer)? clientFactory,
    this.retryDelay = const Duration(seconds: 1),
  }) : clientFactory = clientFactory ?? MediaRpcClient.new;
  final TransferStore store;
  final TamayuraRepository repository;
  final PlatformBridge bridge;
  final Directory directory;
  final Future<void> Function(int, int, String)? progress;
  final MediaRpcClient Function(Peer) clientFactory;
  final Duration retryDelay;

  Future<void> run(
    String id, {
    DownloadCancellation? cancellation,
    bool Function()? isUserCancelled,
  }) async {
    final cancel = cancellation ?? DownloadCancellation();
    if (cancel.cancelled) return;
    final token = const Uuid().v4();
    final task = await store.claim(id, token);
    if (task == null) return;
    var received = task.received;
    Future<void> progressTail = Future.value();
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    void recordProgress(int bytes, int total) {
      received = bytes;
      final now = DateTime.now();
      if (now.difference(lastProgress).inMilliseconds < 400 && bytes != total) {
        return;
      }
      lastProgress = now;
      progressTail = progressTail.then((_) async {
        if (await store.update(id, {'received': bytes}, runToken: token)) {
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
      File? completed;
      for (var attempt = 0; attempt < 3; attempt++) {
        cancel.check();
        try {
          final client = clientFactory(peer);
          void stopIdentity() => unawaited(client.close());
          cancel.addListener(stopIdentity);
          try {
            final identity = await client.identity();
            if (identity.id != task.item.deviceId) {
              throw const FormatException('该地址已属于另一台设备，请重新发现后重试');
            }
          } finally {
            cancel.removeListener(stopIdentity);
            await client.close();
          }
          cancel.check();
          completed = await MediaDownloader(clientFactory: clientFactory)
              .downloadResumable(
                peer: peer,
                item: task.item,
                directory: directory,
                taskId: id,
                cancellation: cancel,
                onProgress: recordProgress,
              );
          break;
        } catch (error) {
          if (cancel.cancelled || attempt == 2 || !_retryable(error)) rethrow;
          // Keep individual part offsets; a retry transfers only missing bytes.
          await Future<void>.delayed(retryDelay * (attempt + 1));
        }
      }
      cancel.check();
      await progressTail;
      if (!await store.update(id, {
        'state': 'saving',
        'received': task.item.size,
      }, runToken: token)) {
        return;
      }
      final uri = await bridge.saveDownload(
        sourcePath: completed!.path,
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
      }, runToken: token);
      if (committed) {
        try {
          await MediaDownloader.discard(directory, id);
        } catch (_) {
          /* Safe to clean later. */
        }
      }
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
        }, runToken: token);
      } else {
        await store.update(id, {
          'state': 'failed',
          'received': received,
          'error': describeError(error),
        }, runToken: token);
      }
    }
  }

  static bool _retryable(Object error) =>
      error is SocketException ||
      error is GrpcError &&
          [
            StatusCode.unavailable,
            StatusCode.deadlineExceeded,
            StatusCode.cancelled,
          ].contains(error.code);
}
