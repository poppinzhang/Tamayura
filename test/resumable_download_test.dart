import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
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
      expect(await file.length(), size);
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
}
