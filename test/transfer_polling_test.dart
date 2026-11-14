import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge;

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Transfer poll did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'idle transfer polls preserve views but publish every visible change',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'transfer-polling-',
      );
      final repository = await TamayuraRepository.open(
        path: '${directory.path}/media.db',
        factory: databaseFactoryFfi,
      );
      final tasks = await TransferStore.open(
        path: '${directory.path}/transfers.db',
        factory: databaseFactoryFfi,
      );
      final bridge = FakeBridge();
      var polls = 0;
      bridge.queryScheduled = () async {
        polls++;
        return bridge.scheduled.toList();
      };
      final model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => repository,
        openTransfers: () async => tasks,
      );
      addTearDown(() async {
        await model.shutdown();
        await bridge.events.close();
        await directory.delete(recursive: true);
      });
      await model.initialize();
      await _until(() => polls >= 2);
      var notifications = 0;
      model.addListener(() => notifications++);

      // Seeing two more polls proves that at least one previous pass finished:
      // concurrent timer callbacks are coalesced while a database read is pending.
      var beforePolls = polls;
      await _until(() => polls >= beforePolls + 2);
      expect(model.transfers, isEmpty);
      expect(notifications, 0);

      const peer = Peer(
        id: 'remote',
        name: 'Source',
        host: '127.0.0.1',
        port: 1,
      );
      final item = MediaItem(
        id: 'photo',
        deviceId: peer.id,
        name: 'photo.jpg',
        mimeType: 'image/jpeg',
        size: 100,
        modifiedMs: 1,
        sharedFolderId: 'photos',
        sharedFolderName: 'Photos',
        relativePath: 'photo.jpg',
        thumbnail: Uint8List.fromList([1, 2, 3]),
      );
      final task = await tasks.enqueue(peer, item, directory.path);
      await tasks.update(task.id, {
        'state': 'failed',
        'received': 20,
        'error': 'offline',
      });
      await _until(() => model.transfers[item.key]?.error == 'offline');
      expect(model.transfers[item.key]!.status, TransferStatus.failed);
      expect(model.transfers[item.key]!.receivedBytes, 20);
      final unchanged = model.transfers[item.key];
      notifications = 0;
      beforePolls = polls;
      await _until(() => polls >= beforePolls + 2);
      expect(notifications, 0);
      expect(identical(model.transfers[item.key], unchanged), isTrue);

      await tasks.update(task.id, {
        'state': 'completed',
        'received': 100,
        'error': null,
        'saved_uri': '${directory.path}/photo.jpg',
        'attempt': 2,
      });
      await _until(() => model.transfers[item.key]?.complete == true);
      expect(notifications, 1);
      expect(model.transfers[item.key]!.status, TransferStatus.completed);
      expect(model.transfers[item.key]!.progress, 1);
      expect(model.transfers[item.key]!.attempt, 2);
      expect(model.transfers[item.key]!.error, isNull);

      notifications = 0;
      await tasks.update(task.id, {
        'name': 'renamed.jpg',
        'relative_path': 'renamed.jpg',
        'thumbnail': Uint8List.fromList([3, 2, 1]),
      });
      await _until(
        () => model.transfers[item.key]?.item?.name == 'renamed.jpg',
      );
      expect(notifications, 1);
      expect(model.transfers[item.key]!.item!.thumbnail, [3, 2, 1]);

      notifications = 0;
      await tasks.removeCompleted(peer.id, item.id);
      await _until(() => !model.transfers.containsKey(item.key));
      expect(notifications, 1);
      expect(model.error, isNull);
    },
  );
}
