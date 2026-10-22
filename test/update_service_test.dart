import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:tamayura/app/app_info.dart';
import 'package:tamayura/update/update_service.dart';

const _current = AppVersion('0.7.0', '11');
const _repository = 'https://github.com/poppinzhang/Tamayura';

String _listUrl(int page) =>
    'https://api.github.com/repos/poppinzhang/Tamayura/releases?per_page=100&page=$page';

UpdateHttpResponse _jsonResponse(Object value, {void Function()? onClose}) =>
    UpdateHttpResponse(
      statusCode: 200,
      body: Stream.value(utf8.encode(jsonEncode(value))),
      onClose: onClose,
    );

class _Transport implements UpdateHttpTransport {
  final routes = <String, FutureOr<UpdateHttpResponse> Function()>{};
  final requests = <Uri>[];
  final requestHeaders = <Map<String, String>>[];
  final cancellations = <UpdateCancellation>[];

  @override
  Future<UpdateHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required UpdateCancellation cancellation,
  }) async {
    requests.add(uri);
    requestHeaders.add(headers);
    cancellations.add(cancellation);
    final route = routes[uri.toString()];
    if (route == null) throw StateError('Unexpected update request: $uri');
    return await route();
  }
}

class _Fixture {
  _Fixture({this.version = '0.8.0', this.target = UpdateTarget.android});

  final String version;
  final UpdateTarget target;
  final bytes = List.generate(32, (index) => index);

  String get filename =>
      'Tamayura-$version-${target == UpdateTarget.android ? 'android.apk' : 'windows-x64.zip'}';
  String get assetUrl => '$_repository/releases/download/v$version/$filename';
  String get metadataUrl =>
      '$_repository/releases/download/v$version/release.json';

  late final Map<String, dynamic> platform = {
    'filename': filename,
    'size_bytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
    'architectures': target == UpdateTarget.android
        ? ['armeabi-v7a', 'arm64-v8a', 'x86_64']
        : ['x64'],
  };

  late final Map<String, dynamic> metadata = {
    'tag': 'v$version',
    'version': version,
    'build_number': 12,
    'platforms': {target.name: platform},
  };

  late final Map<String, dynamic> packageAsset = {
    'name': filename,
    'size': bytes.length,
    'state': 'uploaded',
    'browser_download_url': assetUrl,
  };

  late final Map<String, dynamic> release = {
    'tag_name': 'v$version',
    'draft': false,
    'prerelease': true,
    'body': '修复与改进',
    'html_url': '$_repository/releases/tag/v$version',
    'assets': [
      {
        'name': 'release.json',
        'size': utf8.encode(jsonEncode(metadata)).length,
        'state': 'uploaded',
        'browser_download_url': metadataUrl,
      },
      packageAsset,
    ],
  };

  void install(_Transport transport) {
    transport.routes[_listUrl(1)] = () => _jsonResponse([release]);
    transport.routes[metadataUrl] = () => _jsonResponse(metadata);
    transport.routes[assetUrl] = () => UpdateHttpResponse(
      statusCode: 200,
      body: Stream.value(bytes),
      headers: {'content-length': '${bytes.length}'},
    );
  }
}

Matcher _failure(String message) => throwsA(
  isA<UpdateException>().having(
    (exception) => exception.message,
    'message',
    contains(message),
  ),
);

