import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/background/transfer_scheduler.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge;

class _FailingScheduler implements TransferScheduler {
  @override
  Future<void> scheduleTransfer(String id) async {}
  @override
  Future<void> cancelTransfer(String id) async {}
  @override
  Future<List<String>> scheduledTransferIds() async => [];
  @override
  Future<void> shutdown() async => throw StateError('shutdown failure');
}

class _FailingDiscoveryCancellation extends FakeBridge {
  final failingEvents = StreamController<Map<String, dynamic>>(
    onCancel: () async => throw StateError('discovery cancel failed'),
  );
  @override
  Stream<Map<String, dynamic>> get discoveryEvents => failingEvents.stream;
}

class _Node implements TailscaleNode {
  final started = Completer<void>();
  int disposals = 0;
  static const signedOut = NodeStatus(
    sessionEpoch: 'session',
    state: NodeState.signedOut,
  );
  @override
  Future<NodeStatus> start() async {
    started.complete();
    return signedOut;
  }

  @override
  Future<NodeStatus> status() async => signedOut;
  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'discovery cancellation failure cannot leave the media listener running',
    () async {
      final repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final transfers = await TransferStore.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final bridge = _FailingDiscoveryCancellation();
      final model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => repository,
        openTransfers: () async => transfers,
      );
      await model.initialize();
      expect(model.port, greaterThan(0));
      await model.shutdown();
      expect(model.port, 0);
      await bridge.failingEvents.close();
      await bridge.events.close();
    },
  );
  test(
    'scheduler shutdown failure still releases the Tailscale owner and stores',
    () async {
      final repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final transfers = await TransferStore.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await repository.setSetting('tailscale_enabled_v1', 'true');
      final node = _Node();
      final bridge = FakeBridge();
      final model = AppController(
        bridge: bridge,
        preferredPort: 0,
        transferScheduler: _FailingScheduler(),
        openRepository: () async => repository,
        openTransfers: () async => transfers,
        openTailscaleNode: () async => node,
      );
      addTearDown(() async {
        await model.shutdown();
        await bridge.events.close();
      });
      await model.initialize();
      await node.started.future;
      await model.shutdown();
      expect(node.disposals, 1);
      await model.shutdown();
      expect(node.disposals, 1);
      await expectLater(
        repository.listPeers(),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(transfers.recent(), throwsA(isA<DatabaseException>()));
    },
  );
}
