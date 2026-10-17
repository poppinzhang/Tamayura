import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../app/app_info.dart';

enum UpdateTarget { android, windows, macos }

class UpdateAsset {
  const UpdateAsset({
    required this.filename,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
  });

  final String filename;
  final Uri url;
  final int sizeBytes;
  final String sha256;
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.notes,
    required this.pageUrl,
    this.buildNumber,
    this.asset,
  });

  final String version;
  final int? buildNumber;
  final String notes;
  final Uri pageUrl;
  final UpdateAsset? asset;
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateCancelledException extends UpdateException {
  const UpdateCancelledException() : super('已取消更新下载');
}

class UpdateCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (isCancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void _throwIfCancelled() {
    if (isCancelled) throw const UpdateCancelledException();
  }

  void _addListener(void Function() listener) {
    if (isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void _removeListener(void Function() listener) => _listeners.remove(listener);
}

abstract class UpdateHttpTransport {
  Future<UpdateHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required UpdateCancellation cancellation,
  });
}

class UpdateHttpResponse {
  UpdateHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
    void Function()? onClose,
  }) : _onClose = onClose;

  final int statusCode;
  final Stream<List<int>> body;
  final Map<String, String> headers;
  final void Function()? _onClose;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _onClose?.call();
  }
}

class UpdateService {
  UpdateService({
    UpdateHttpTransport? transport,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _transport = transport ?? _IoUpdateHttpTransport(requestTimeout);

  static const _repository = 'poppinzhang/Tamayura';
  static const _pageSize = 100;
  static const _maximumPages = 5;
  static const _maximumJsonBytes = 4 * 1024 * 1024;
  static const _maximumMetadataBytes = 64 * 1024;
  static const _maximumPackageBytes = 2 * 1024 * 1024 * 1024;
  static final _versionPattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );
  static final _digestPattern = RegExp(r'^[0-9a-fA-F]{64}$');

  final UpdateHttpTransport _transport;
  final Duration requestTimeout;
  bool _busy = false;

  Future<UpdateRelease?> check(
    AppVersion current,
    UpdateTarget target, {
    UpdateCancellation? cancellation,
  }) => _run(cancellation ?? UpdateCancellation(), (cancel) async {
    final currentVersion = _parseVersion(current.version);
    final currentBuild = int.tryParse(current.buildNumber);
    if (currentVersion == null || currentBuild == null || currentBuild < 1) {
      throw const UpdateException('无法识别当前应用版本，请重新安装正式发布的安装包');
    }
    final candidates = <_ReleaseCandidate>[];
    var finished = false;
    for (var page = 1; page <= _maximumPages; page++) {
      final uri = Uri.https('api.github.com', '/repos/$_repository/releases', {
        'per_page': '$_pageSize',
        'page': '$page',
      });
      final payload = await _json(uri, _maximumJsonBytes, cancel);
      if (payload is! List || payload.length > _pageSize) {
        throw const UpdateException('GitHub 版本列表格式不正确，请稍后重试');
      }
      for (final entry in payload) {
        if (entry is! Map<String, dynamic> || entry['draft'] is! bool) {
          throw const UpdateException('GitHub 版本列表格式不正确，请稍后重试');
        }
        if (entry['draft'] == true) continue;
        final tag = entry['tag_name'];
        if (tag is! String || !tag.startsWith('v')) continue;
        final version = _parseVersion(tag.substring(1));
        if (version == null || _compareVersion(version, currentVersion) <= 0) {
          continue;
        }
        final pageUrl = Uri.https(
          'github.com',
          '/$_repository/releases/tag/$tag',
        );
        if (entry['html_url'] != pageUrl.toString()) {
          throw const UpdateException('更新页面地址无效，请稍后重试');
        }
        final notes = entry['body'];
        if (notes != null && notes is! String) {
          throw const UpdateException('更新说明格式不正确，请稍后重试');
        }
        candidates.add(
          _ReleaseCandidate(
            version: tag.substring(1),
            components: version,
            pageUrl: pageUrl,
            notes: notes == null
                ? ''
                : (notes as String).substring(
                    0,
                    notes.length > 20000 ? 20000 : notes.length,
                  ),
            assets: entry['assets'],
          ),
        );
      }
      if (payload.length < _pageSize) {
        finished = true;
        break;
      }
    }
    if (!finished) {
      throw const UpdateException('版本列表过长，暂时无法确认最新版本，请前往 GitHub 查看');
    }
    if (candidates.isEmpty) return null;
    candidates.sort(
      (left, right) => _compareVersion(right.components, left.components),
    );
    final candidate = candidates.first;
    if (target == UpdateTarget.macos) {
      return candidate.release();
    }
    final metadataAsset = _findAsset(candidate, 'release.json');
    final metadataSize = metadataAsset['size'];
    if (metadataSize is! int ||
        metadataSize < 1 ||
        metadataSize > _maximumMetadataBytes) {
      throw const UpdateException('新版本的更新清单无效，暂时无法自动更新');
    }
    final metadata = await _json(
      _assetUrl(candidate, metadataAsset, 'release.json'),
      _maximumMetadataBytes,
      cancel,
    );
    if (metadata is! Map<String, dynamic> ||
        metadata['tag'] != 'v${candidate.version}' ||
        metadata['version'] != candidate.version ||
        metadata['build_number'] is! int ||
        (metadata['build_number'] as int) < 1) {
      throw const UpdateException('新版本的更新清单与发布版本不一致');
    }
    final buildNumber = metadata['build_number'] as int;
    if (target == UpdateTarget.android && buildNumber <= currentBuild) {
      throw const UpdateException('新版本的 Android 构建号无效，暂时无法覆盖安装');
    }
    final platforms = metadata['platforms'];
    final platform = platforms is Map<String, dynamic>
        ? platforms[target.name]
        : null;
    final suffix = target == UpdateTarget.android
        ? 'android.apk'
        : 'windows-x64.zip';
    final filename = 'Tamayura-${candidate.version}-$suffix';
    if (platform is! Map<String, dynamic> ||
        platform['filename'] != filename ||
        platform['size_bytes'] is! int ||
        (platform['size_bytes'] as int) < 1 ||
        (platform['size_bytes'] as int) > _maximumPackageBytes ||
        platform['sha256'] is! String ||
        !_digestPattern.hasMatch(platform['sha256'] as String)) {
      throw const UpdateException('新版本缺少有效的对应平台安装包信息');
    }
    final architectures = platform['architectures'];
    final expectedArchitectures = target == UpdateTarget.android
        ? {'armeabi-v7a', 'arm64-v8a', 'x86_64'}
        : {'x64'};
    if (architectures is! List ||
        architectures.length != expectedArchitectures.length ||
        !architectures.toSet().containsAll(expectedArchitectures)) {
      throw const UpdateException('新版本的安装包架构不受支持');
    }
    final asset = _findAsset(candidate, filename);
    if (asset['size'] != platform['size_bytes']) {
      throw const UpdateException('新版本的安装包大小与更新清单不一致');
    }
    return candidate.release(
      buildNumber: buildNumber,
      asset: UpdateAsset(
        filename: filename,
        url: _assetUrl(candidate, asset, filename),
        sizeBytes: platform['size_bytes'] as int,
        sha256: (platform['sha256'] as String).toLowerCase(),
      ),
    );
  });

  Future<File> download(
    UpdateRelease release,
    Directory directory, {
    void Function(int received, int total)? onProgress,
    UpdateCancellation? cancellation,
  }) => _run(cancellation ?? UpdateCancellation(), (cancel) async {
    final asset = release.asset;
    if (_parseVersion(release.version) == null ||
        asset == null ||
        !{
          'Tamayura-${release.version}-android.apk',
          'Tamayura-${release.version}-windows-x64.zip',
        }.contains(asset.filename) ||
        asset.sizeBytes < 1 ||
        asset.sizeBytes > _maximumPackageBytes ||
        !_digestPattern.hasMatch(asset.sha256) ||
        asset.url !=
            Uri.https(
              'github.com',
              '/$_repository/releases/download/v${release.version}/${asset.filename}',
            )) {
      throw const UpdateException('安装包信息无效，请重新检查更新');
    }
    Directory? staging;
    RandomAccessFile? output;
    UpdateHttpResponse? response;
    StreamIterator<List<int>>? iterator;
    var complete = false;
    try {
      await directory.create(recursive: true);
      staging = await directory.createTemp('update-');
      final temporary = File(path.join(staging.path, '${asset.filename}.part'));
      output = await temporary.open(mode: FileMode.writeOnly);
      response = await _request(asset.url, cancel);
      final contentLength = response.headers['content-length'];
      if (contentLength != null &&
          int.tryParse(contentLength) != asset.sizeBytes) {
        throw const UpdateException('安装包下载大小与更新清单不一致，请重试');
      }
      final digest = _UpdateDigest();
      final sink = sha256.startChunkedConversion(digest);
      var received = 0;
      onProgress?.call(received, asset.sizeBytes);
      iterator = StreamIterator(response.body.timeout(requestTimeout));
      while (await _wait(iterator.moveNext(), cancel)) {
        cancel._throwIfCancelled();
        final chunk = iterator.current;
        received += chunk.length;
        if (received > asset.sizeBytes) {
          throw const UpdateException('安装包下载大小超出更新清单，请重试');
        }
        await output.writeFrom(chunk);
        sink.add(chunk);
        onProgress?.call(received, asset.sizeBytes);
      }
      cancel._throwIfCancelled();
      sink.close();
      if (received != asset.sizeBytes ||
          digest.value.toString() != asset.sha256.toLowerCase()) {
        throw const UpdateException('安装包完整性校验失败，请重新下载');
      }
      await output.flush();
      await output.close();
      output = null;
      cancel._throwIfCancelled();
      final package = await temporary.rename(
        path.join(staging.path, asset.filename),
      );
      cancel._throwIfCancelled();
      complete = true;
      return package;
    } finally {
      response?.close();
      try {
        await iterator?.cancel();
      } finally {
        try {
          await output?.close();
        } finally {
          if (!complete && staging != null && await staging.exists()) {
            await staging.delete(recursive: true);
          }
        }
      }
    }
  });

  Future<T> _run<T>(
    UpdateCancellation cancellation,
    Future<T> Function(UpdateCancellation) operation,
  ) async {
    if (_busy) throw const UpdateException('已有更新操作正在进行，请稍候');
    _busy = true;
    try {
      cancellation._throwIfCancelled();
      return await operation(cancellation);
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw const UpdateException('连接 GitHub 或下载安装包超时，请检查网络后重试');
    } on SocketException {
      throw const UpdateException('无法连接 GitHub，请检查网络后重试');
    } on HttpException {
      throw const UpdateException('GitHub 连接中断，请稍后重试');
    } on FileSystemException {
      throw const UpdateException('无法保存更新安装包，请检查可用空间和目录权限后重试');
    } on FormatException {
      throw const UpdateException('更新信息格式不正确，请稍后重试');
    } finally {
      _busy = false;
    }
  }

  Future<Object?> _json(
    Uri uri,
    int maximumBytes,
    UpdateCancellation cancellation,
  ) async {
    final response = await _request(uri, cancellation);
    final iterator = StreamIterator(response.body.timeout(requestTimeout));
    final elapsed = Stopwatch()..start();
    try {
      final bytes = BytesBuilder(copy: false);
      while (true) {
        final remaining = requestTimeout - elapsed.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Update metadata timeout');
        }
        if (!await _wait(
          iterator.moveNext().timeout(remaining),
          cancellation,
        )) {
          break;
        }
        if (bytes.length + iterator.current.length > maximumBytes) {
          throw const UpdateException('更新信息超过允许大小，请稍后重试');
        }
        bytes.add(iterator.current);
      }
      return jsonDecode(utf8.decode(bytes.takeBytes()));
    } finally {
      response.close();
      await iterator.cancel();
    }
  }

