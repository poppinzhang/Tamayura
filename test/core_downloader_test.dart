import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/network/downloader.dart';
import 'package:tamayura/network/media_rpc.dart';

const peer = Peer(id: 'remote', name: 'Phone', host: '127.0.0.1', port: 1234);
MediaItem item(int size, {String name = 'photo.jpg'}) => MediaItem(
  id: 'file',
  deviceId: peer.id,
  name: name,
  mimeType: 'image/jpeg',
  size: size,
  modifiedMs: 0,
  thumbnail: Uint8List(0),
);

class FakeClient implements MediaTransferClient {
  FakeClient(this.response);
  final Stream<Uint8List> Function(int offset, int length) response;
  bool closed = false;
  @override
  Stream<Uint8List> readRange(String id, int offset, int length) =>
      response(offset, length);
  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'tamayura-download-test-',
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('only files strictly larger than 50 MiB use four exact ranges', () {
    expect(downloadRanges(0).single.length, 0);
    expect(downloadRanges(parallelDownloadThreshold).length, 1);
    final ranges = downloadRanges(parallelDownloadThreshold + 3);
    expect(ranges.length, 4);
    expect(ranges.first.offset, 0);
    for (var index = 1; index < ranges.length; index++) {
      expect(
        ranges[index].offset,
        ranges[index - 1].offset + ranges[index - 1].length,
      );
    }
    expect(
      ranges.last.offset + ranges.last.length,
      parallelDownloadThreshold + 3,
    );
    expect(() => downloadRanges(-1), throwsArgumentError);
  });

  test(
    'remote filenames cannot traverse a directory or introduce separators',
    () {
      expect(safeMediaFilename('../../Camera/test.jpg'), 'test.jpg');
      expect(safeMediaFilename(r'C:\photos\test.jpg'), 'test.jpg');
      expect(safeMediaFilename('..'), 'media');
      expect(safeMediaFilename('bad\u0000name.jpg'), 'bad_name.jpg');
      expect(safeMediaFilename('CON.jpg'), '_CON.jpg');
      expect(safeMediaFilename('nul.png'), '_nul.png');
      expect(safeMediaFilename('LPT1.mp4'), '_LPT1.mp4');
      expect(safeMediaFilename('COM¹.heic'), '_COM¹.heic');
      expect(safeMediaFilename(r'CONIN$'), r'_CONIN$');
      expect(safeMediaFilename(r'conout$.jpg'), r'_conout$.jpg');
      expect(safeMediaFilename('NUL .jpg'), '_NUL .jpg');
      expect(safeMediaFilename('photo.jpg. '), 'photo.jpg');
      expect(safeMediaFilename('...'), 'media');
      expect(safeMediaFilename('CONCERT.jpg'), 'CONCERT.jpg');
      final longName = safeMediaFilename('${'照' * 100}.jpg');
      expect(utf8.encode(longName).length, lessThanOrEqualTo(180));
      expect(longName, endsWith('.jpg'));
    },
  );

  test(
    'successful download writes exact bytes and cleans up staging files',
    () async {
      final bytes = Uint8List.fromList(List.generate(300, (i) => i % 256));
      final clients = <FakeClient>[];
      final progress = <int>[];
      final downloader = MediaDownloader(
        clientFactory: (_) {
          final client = FakeClient(
            (offset, length) => Stream.value(
              Uint8List.sublistView(bytes, offset, offset + length),
            ),
          );
          clients.add(client);
          return client;
        },
      );
      final result = await downloader.download(
        peer: peer,
        item: item(bytes.length, name: '../../escape.jpg'),
        directory: directory,
        onProgress: (received, total) {
          progress.add(received);
        },
      );
      expect(await result.readAsBytes(), bytes);
      expect(result.parent.path, directory.path);
      expect(progress, [0, bytes.length]);
      expect(clients.every((client) => client.closed), isTrue);
      expect(await directory.list().length, 1);
    },
  );

  test('zero-byte media produces a valid empty file', () async {
    final downloader = MediaDownloader(
      clientFactory: (_) =>
          FakeClient((offset, length) => const Stream.empty()),
    );
    final result = await downloader.download(
      peer: peer,
      item: item(0),
      directory: directory,
    );
    expect(await result.length(), 0);
  });

  for (final mode in ['short', 'long', 'error']) {
    test(
      '$mode transfer removes all temporary files and closes clients',
      () async {
        late FakeClient client;
        final downloader = MediaDownloader(
          clientFactory: (_) {
            client = FakeClient((offset, length) async* {
              yield Uint8List(mode == 'long' ? length + 1 : length - 1);
              if (mode == 'error') throw const SocketException('Disconnected');
            });
            return client;
          },
        );
        await expectLater(
          downloader.download(peer: peer, item: item(10), directory: directory),
          throwsA(isA<Exception>()),
        );
        expect(await directory.list().length, 0);
        expect(client.closed, isTrue);
      },
    );
  }

  test(
    'large media requests four ranges concurrently and joins in byte order',
    () async {
      var active = 0;
      var peakActive = 0;
      final requested = <DownloadRange>[];
      final downloader = MediaDownloader(
        clientFactory: (_) => FakeClient((offset, length) async* {
          active++;
          if (active > peakActive) peakActive = active;
          requested.add(DownloadRange(offset, length));
          await Future<void>.delayed(const Duration(milliseconds: 5));
          var remaining = length;
          var cursor = offset;
          try {
            while (remaining > 0) {
              final count = remaining.clamp(0, 512 * 1024);
              final data = Uint8List(count);
              for (var i = 0; i < count; i++) {
                data[i] = (cursor + i) % 251;
              }
              yield data;
              cursor += count;
              remaining -= count;
            }
          } finally {
            active--;
          }
        }),
      );
      final size = parallelDownloadThreshold + 3;
      final result = await downloader.download(
        peer: peer,
        item: item(size),
        directory: directory,
      );
      expect(requested.length, 4);
      expect(peakActive, 4);
      expect(await result.length(), size);
      final handle = await result.open();
      try {
        for (final range in downloadRanges(size)) {
          await handle.setPosition(range.offset);
          final sample = await handle.read(100);
          expect(
            sample,
            List.generate(100, (index) => (range.offset + index) % 251),
          );
        }
        await handle.setPosition(size - 1);
        expect(await handle.readByte(), (size - 1) % 251);
      } finally {
        await handle.close();
      }
      expect(await directory.list().length, 1);
    },
  );
}
