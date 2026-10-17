import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/app_lifecycle.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/platform/platform_bridge.dart';

import 'background_sharing_test.dart' show SharingBridge;
import 'controller_test.dart' show FakeBridge, MemorySource;

class _DesktopBridge extends SharingBridge {
  _DesktopBridge(this.directory);

  final Directory directory;
  int discoverySubscriptions = 0, sharingSubscriptions = 0;
  final activeTransfers = <String>{};
  final transferActivities = <bool>[];

  @override
  bool get usesInProcessTransfers => true;

  @override
  Stream<Map<String, dynamic>> get discoveryEvents {
    discoverySubscriptions++;
    return super.discoveryEvents;
  }

  @override
  Stream<SharingStatus> get sharingEvents {
    sharingSubscriptions++;
    return super.sharingEvents;
  }

  @override
  Future<Map<String, dynamic>> localInfo() async => {
    'name': 'Desktop',
    'addresses': ['127.0.0.1'],
  };

  @override
  Future<String> transferDirectory() async => p.join(directory.path, 'staging');

  @override
  Future<TransferSpaceInfo> transferSpace({
    required String directoryUri,
  }) async => const TransferSpaceInfo();

  @override
  Future<void> setTransferActivity(
    String taskId, {
    required bool active,
  }) async {
    transferActivities.add(active);
    if (active) {
      activeTransfers.add(taskId);
    } else {
      activeTransfers.remove(taskId);
    }
  }
}

class _HeldDownloadSource extends MemorySource {
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.readRange(id, offset, length);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  for (final platform in ['macOS', 'Windows']) {
    group('$platform tray lifecycle', () {
      late Directory directory;
      late _DesktopBridge bridge;
      late TamayuraRepository repository;
      late TransferStore transfers;
      late AppController model;
      late AppLifecycleCoordinator lifecycle;
      late int resumeRefreshes;

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('tamayura-tray-');
        bridge = _DesktopBridge(directory);
        repository = await TamayuraRepository.open(
          path: p.join(directory.path, 'catalog.db'),
          factory: databaseFactoryFfi,
        );
        transfers = await TransferStore.open(
          path: p.join(directory.path, 'transfers.db'),
          factory: databaseFactoryFfi,
        );
        await repository.setSetting(
          'sharedFolders',
          jsonEncode([
            const SharedFolder(
              id: 'photos',
              uri: 'file:///shared-photos',
              name: 'Photos',
            ).toJson(),
          ]),
        );
        final now = DateTime.utc(2026, 1, 1);
        model = AppController(
          bridge: bridge,
          preferredPort: 0,
          openRepository: () async => repository,
          openTransfers: () async => transfers,
          clock: () => now,
        );
        resumeRefreshes = 0;
        lifecycle = AppLifecycleCoordinator(
          isMacOS: platform == 'macOS',
          isWindows: platform == 'Windows',
          setForeground: model.setForeground,
          onResume: () async {
            resumeRefreshes++;
            await model.refreshAfterResume();
          },
        );
        await lifecycle.initialize(AppLifecycleState.resumed);
      });

      tearDown(() async {
        await model.shutdown();
        await bridge.changes.close();
        await bridge.events.close();
        await directory.delete(recursive: true);
      });

      test(
        'repeated close and restore retains sharing and one discovery listener',
        () async {
          await model.initialize();
          await model.setBackgroundSharing(true);
          final servingPort = model.port;
          final client = MediaRpcClient(
            Peer(
              id: FakeBridge.identity,
              name: 'Desktop',
              host: '127.0.0.1',
              port: servingPort,
            ),
          );
          try {
            for (var cycle = 0; cycle < 3; cycle++) {
              await lifecycle.handleState(AppLifecycleState.inactive);
              await lifecycle.handleState(AppLifecycleState.hidden);
              await lifecycle.handleState(AppLifecycleState.hidden);
              expect(model.port, servingPort);
              expect(model.backgroundSharingRunning, isTrue);
              expect(bridge.events.hasListener, isTrue);
              expect((await client.identity()).id, FakeBridge.identity);
              final media = await client.listMedia();
              expect(media.single.id, 'local-photos');
              expect(
                await client
                    .readRange(media.single.id, 0, 3)
                    .expand((bytes) => bytes)
                    .toList(),
                [1, 2, 3],
              );

              await lifecycle.handleState(AppLifecycleState.inactive);
              await lifecycle.handleState(AppLifecycleState.inactive);
              expect(resumeRefreshes, cycle);
              await lifecycle.handleState(AppLifecycleState.resumed);
              expect(resumeRefreshes, cycle + 1);
              expect(model.port, servingPort);
            }
            expect(bridge.stops, 0);
            expect(bridge.discoverySubscriptions, 1);
            expect(bridge.sharingSubscriptions, 1);
            expect(bridge.scans, hasLength(1));
            expect(model.error, isNull);
          } finally {
            await client.close();
          }
        },
      );

      test(
        'closing with sharing disabled completes an existing download while hidden',
        () async {
          final source = _HeldDownloadSource();
          final server = MediaRpcServer(
            identity: const Peer(
              id: 'remote',
              name: 'Remote',
              host: '127.0.0.1',
              port: 0,
            ),
            source: source,
          );
          await server.start();
          try {
            await repository.upsertPeer(
              Peer(
                id: 'remote',
                name: 'Remote',
                host: '127.0.0.1',
                port: server.port,
              ),
            );
            await repository.setSetting(
              'downloadUri',
              directory.uri.toString(),
            );
            await model.initialize();
            final item = model.media.single;
            await model.download(item);
            await source.entered.future.timeout(const Duration(seconds: 5));
            expect(bridge.activeTransfers, hasLength(1));

            await lifecycle.handleState(AppLifecycleState.inactive);
            await lifecycle.handleState(AppLifecycleState.hidden);
            expect(model.backgroundSharingEnabled, isFalse);
            expect(model.port, 0);
            expect(bridge.events.hasListener, isFalse);
            expect(bridge.activeTransfers, hasLength(1));
            expect(bridge.transferActivities, [true]);

            final completed = Completer<void>();
            void checkCompleted() {
              if (model.transfers[item.key]?.status ==
                      TransferStatus.completed &&
                  bridge.activeTransfers.isEmpty &&
                  !completed.isCompleted) {
                completed.complete();
              }
            }

            model.addListener(checkCompleted);
            try {
              source.release.complete();
              await completed.future.timeout(const Duration(seconds: 5));
            } finally {
              model.removeListener(checkCompleted);
            }
            expect(bridge.savedBytes, [1, 2, 3]);
            expect(bridge.transferActivities, [true, false]);
            expect(model.port, 0);
            expect(resumeRefreshes, 0);

            await lifecycle.handleState(AppLifecycleState.inactive);
            await lifecycle.handleState(AppLifecycleState.resumed);
            expect(model.port, greaterThan(0));
            expect(bridge.events.hasListener, isTrue);
            expect(model.transfers[item.key]?.status, TransferStatus.completed);
            expect(resumeRefreshes, 1);
            expect(bridge.sharingSubscriptions, 1);
            expect(model.error, isNull);
          } finally {
            if (!source.release.isCompleted) source.release.complete();
            await model.shutdown();
            await server.stop();
          }
        },
      );
    });
  }
}
