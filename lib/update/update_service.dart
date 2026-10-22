import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../app/app_info.dart';
import '../l10n/app_locale.dart';

enum UpdateTarget {
  android,
  windows,
  macos,
  linux;

  /// macOS and Linux open the release page; the user replaces the app.
  bool get opensReleasePage => this == macos || this == linux;
}

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

class UpdateCancelledException implements UpdateException {
  const UpdateCancelledException();

  @override
  String get message => AppLocale.strings.updateErrorCancelled;

  @override
  String toString() => message;
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
      throw UpdateException(AppLocale.strings.updateErrorCurrentVersion);
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
        throw UpdateException(AppLocale.strings.updateErrorReleaseList);
      }
      for (final entry in payload) {
        if (entry is! Map<String, dynamic> || entry['draft'] is! bool) {
          throw UpdateException(AppLocale.strings.updateErrorReleaseList);
        }
        if (entry['draft'] == true) continue;
        if (entry['prerelease'] is! bool) {
          throw UpdateException(AppLocale.strings.updateErrorReleaseList);
        }
        if (entry['prerelease'] == true) continue;
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
          throw UpdateException(AppLocale.strings.updateErrorPageUrl);
        }
        final notes = entry['body'];
        if (notes != null && notes is! String) {
          throw UpdateException(AppLocale.strings.updateErrorNotes);
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
      throw UpdateException(AppLocale.strings.updateErrorListTooLong);
    }
    if (candidates.isEmpty) return null;
    candidates.sort(
      (left, right) => _compareVersion(right.components, left.components),
    );
    final candidate = candidates.first;
    if (target.opensReleasePage) {
      return candidate.release();
    }
    final metadataAsset = _findAsset(candidate, 'release.json');
    final metadataSize = metadataAsset['size'];
    if (metadataSize is! int ||
        metadataSize < 1 ||
        metadataSize > _maximumMetadataBytes) {
      throw UpdateException(AppLocale.strings.updateErrorManifest);
    }
    final metadata = await _json(
      _assetUrl(candidate, metadataAsset, 'release.json'),
      _maximumMetadataBytes,
      cancel,
    );
    if (metadata is! Map<String, dynamic> ||
        metadata['tag'] != 'v${candidate.version}' ||
        metadata['version'] != candidate.version ||
        metadata['release_type'] != 'release' ||
        metadata['build_number'] is! int ||
        (metadata['build_number'] as int) < 1) {
      throw UpdateException(AppLocale.strings.updateErrorManifestMismatch);
    }
    final buildNumber = metadata['build_number'] as int;
    if (target == UpdateTarget.android && buildNumber <= currentBuild) {
      throw UpdateException(AppLocale.strings.updateErrorAndroidBuild);
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
      throw UpdateException(AppLocale.strings.updateErrorPackageInfo);
    }
    final architectures = platform['architectures'];
    final expectedArchitectures = target == UpdateTarget.android
        ? {'armeabi-v7a', 'arm64-v8a', 'x86_64'}
        : {'x64'};
    if (architectures is! List ||
        architectures.length != expectedArchitectures.length ||
        !architectures.toSet().containsAll(expectedArchitectures)) {
      throw UpdateException(AppLocale.strings.updateErrorArchitecture);
    }
    final asset = _findAsset(candidate, filename);
    if (asset['size'] != platform['size_bytes']) {
      throw UpdateException(AppLocale.strings.updateErrorPackageSize);
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
      throw UpdateException(AppLocale.strings.updateErrorInvalidPackage);
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
        throw UpdateException(AppLocale.strings.updateErrorDownloadSize);
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
          throw UpdateException(AppLocale.strings.updateErrorDownloadTooLarge);
        }
        await output.writeFrom(chunk);
        sink.add(chunk);
        onProgress?.call(received, asset.sizeBytes);
      }
      cancel._throwIfCancelled();
      sink.close();
      if (received != asset.sizeBytes ||
          digest.value.toString() != asset.sha256.toLowerCase()) {
        throw UpdateException(AppLocale.strings.updateErrorChecksum);
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
    if (_busy) throw UpdateException(AppLocale.strings.updateErrorBusy);
    _busy = true;
    try {
      cancellation._throwIfCancelled();
      return await operation(cancellation);
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw UpdateException(AppLocale.strings.updateErrorTimeout);
    } on SocketException {
      throw UpdateException(AppLocale.strings.updateErrorConnect);
    } on HttpException {
      throw UpdateException(AppLocale.strings.updateErrorConnectionLost);
    } on FileSystemException {
      throw UpdateException(AppLocale.strings.updateErrorStorage);
    } on FormatException {
      throw UpdateException(AppLocale.strings.updateErrorFormat);
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
          throw UpdateException(AppLocale.strings.updateErrorResponseTooLarge);
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
          throw UpdateException(AppLocale.strings.updateErrorRedirect);
        }
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        response.close();
        throw UpdateException(AppLocale.strings.updateErrorForbidden);
      }
      if (response.statusCode != 200) {
        response.close();
        throw UpdateException(AppLocale.strings.updateErrorUnavailable);
      }
      final encoding = response.headers['content-encoding'];
      if (encoding != null && encoding != 'identity') {
        response.close();
        throw UpdateException(AppLocale.strings.updateErrorEncoding);
      }
      return response;
    }
    throw UpdateException(AppLocale.strings.updateErrorRedirect);
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
      throw UpdateException(AppLocale.strings.updateErrorUntrustedUrl);
    }
  }

  static Map<String, dynamic> _findAsset(
    _ReleaseCandidate candidate,
    String filename,
  ) {
    final assets = candidate.assets;
    if (assets is! List) {
      throw UpdateException(AppLocale.strings.updateErrorNoAssets);
    }
    final matching = assets.where(
      (asset) => asset is Map<String, dynamic> && asset['name'] == filename,
    );
    if (matching.length != 1) {
      throw UpdateException(AppLocale.strings.updateErrorAmbiguousAssets);
    }
    final asset = matching.single as Map<String, dynamic>;
    if (asset['state'] != 'uploaded') {
      throw UpdateException(AppLocale.strings.updateErrorAssetsPending);
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
      throw UpdateException(AppLocale.strings.updateErrorAssetUrl);
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
