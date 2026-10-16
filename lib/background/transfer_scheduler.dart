import 'dart:async';
import 'dart:io';

import '../app/errors.dart';
import '../core/models.dart';
import '../data/repository.dart';
import '../data/transfer_store.dart';
import '../network/downloader.dart';
import '../network/media_rpc.dart';
import '../platform/platform_bridge.dart';
import 'transfer_worker.dart';

abstract interface class TransferScheduler {
  Future<void> scheduleTransfer(String taskId);
  Future<void> cancelTransfer(String taskId);
  Future<List<String>> scheduledTransferIds();
  Future<void> shutdown();
}

/// Android's jobs survive activity teardown and must not be stopped with the UI.
class NativeTransferScheduler implements TransferScheduler {
  const NativeTransferScheduler(this.bridge);
  final PlatformBridge bridge;

  @override
  Future<void> scheduleTransfer(String taskId) =>
      bridge.scheduleTransfer(taskId);
  @override
  Future<void> cancelTransfer(String taskId) => bridge.cancelTransfer(taskId);
  @override
  Future<List<String>> scheduledTransferIds() => bridge.scheduledTransferIds();
  @override
  Future<void> shutdown() async {}
}

/// Desktop downloads continue while the window is hidden or unfocused. The
/// process owns them: startup reconciles interrupted records for manual retry.
class InProcessTransferScheduler implements TransferScheduler {
  InProcessTransferScheduler({
    required this.store,
    required this.repository,
    required this.bridge,
    this.clientFactory,
    this.onChanged,
    this.retryDelay = const Duration(seconds: 1),
  });

  final TransferStore store;
  final TamayuraRepository repository;
  final PlatformBridge bridge;
  final MediaRpcClient Function(Peer)? clientFactory;
  final Future<void> Function()? onChanged;
  final Duration retryDelay;
  final Map<String, _Execution> _runs = {};
  final Map<String, Future<void>> _commands = {};
  bool _closed = false;
  Future<void>? _shutdown;

  // A retry must wait for the previous worker to release its part files, even
  // when cancellation and the next schedule arrive in the same event loop.
  Future<void> _command(String id, Future<void> Function() command) {
    final next = (_commands[id] ?? Future<void>.value()).then((_) => command());
    final tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _commands[id] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_commands[id], tail)) _commands.remove(id);
      }),
    );
    return next;
  }

  @override
  Future<void> scheduleTransfer(String taskId) => _command(taskId, () async {
    if (_closed) throw StateError('应用正在退出，请重新打开后重试下载');
    if (_runs.containsKey(taskId)) return;
    final execution = _Execution();
    _runs[taskId] = execution;
    execution.done = _run(taskId, execution);
  });

  Future<void> _run(String id, _Execution execution) async {
    int? attempt;
    var activityRequested = false;
    try {
      attempt = (await store.get(id))?.attempt;
      execution.cancellation.check();
      activityRequested = true;
      await bridge.setTransferActivity(id, active: true);
      execution.cancellation.check();
      final directory = Directory(await bridge.transferDirectory());
      execution.cancellation.check();
      await TransferRunner(
        store: store,
        repository: repository,
        bridge: bridge,
        directory: directory,
        clientFactory: clientFactory,
        retryDelay: retryDelay,
        progress: (_, _, _) => _changed(),
      ).run(
        id,
        cancellation: execution.cancellation,
        isUserCancelled: () => execution.userCancelled,
      );
    } catch (error) {
      if (attempt != null && !execution.cancellation.cancelled) {
        try {
          await store.failSetup(id, attempt, describeError(error));
        } catch (_) {
          // If storage is unavailable, the next reconciliation keeps this task
          // retryable. An unawaited worker must not crash the UI isolate.
        }
      }
    } finally {
      if (activityRequested) {
        try {
          // Release is idempotent, including when acquisition's reply failed.
          await bridge.setTransferActivity(id, active: false);
        } catch (_) {
          // Cleanup must not turn an unawaited worker into an isolate error.
          // Native termination also releases any remaining activities.
        }
      }
      if (identical(_runs[id], execution)) _runs.remove(id);
      await _changed();
    }
  }

  Future<void> _changed() async {
    try {
      await onChanged?.call();
    } catch (_) {
      // UI polling is advisory; persisted progress is authoritative.
    }
  }

  @override
  Future<void> cancelTransfer(String taskId) => _command(taskId, () async {
    final execution = _runs[taskId];
    if (execution == null) return;
    execution.userCancelled = true;
    execution.cancellation.cancel();
    await execution.done;
  });

  @override
  Future<List<String>> scheduledTransferIds() async => _runs.keys.toList();

  @override
  Future<void> shutdown() => _shutdown ??= _stopAll();

  Future<void> _stopAll() async {
    _closed = true;
    for (final execution in _runs.values.toList()) {
      execution.cancellation.cancel();
    }
    await Future.wait(_commands.values.toList());
    await Future.wait(_runs.values.map((run) => run.done).toList());
  }
}

class _Execution {
  final cancellation = DownloadCancellation();
  bool userCancelled = false;
  late final Future<void> done;
}