void main() {
  late _Transport transport;
  late UpdateService service;

  setUp(() {
    transport = _Transport();
    service = UpdateService(transport: transport);
  });

  group('release discovery', () {
    test(
      'accepts prerelease and exact Android metadata without credentials',
      () async {
        final fixture = _Fixture()..install(transport);
        final release = await service.check(_current, UpdateTarget.android);

        expect(release!.version, '0.8.0');
        expect(release.buildNumber, 12);
        expect(release.notes, '修复与改进');
        expect(release.asset!.filename, fixture.filename);
        expect(release.asset!.sizeBytes, fixture.bytes.length);
        expect(release.asset!.sha256, sha256.convert(fixture.bytes).toString());
        expect(release.pageUrl.toString(), fixture.release['html_url']);
        expect(transport.requests, [
          Uri.parse(_listUrl(1)),
          Uri.parse(fixture.metadataUrl),
        ]);
        expect(
          transport.requestHeaders.every(
            (headers) => !headers.containsKey('Authorization'),
          ),
          isTrue,
        );
        expect(transport.requestHeaders.first['Accept'], isNull);
        expect(
          transport.requestHeaders.first['accept'],
          'application/vnd.github+json',
        );
      },
    );

    test('selects Windows x64 package and accepts stable releases', () async {
      final fixture = _Fixture(target: UpdateTarget.windows);
      fixture.release['prerelease'] = false;
      fixture.install(transport);
      final release = await service.check(_current, UpdateTarget.windows);
      expect(release!.asset!.filename, endsWith('-windows-x64.zip'));
    });

    test(
      'macOS only reads releases and opens the specific version page',
      () async {
        final fixture = _Fixture();
        fixture.release.remove('assets');
        fixture.install(transport);
        final release = await service.check(_current, UpdateTarget.macos);
        expect(release!.asset, isNull);
        expect(release.buildNumber, isNull);
        expect(release.pageUrl.toString(), '$_repository/releases/tag/v0.8.0');
        expect(transport.requests.length, 1);
      },
    );

    test(
      'Linux only reads releases and opens the specific version page',
      () async {
        final fixture = _Fixture();
        fixture.release.remove('assets');
        fixture.install(transport);
        final release = await service.check(_current, UpdateTarget.linux);
        expect(release!.asset, isNull);
        expect(release.buildNumber, isNull);
        expect(release.pageUrl.toString(), '$_repository/releases/tag/v0.8.0');
        expect(transport.requests.length, 1);
      },
    );

    test(
      'compares numeric components and ignores draft or invalid tags',
      () async {
        final lower = _Fixture(version: '0.9.9');
        final higher = _Fixture(version: '0.10.0');
        final draft = _Fixture(version: '9.0.0');
        draft.release['draft'] = true;
        transport.routes[_listUrl(1)] = () => _jsonResponse([
          lower.release,
          draft.release,
          {'draft': false, 'tag_name': 'v01.0.0'},
          {'draft': false, 'tag_name': 'v2.0.0-beta'},
          {'draft': false, 'tag_name': 'v2.0'},
          {'draft': false, 'tag_name': '2.0.0'},
          {'draft': false, 'tag_name': 'v92233720368547758080.0.0'},
          higher.release,
        ]);
        final release = await service.check(_current, UpdateTarget.macos);
        expect(release!.version, '0.10.0');
      },
    );

    for (final version in ['0.7.0', '0.6.9']) {
      test('does not offer equal or older version $version', () async {
        _Fixture(version: version).install(transport);
        expect(await service.check(_current, UpdateTarget.android), isNull);
        expect(transport.requests.length, 1);
      });
    }

    test('empty published list means no update', () async {
      transport.routes[_listUrl(1)] = () => _jsonResponse([]);
      expect(await service.check(_current, UpdateTarget.macos), isNull);
    });

    test('reads additional release pages before choosing a version', () async {
      transport.routes[_listUrl(1)] = () => _jsonResponse(
        List.generate(100, (_) => _Fixture(version: '0.7.0').release),
      );
      transport.routes[_listUrl(2)] = () =>
          _jsonResponse([_Fixture(version: '0.10.0').release]);
      expect(
        (await service.check(_current, UpdateTarget.macos))!.version,
        '0.10.0',
      );
      expect(transport.requests.length, 2);
    });

    test(
      'bounded pagination fails visibly rather than reporting current',
      () async {
        for (var page = 1; page <= 5; page++) {
          transport.routes[_listUrl(page)] = () => _jsonResponse(
            List.generate(100, (_) => _Fixture(version: '0.7.0').release),
          );
        }
        await expectLater(
          service.check(_current, UpdateTarget.macos),
          _failure('版本列表过长'),
        );
        expect(transport.requests.length, 5);
      },
    );

    test(
      'invalid installed version does not trigger network requests',
      () async {
        await expectLater(
          service.check(const AppVersion('dev', '11'), UpdateTarget.android),
          _failure('当前应用版本'),
        );
        await expectLater(
          service.check(const AppVersion('0.7.0', 'x'), UpdateTarget.android),
          _failure('当前应用版本'),
        );
        expect(transport.requests, isEmpty);
      },
    );

    test('Android requires an increasing build number', () async {
      final fixture = _Fixture();
      fixture.metadata['build_number'] = 11;
      fixture.install(transport);
      await expectLater(
        service.check(_current, UpdateTarget.android),
        _failure('构建号'),
      );
    });

    test('release notes may be empty and are bounded', () async {
      final fixture = _Fixture();
      fixture.release['body'] = null;
      fixture.install(transport);
      expect((await service.check(_current, UpdateTarget.macos))!.notes, '');
      fixture.release['body'] = 'a' * 21000;
      expect(
        (await service.check(_current, UpdateTarget.macos))!.notes.length,
        20000,
      );
    });

    for (final code in [403, 429]) {
      test('rate limit $code is an error, not an up-to-date result', () async {
        var closed = false;
        transport.routes[_listUrl(1)] = () => UpdateHttpResponse(
          statusCode: code,
          body: const Stream.empty(),
          onClose: () => closed = true,
        );
        await expectLater(
          service.check(_current, UpdateTarget.macos),
          _failure('请求过于频繁'),
        );
        expect(closed, isTrue);
      });
    }

    test('network failure and malformed JSON allow retry', () async {
      transport.routes[_listUrl(1)] = () =>
          throw const SocketException('offline');
      await expectLater(
        service.check(_current, UpdateTarget.macos),
        _failure('检查网络'),
      );
      transport.routes[_listUrl(1)] = () => UpdateHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode('{')),
      );
      await expectLater(
        service.check(_current, UpdateTarget.macos),
        _failure('格式不正确'),
      );
      _Fixture().install(transport);
      expect(await service.check(_current, UpdateTarget.macos), isNotNull);
    });

    for (final invalid in [
      null,
      {},
      [
        {'tag_name': 'v1.0.0'},
      ],
    ]) {
      test('rejects invalid releases shape $invalid', () async {
        transport.routes[_listUrl(1)] = () => _jsonResponse(invalid ?? 'null');
        await expectLater(
          service.check(_current, UpdateTarget.macos),
          _failure('列表格式'),
        );
      });
    }

    test(
      'missing latest attachments is visible instead of claiming latest',
      () async {
        final fixture = _Fixture();
        fixture.release['assets'] = [];
        fixture.install(transport);
        await expectLater(
          service.check(_current, UpdateTarget.android),
          _failure('发布附件'),
        );
      },
    );

    test(
      'rejects duplicate package attachments and incomplete uploads',
      () async {
        final fixture = _Fixture()..install(transport);
        final assets = fixture.release['assets'] as List;
        assets.add(fixture.packageAsset);
        await expectLater(
          service.check(_current, UpdateTarget.android),
          _failure('唯一'),
        );
        assets.removeLast();
        fixture.packageAsset['state'] = 'new';
        await expectLater(
          service.check(_current, UpdateTarget.android),
          _failure('尚未上传完成'),
        );
      },
    );

    for (final field in ['tag', 'version', 'build_number']) {
      test('rejects metadata mismatched $field', () async {
        final fixture = _Fixture();
        fixture.metadata[field] = field == 'build_number' ? 0 : 'invalid';
        fixture.install(transport);
        await expectLater(
          service.check(_current, UpdateTarget.android),
          _failure('发布版本不一致'),
        );
      });
    }

    test(
      'rejects unsupported architecture and package size mismatch',
      () async {
        final fixture = _Fixture(target: UpdateTarget.windows)
          ..install(transport);
        fixture.platform['architectures'] = ['arm64'];
        await expectLater(
          service.check(_current, UpdateTarget.windows),
          _failure('架构'),
        );
        fixture.platform['architectures'] = ['x64'];
        fixture.packageAsset['size'] = 99;
        await expectLater(
          service.check(_current, UpdateTarget.windows),
          _failure('大小'),
        );
      },
    );

    test('rejects metadata path traversal and malformed digest', () async {
      final fixture = _Fixture()..install(transport);
      fixture.platform['filename'] = '../Tamayura.apk';
      await expectLater(
        service.check(_current, UpdateTarget.android),
        _failure('安装包信息'),
      );
      fixture.platform['filename'] = fixture.filename;
      fixture.platform['sha256'] = 'invalid';
      await expectLater(
        service.check(_current, UpdateTarget.android),
        _failure('安装包信息'),
      );
    });

    test('rejects untrusted release page and mismatched asset URL', () async {
      final fixture = _Fixture()..install(transport);
      fixture.release['html_url'] = 'https://example.invalid/update';
      await expectLater(
        service.check(_current, UpdateTarget.android),
        _failure('页面地址'),
      );
      fixture.release['html_url'] =
          '$_repository/releases/tag/v${fixture.version}';
      fixture.packageAsset['browser_download_url'] =
          '$_repository/releases/download/v0.1.0/${fixture.filename}';
      await expectLater(
        service.check(_current, UpdateTarget.android),
        _failure('附件地址'),
      );
    });

    test(
      'bounds metadata response size even when content length is absent',
      () async {
        final fixture = _Fixture()..install(transport);
        transport.routes[fixture.metadataUrl] = () => UpdateHttpResponse(
          statusCode: 200,
          body: Stream.value(List.filled(65537, 32)),
        );
        await expectLater(
          service.check(_current, UpdateTarget.android),
          _failure('允许大小'),
        );
      },
    );

    test(
      'request timeout cancels transport and leaves service reusable',
      () async {
        service = UpdateService(
          transport: transport,
          requestTimeout: const Duration(milliseconds: 20),
        );
        final pending = Completer<UpdateHttpResponse>();
        transport.routes[_listUrl(1)] = () => pending.future;
        await expectLater(
          service.check(_current, UpdateTarget.macos),
          _failure('超时'),
        );
        expect(transport.cancellations.single.isCancelled, isTrue);
        _Fixture().install(transport);
        expect(await service.check(_current, UpdateTarget.macos), isNotNull);
        pending.complete(
          UpdateHttpResponse(statusCode: 200, body: const Stream.empty()),
        );
      },
    );

    test('body timeout closes response', () async {
      service = UpdateService(
        transport: transport,
        requestTimeout: const Duration(milliseconds: 20),
      );
      final stream = StreamController<List<int>>();
      var closed = false;
      transport.routes[_listUrl(1)] = () => UpdateHttpResponse(
        statusCode: 200,
        body: stream.stream,
        onClose: () => closed = true,
      );
      await expectLater(
        service.check(_current, UpdateTarget.macos),
        _failure('超时'),
      );
      expect(closed, isTrue);
      await stream.close();
    });

    test(
      'concurrent operations are rejected and check can be cancelled',
      () async {
        final pending = Completer<UpdateHttpResponse>();
        transport.routes[_listUrl(1)] = () => pending.future;
        final cancellation = UpdateCancellation();
        final checking = service.check(
          _current,
          UpdateTarget.macos,
          cancellation: cancellation,
        );
        await expectLater(
          service.check(_current, UpdateTarget.macos),
          _failure('正在进行'),
        );
        final expected = expectLater(
          checking,
          throwsA(isA<UpdateCancelledException>()),
        );
        cancellation.cancel();
        await expected;
        expect(transport.cancellations.single.isCancelled, isTrue);
        pending.complete(
          UpdateHttpResponse(statusCode: 200, body: const Stream.empty()),
        );
      },
    );
  });

  group('package download', () {
    late Directory directory;
    late _Fixture fixture;
    late UpdateRelease release;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'tamayura-update-test-',
      );
      fixture = _Fixture()..install(transport);
      release = (await service.check(_current, UpdateTarget.android))!;
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test(
      'streams chunks, reports progress, verifies and renames atomically',
      () async {
        var closed = false;
        transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
          statusCode: 200,
          body: Stream.fromIterable([
            fixture.bytes.sublist(0, 5),
            fixture.bytes.sublist(5, 20),
            fixture.bytes.sublist(20),
          ]),
          onClose: () => closed = true,
        );
        final progress = <int>[];
        final package = await service.download(
          release,
          directory,
          onProgress: (received, total) {
            expect(total, fixture.bytes.length);
            progress.add(received);
          },
        );
        expect(await package.readAsBytes(), fixture.bytes);
        expect(path.basename(package.path), fixture.filename);
        expect(progress, [0, 5, 20, 32]);
        expect(
          await directory
              .list(recursive: true)
              .where((entry) => entry.path.endsWith('.part'))
              .toList(),
          isEmpty,
        );
        expect(closed, isTrue);
      },
    );

    for (final mode in ['corrupt', 'short', 'long']) {
      test('$mode download removes staging files and permits retry', () async {
        final bytes = switch (mode) {
          'corrupt' => List.filled(fixture.bytes.length, 255),
          'short' => fixture.bytes.sublist(0, fixture.bytes.length - 1),
          _ => [...fixture.bytes, 0],
        };
        transport.routes[fixture.assetUrl] = () =>
            UpdateHttpResponse(statusCode: 200, body: Stream.value(bytes));
        await expectLater(
          service.download(release, directory),
          throwsA(isA<UpdateException>()),
        );
        expect(await directory.list().toList(), isEmpty);
        fixture.install(transport);
        expect(
          await (await service.download(release, directory)).readAsBytes(),
          fixture.bytes,
        );
      });
    }

    test('rejects incorrect Content-Length before accepting package', () async {
      transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
        statusCode: 200,
        headers: {'content-length': '31'},
        body: Stream.value(fixture.bytes),
      );
      await expectLater(service.download(release, directory), _failure('大小'));
      expect(await directory.list().toList(), isEmpty);
    });

    test('cancellation between chunks deletes partial package', () async {
      final cancellation = UpdateCancellation();
      transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          fixture.bytes.sublist(0, 5),
          fixture.bytes.sublist(5),
        ]),
      );
      await expectLater(
        service.download(
          release,
          directory,
          cancellation: cancellation,
          onProgress: (received, _) {
            if (received > 0) cancellation.cancel();
          },
        ),
        throwsA(isA<UpdateCancelledException>()),
      );
      expect(await directory.list().toList(), isEmpty);
    });

    test(
      'cancellation while waiting for data closes the active response',
      () async {
        final stream = StreamController<List<int>>();
        final started = Completer<void>();
        var closed = false;
        transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
          statusCode: 200,
          body: stream.stream,
          onClose: () => closed = true,
        );
        final cancellation = UpdateCancellation();
        final downloading = service.download(
          release,
          directory,
          cancellation: cancellation,
          onProgress: (_, _) => started.complete(),
        );
        final expected = expectLater(
          downloading,
          throwsA(isA<UpdateCancelledException>()),
        );
        await started.future;
        cancellation.cancel();
        await expected;
        expect(closed, isTrue);
        expect(await directory.list().toList(), isEmpty);
        await stream.close();
      },
    );

    test('already cancelled download never creates staging files', () async {
      final cancellation = UpdateCancellation()..cancel();
      await expectLater(
        service.download(release, directory, cancellation: cancellation),
        throwsA(isA<UpdateCancelledException>()),
      );
      expect(await directory.list().toList(), isEmpty);
    });

    test('idle download timeout cleans partial file', () async {
      service = UpdateService(
        transport: transport,
        requestTimeout: const Duration(milliseconds: 20),
      );
      final stream = StreamController<List<int>>();
      transport.routes[fixture.assetUrl] = () =>
          UpdateHttpResponse(statusCode: 200, body: stream.stream);
      await expectLater(service.download(release, directory), _failure('超时'));
      expect(await directory.list().toList(), isEmpty);
      await stream.close();
    });

    test(
      'disk failure is actionable and does not expose filesystem paths',
      () async {
        final occupied = File(path.join(directory.path, 'not-a-directory'));
        await occupied.writeAsString('occupied');
        await expectLater(
          service.download(release, Directory(occupied.path)),
          _failure('可用空间和目录权限'),
        );
        expect(await occupied.readAsString(), 'occupied');
      },
    );

    test('forged package names and URLs fail before writing', () async {
      for (final asset in [
        UpdateAsset(
          filename: '../escape.apk',
          url: release.asset!.url,
          sizeBytes: 32,
          sha256: release.asset!.sha256,
        ),
        UpdateAsset(
          filename: release.asset!.filename,
          url: Uri.parse('https://example.invalid/package.apk'),
          sizeBytes: 32,
          sha256: release.asset!.sha256,
        ),
      ]) {
        final forged = UpdateRelease(
          version: release.version,
          notes: '',
          pageUrl: release.pageUrl,
          asset: asset,
        );
        await expectLater(
          service.download(forged, directory),
          _failure('安装包信息无效'),
        );
      }
      expect(await directory.list().toList(), isEmpty);
    });

    test(
      'allows GitHub release asset HTTPS redirect and verifies result',
      () async {
        const redirected =
            'https://release-assets.githubusercontent.com/github-production-release-asset/1/package?token=download';
        transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
          statusCode: 302,
          headers: {'location': redirected},
          body: const Stream.empty(),
        );
        transport.routes[redirected] = () => UpdateHttpResponse(
          statusCode: 200,
          body: Stream.value(fixture.bytes),
        );
        final package = await service.download(release, directory);
        expect(await package.readAsBytes(), fixture.bytes);
        expect(transport.requests.last.toString(), redirected);
      },
    );

    for (final location in [
      'http://github.com/poppinzhang/Tamayura/releases/download/v0.8.0/package',
      'https://release-assets.githubusercontent.com.attacker.invalid/package',
      'https://user:password@release-assets.githubusercontent.com/package',
      'https://release-assets.githubusercontent.com:8443/package',
      'https://github.com/another/repository/releases/download/v0.8.0/package',
      'https://example.invalid/package',
    ]) {
      test('rejects untrusted redirect $location', () async {
        transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
          statusCode: 302,
          headers: {'location': location},
          body: const Stream.empty(),
        );
        await expectLater(
          service.download(release, directory),
          _failure('不受信任'),
        );
        expect(await directory.list().toList(), isEmpty);
        expect(transport.requests.last.toString(), fixture.assetUrl);
      });
    }

    test('redirect loops are bounded', () async {
      transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
        statusCode: 302,
        headers: {'location': fixture.assetUrl},
        body: const Stream.empty(),
      );
      await expectLater(
        service.download(release, directory),
        _failure('重定向异常'),
      );
      expect(
        transport.requests
            .where((uri) => uri.toString() == fixture.assetUrl)
            .length,
        6,
      );
      expect(await directory.list().toList(), isEmpty);
    });

    test(
      'rejects unexpected encodings and partial response statuses',
      () async {
        transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
          statusCode: 200,
          headers: {'content-encoding': 'gzip'},
          body: Stream.value(fixture.bytes),
        );
        await expectLater(
          service.download(release, directory),
          _failure('下载编码'),
        );
        transport.routes[fixture.assetUrl] = () => UpdateHttpResponse(
          statusCode: 206,
          body: Stream.value(fixture.bytes),
        );
        await expectLater(
          service.download(release, directory),
          _failure('暂时不可用'),
        );
        expect(await directory.list().toList(), isEmpty);
      },
    );
  });
}
