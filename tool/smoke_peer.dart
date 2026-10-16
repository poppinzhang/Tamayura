// A reproducible test peer for Android emulator network smoke checks.
// Connect from the emulator to 10.0.2.2:50728. No user photos are shared.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:tamayura/app/endpoint.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/network/media_rpc.dart';

class SmokeSource implements LocalMediaSource {
  SmokeSource({this.count = 1, this.delay = Duration.zero});
  final Duration delay;
  final int count;
  final int modifiedMs = DateTime.now().millisecondsSinceEpoch;
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  @override
  Future<List<MediaMetadata>> scan() async => List.generate(
    count,
    (index) => MediaMetadata(
      id: count == 1
          ? 'smoke-photo'
          : 'smoke-photo-${index.toString().padLeft(6, '0')}',
      deviceId: 'tamayura-smoke-peer',
      name: '网络测试图片-$index.png',
      sharedFolderId: 'smoke-folder-${index % 2}',
      sharedFolderName: index.isEven ? '相机' : '旅行',
      relativePath: '2026/网络测试图片-$index.png',
      mimeType: 'image/png',
      size: bytes.length,
      modifiedMs: modifiedMs - index,
    ),
  );
  @override
  Future<Uint8List> readThumbnail(String id) async => bytes;
  @override
  Future<Uint8List> readRange(String id, int offset, int length) async {
    await Future<void>.delayed(delay);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

Future<void> main(List<String> arguments) async {
  final count = arguments.isEmpty ? 1 : int.parse(arguments.first);
  if (count < 1 || count > 100000) {
    throw ArgumentError("count must be 1..100000");
  }
  final server = MediaRpcServer(
    identity: const Peer(
      id: 'tamayura-smoke-peer',
      name: '网络测试设备',
      host: '',
      port: 0,
    ),
    source: SmokeSource(
      count: count,
      delay: Duration(
        seconds: arguments.length > 1 ? int.parse(arguments[1]) : 0,
      ),
    ),
  );
  await server.start(port: LanEndpoint.defaultPort);
  stdout.writeln(
    'Test peer ready. Android emulator endpoint: 10.0.2.2:${server.port}',
  );
  await ProcessSignal.sigint.watch().first;
  await server.stop();
}
