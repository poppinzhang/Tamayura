import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as p;
import 'package:tamayura/core/models.dart';
import 'package:tamayura/network/downloader.dart';
import 'package:tamayura/network/media_rpc.dart';

const peer = Peer(id: 'peer', name: 'B', host: '127.0.0.1', port: 50728);
MediaItem media(int size, {int modified = 1}) => MediaItem(
  id: 'media',
  deviceId: 'peer',
  name: 'photo.jpg',
  mimeType: 'image/jpeg',
  size: size,
  modifiedMs: modified,
  thumbnail: Uint8List(0),
);

class Client implements MediaTransferClient {
  Client(this.read, {this.onClose});
  final Stream<Uint8List> Function(int, int) read;
  final void Function()? onClose;
  @override
  Stream<Uint8List> readRange(String id, int offset, int length) =>
      read(offset, length);
  @override
  Future<void> close() async {
    onClose?.call();
  }
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tamayura-resume-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'offline export requires the matching manifest and every complete part',
    () async {
      final staging = await Directory(p.join(directory.path, 'task')).create();
      final manifest = File(p.join(staging.path, 'manifest.json'));
      final part = File(p.join(staging.path, '0.part'));
      Future<DownloadParts?> completed({int modified = 1}) =>
          MediaDownloader.completedParts(
            item: media(4, modified: modified),
            directory: directory,
            taskId: 'task',
          );
      Future<int> staged() => MediaDownloader.stagedBytes(
        item: media(4),
        directory: directory,
        taskId: 'task',
      );
      await part.writeAsBytes([1, 2, 3, 4]);
      expect(await completed(), isNull);
      expect(await staged(), 0);
      await manifest.writeAsString('["peer","media",4,1]');
      final ready = (await completed())!;
      expect(ready.paths, [part.path]);
      expect(await ready.openRead().expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
        4,
      ]);
      expect(await staged(), 4);
      expect(await completed(modified: 2), isNull);
      await part.writeAsBytes([1, 2]);
      expect(await completed(), isNull);
      expect(await staged(), 2);
      await part.writeAsBytes([1, 2, 3, 4, 5]);
      expect(await completed(), isNull);
      expect(await staged(), 0);
      await part.delete();
      expect(await completed(), isNull);
    },
  );

  test(
    'zero-byte complete parts can be exported without a network client',
    () async {
      final parts =
          await MediaDownloader(
            clientFactory: (_) => throw StateError('Empty files need no range'),
          ).downloadResumable(
            peer: peer,
            item: media(0),
            directory: directory,
            taskId: 'empty',
          );
      expect(parts.totalSize, 0);
      expect(await parts.files.single.length(), 0);
      expect(
        await MediaDownloader.completedParts(
          item: media(0),
          directory: directory,
          taskId: 'empty',
        ),
        isNotNull,
      );
    },
  );

  test(
    'four durable ranges resume in a new downloader without refetching completed bytes',
    () async {
      final size = parallelDownloadThreshold + 3;
      final ranges = downloadRanges(size);
      // Seed a realistic interrupted set: one complete, one empty and two partial.
      final staging = Directory('${directory.path}/task');
      await staging.create();
      await File(
        '${staging.path}/manifest.json',
      ).writeAsString('["peer","media",$size,1]');
      final cached = [ranges[0].length, 0, 512 * 1024, 123];
      for (var i = 0; i < cached.length; i++) {
        await File(
          '${staging.path}/$i.part',
        ).writeAsBytes(Uint8List(cached[i]));
      }
      final calls = <DownloadRange>[];
      final progress = <int>[];
      final downloader = MediaDownloader(
        clientFactory: (_) => Client((offset, length) async* {
          calls.add(DownloadRange(offset, length));
          while (length > 0) {
            final n = length.clamp(0, 256 * 1024);
            yield Uint8List(n);
            length -= n;
          }
        }),
      );
      final file = await downloader.downloadResumable(
        peer: peer,
        item: media(size),
        directory: directory,
        taskId: 'task',
        onProgress: (r, t) => progress.add(r),
      );
      expect(file.totalSize, size);
      expect(file.files.length, 4);
      expect(
        await file.openRead().fold<int>(0, (sum, bytes) => sum + bytes.length),
        size,
      );
      expect(await File('${staging.path}/complete.partial').exists(), isFalse);
      // Concurrent file opens may start the range requests in any order.
      calls.sort((a, b) => a.offset.compareTo(b.offset));
      expect(calls.map((r) => r.offset), [
        ranges[1].offset,
        ranges[2].offset + cached[2],
        ranges[3].offset + cached[3],
      ]);
      expect(calls.map((r) => r.length), [
        ranges[1].length,
        ranges[2].length - cached[2],
        ranges[3].length - cached[3],
      ]);
      expect(progress.first, cached.reduce((a, b) => a + b));
      expect(progress.last, size);
    },
  );
  test(
    'changed metadata discards old parts and unsafe task ids cannot escape staging',
    () async {
      final calls = <int>[];
      final downloader = MediaDownloader(
        clientFactory: (_) => Client((offset, length) async* {
          calls.add(offset);
          yield Uint8List(length);
        }),
      );
      await downloader.downloadResumable(
        peer: peer,
        item: media(3),
        directory: directory,
        taskId: 'task',
      );
      await downloader.downloadResumable(
        peer: peer,
        item: media(4, modified: 2),
        directory: directory,
        taskId: 'task',
      );
      expect(calls, [0, 0]);
      await expectLater(
        downloader.downloadResumable(
          peer: peer,
          item: media(3),
          directory: directory,
          taskId: '../escape',
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'cancel closes a stalled network stream and preserves durable partial bytes',
    () async {
      final cancellation = DownloadCancellation();
      final stream = StreamController<Uint8List>();
      var closed = false;
      final downloader = MediaDownloader(
        clientFactory: (_) => Client(
          (o, l) => stream.stream,
          onClose: () {
            closed = true;
            unawaited(stream.close());
          },
        ),
      );
      final entered = Completer<void>();
      final downloading = downloader.downloadResumable(
        peer: peer,
        item: media(10),
        directory: directory,
        taskId: 'task',
        cancellation: cancellation,
        onProgress: (r, t) {
          if (r == 3 && !entered.isCompleted) entered.complete();
        },
      );
      final expectation = expectLater(
        downloading,
        throwsA(isA<DownloadCancelled>()),
      );
      stream.add(Uint8List.fromList([1, 2, 3]));
      await entered.future;
      cancellation.cancel();
      await expectation.timeout(const Duration(seconds: 2));
      expect(closed, true);
      expect(await File('${directory.path}/task/0.part').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'a silent range is closed by the stall watchdog and keeps its bytes',
    () async {
      final stream = StreamController<Uint8List>();
      var closed = 0;
      final downloader = MediaDownloader(
        stallTimeout: const Duration(milliseconds: 50),
        clientFactory: (_) => Client(
          (o, l) => stream.stream,
          onClose: () {
            closed++;
            unawaited(stream.close());
          },
        ),
      );
      stream.add(Uint8List.fromList([1, 2, 3]));
      await expectLater(
        downloader
            .downloadResumable(
              peer: peer,
              item: media(10),
              directory: directory,
              taskId: 'task',
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<TransferStalled>()),
      );
      expect(closed, greaterThanOrEqualTo(1));
      expect(await File('${directory.path}/task/0.part').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );
  test('a slow but steady range is not mistaken for a stall', () async {
    final downloader = MediaDownloader(
      stallTimeout: const Duration(milliseconds: 100),
      clientFactory: (_) => Client((offset, length) async* {
        for (var i = 0; i < length; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          yield Uint8List(1);
        }
      }),
    );
    // The whole range takes longer than the watchdog; only silence counts.
    final file = await downloader.downloadResumable(
      peer: peer,
      item: media(6),
      directory: directory,
      taskId: 'task',
    );
    expect(file.totalSize, 6);
    expect(await file.files.single.length(), 6);
  });
  test('only peer and LAN outages are transient', () {
    for (final error in <Object>[
      const TransferStalled(),
      const SocketException('Connection refused'),
      const GrpcError.unavailable('Error connecting'),
      const GrpcError.deadlineExceeded('identity'),
      const GrpcError.cancelled('transport closed'),
      const GrpcError.unknown('HTTP/2 error: Connection error'),
    ]) {
      expect(isTransientTransferError(error), isTrue, reason: '$error');
    }
    for (final error in <Object>[
      const GrpcError.notFound('Media is not shared'),
      const GrpcError.dataLoss('size changed'),
      const GrpcError.failedPrecondition('folder revoked'),
      const GrpcError.outOfRange('range'),
      const FormatException('bad chunk'),
      StateError('bug'),
    ]) {
      expect(isTransientTransferError(error), isFalse, reason: '$error');
    }
  });
  test('cancellation ends a retry wait immediately', () async {
    final cancellation = DownloadCancellation();
    final waiting = cancellation.sleep(const Duration(hours: 1));
    cancellation.cancel();
    await expectLater(
      waiting.timeout(const Duration(seconds: 1)),
      throwsA(isA<DownloadCancelled>()),
    );
    await DownloadCancellation().sleep(Duration.zero);
  });
}