  Future<UpdateHttpResponse> _request(
    Uri uri,
    UpdateCancellation cancellation,
  ) async {
    var current = uri;
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancellation._throwIfCancelled();
      _validateRequestUrl(current);
      final requestCancellation = UpdateCancellation();
      cancellation._addListener(requestCancellation.cancel);
      UpdateHttpResponse response;
      try {
        response = await _wait(
          _transport
              .get(
                current,
                headers: {
                  HttpHeaders.acceptHeader: current.host == 'api.github.com'
                      ? 'application/vnd.github+json'
                      : 'application/octet-stream',
                  HttpHeaders.userAgentHeader: 'Tamayura-update',
                  HttpHeaders.acceptEncodingHeader: 'identity',
                  if (current.host == 'api.github.com')
                    'X-GitHub-Api-Version': '2022-11-28',
                },
                cancellation: requestCancellation,
              )
              .timeout(requestTimeout),
          cancellation,
        );
      } catch (_) {
        requestCancellation.cancel();
        rethrow;
      } finally {
        cancellation._removeListener(requestCancellation.cancel);
      }
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers['location'];
        response.close();
        if (location == null || redirects == 5) {
          throw const UpdateException('GitHub 下载地址重定向异常，请稍后重试');
        }
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        response.close();
        throw const UpdateException('GitHub 拒绝访问或请求过于频繁，请稍后重试');
      }
      if (response.statusCode != 200) {
        response.close();
        throw const UpdateException('GitHub 更新信息或安装包暂时不可用，请稍后重试');
      }
      final encoding = response.headers['content-encoding'];
      if (encoding != null && encoding != 'identity') {
        response.close();
        throw const UpdateException('GitHub 返回了不支持的下载编码，请稍后重试');
      }
      return response;
    }
    throw const UpdateException('GitHub 下载地址重定向异常，请稍后重试');
  }

  static void _validateRequestUrl(Uri uri) {
    final validHost = switch (uri.host) {
      'api.github.com' => uri.path == '/repos/$_repository/releases',
      'github.com' => uri.path.startsWith('/$_repository/releases/download/'),
      'release-assets.githubusercontent.com' => uri.path.startsWith('/'),
      _ => false,
    };
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        !validHost ||
        uri.pathSegments.any(
          (segment) => segment == '..' || segment.contains('\\'),
        )) {
      throw const UpdateException('更新下载地址不受信任，已停止更新');
    }
  }

  static Map<String, dynamic> _findAsset(
    _ReleaseCandidate candidate,
    String filename,
  ) {
    final assets = candidate.assets;
    if (assets is! List) {
      throw const UpdateException('新版本缺少发布附件，暂时无法自动更新');
    }
    final matching = assets.where(
      (asset) => asset is Map<String, dynamic> && asset['name'] == filename,
    );
    if (matching.length != 1) {
      throw const UpdateException('新版本缺少唯一且完整的发布附件，暂时无法自动更新');
    }
    final asset = matching.single as Map<String, dynamic>;
    if (asset['state'] != 'uploaded') {
      throw const UpdateException('新版本的发布附件尚未上传完成，请稍后重试');
    }
    return asset;
  }

  static Uri _assetUrl(
    _ReleaseCandidate candidate,
    Map<String, dynamic> asset,
    String filename,
  ) {
    final expected = Uri.https(
      'github.com',
      '/$_repository/releases/download/v${candidate.version}/$filename',
    );
    if (asset['browser_download_url'] != expected.toString()) {
      throw const UpdateException('更新附件地址与发布版本不一致');
    }
    return expected;
  }

  static List<int>? _parseVersion(String version) {
    if (!_versionPattern.hasMatch(version)) return null;
    final components = version.split('.').map(int.tryParse).toList();
    if (components.any((component) => component == null)) return null;
    return components.cast<int>();
  }

  static int _compareVersion(List<int> left, List<int> right) {
    for (var index = 0; index < 3; index++) {
      final comparison = left[index].compareTo(right[index]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static Future<T> _wait<T>(
    Future<T> operation,
    UpdateCancellation cancellation,
  ) async {
    final completion = Completer<T>();
    void cancel() {
      if (!completion.isCompleted) {
        completion.completeError(const UpdateCancelledException());
      }
    }

    cancellation._addListener(cancel);
    operation.then(
      (value) {
        if (!completion.isCompleted) completion.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completion.isCompleted) completion.completeError(error, stack);
      },
    );
    try {
      return await completion.future;
    } finally {
      cancellation._removeListener(cancel);
    }
  }
}

class _ReleaseCandidate {
  const _ReleaseCandidate({
    required this.version,
    required this.components,
    required this.pageUrl,
    required this.notes,
    required this.assets,
  });

  final String version;
  final List<int> components;
  final Uri pageUrl;
  final String notes;
  final Object? assets;

  UpdateRelease release({int? buildNumber, UpdateAsset? asset}) =>
      UpdateRelease(
        version: version,
        buildNumber: buildNumber,
        notes: notes,
        pageUrl: pageUrl,
        asset: asset,
      );
}

class _UpdateDigest implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _IoUpdateHttpTransport implements UpdateHttpTransport {
  const _IoUpdateHttpTransport(this.timeout);

  final Duration timeout;

  @override
  Future<UpdateHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required UpdateCancellation cancellation,
  }) async {
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = timeout;
    void abort() => client.close(force: true);
    cancellation._addListener(abort);
    try {
      cancellation._throwIfCancelled();
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close();
      cancellation._throwIfCancelled();
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(',');
      });
      return UpdateHttpResponse(
        statusCode: response.statusCode,
        headers: responseHeaders,
        body: response,
        onClose: () {
          cancellation._removeListener(abort);
          abort();
        },
      );
    } catch (_) {
      cancellation._removeListener(abort);
      abort();
      rethrow;
    }
  }
}
