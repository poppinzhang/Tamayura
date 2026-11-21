import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'models.dart';

const maxControlBytes = 1024 * 1024;

abstract interface class BridgeControl {
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]);
  Future<void> close();
}

Map<String, dynamic> decodeResponse(String message, int requestId) {
  try {
    if (utf8.encode(message).length > maxControlBytes) {
      throw const TailscaleException('responseTooLarge');
    }
    final json = jsonDecode(message);
    if (json is! Map<String, dynamic> ||
        json['id'] != requestId ||
        json.containsKey('error') == json.containsKey('result')) {
      throw const TailscaleException('invalidResponse');
    }
    if (json.containsKey('error')) {
      final error = json['error'];
      final code = error is Map ? error['code'] : null;
      // Never let native error text leak an authentication URL or private path.
      throw TailscaleException(
        code is String && RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(code)
            ? code
            : 'nativeFailure',
      );
    }
    final result = json['result'];
    if (result is! Map<String, dynamic>) {
      throw const TailscaleException('invalidResponse');
    }
    return result;
  } on TailscaleException {
    rethrow;
  } catch (_) {
    throw const TailscaleException('invalidResponse');
  }
}

/// Private inherited pipes: no TCP management server, PATH lookup, or logs.
class ProcessBridgeControl implements BridgeControl {
  ProcessBridgeControl._(this._process) {
    _stdout = _process.stdout.listen(
      _receive,
      onError: (_) => _fail('runtimeStopped'),
      onDone: () => _fail('runtimeStopped'),
    );
    _stderr = _process.stderr.listen((_) {});
    unawaited(_process.exitCode.then((_) => _fail('runtimeStopped')));
  }

  static Future<ProcessBridgeControl> start(String executablePath) async {
    if (!File(executablePath).isAbsolute) {
      throw const TailscaleException('invalidExecutable');
    }
    try {
      return ProcessBridgeControl._(
        await Process.start(
          executablePath,
          [],
          runInShell: false,
          mode: ProcessStartMode.normal,
        ),
      );
    } catch (_) {
      throw const TailscaleException('runtimeUnavailable');
    }
  }

  final Process _process;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _buffer = <int>[];
  Future<void> _writes = Future.value();
  late final StreamSubscription<List<int>> _stdout;
  late final StreamSubscription<List<int>> _stderr;
  int _nextId = 0;
  bool _closed = false;

  void _receive(List<int> chunk) {
    for (final byte in chunk) {
      if (byte == 10) {
        if (_buffer.isEmpty) continue;
        try {
          final message = utf8.decode(_buffer);
          _buffer.clear();
          final json = jsonDecode(message);
          if (json is! Map || json['id'] is! int) {
            _fail('invalidResponse');
            return;
          }
          final id = json['id'] as int;
          final completer = _pending.remove(id);
          if (completer == null) {
            _fail('invalidResponse');
            return;
          }
          try {
            completer.complete(decodeResponse(message, id));
          } catch (error, stack) {
            completer.completeError(error, stack);
          }
        } catch (_) {
          _fail('invalidResponse');
          return;
        }
      } else {
        if (_buffer.length >= maxControlBytes) {
          _fail('responseTooLarge');
          return;
        }
        _buffer.add(byte);
      }
    }
  }

  void _fail(String code) {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      completer.completeError(TailscaleException(code));
    }
    _pending.clear();
    _process.kill();
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (_closed) throw const TailscaleException('runtimeStopped');
    final id = ++_nextId;
    final message = jsonEncode({'id': id, 'method': method, 'params': params});
    if (utf8.encode(message).length > maxControlBytes) {
      throw const TailscaleException('requestTooLarge');
    }
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    // IOSink rejects writes while a flush is pending. Queue only the frames;
    // each caller still receives its own response by request ID.
    _writes = _writes.then((_) async {
      if (_closed) return;
      try {
        _process.stdin.writeln(message);
        await _process.stdin.flush();
      } catch (_) {
        _fail('runtimeStopped');
      }
    });
    return completer.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        // A timeout cannot safely leave an unobserved native resource alive.
        _fail('controlTimeout');
        throw const TailscaleException('controlTimeout');
      },
    );
  }

  @override
  Future<void> close() async {
    _fail('runtimeStopped');
    await _stdout.cancel();
    await _stderr.cancel();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
    await _writes;
    try {
      await _process.stdin.close();
    } catch (_) {}
  }
}

typedef _RequestNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _RequestDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

String _nativeRequest(String message) {
  try {
    final library = DynamicLibrary.open('libflutter_tailscale.so');
    final request = library.lookupFunction<_RequestNative, _RequestDart>(
      'ft_request',
    );
    final free = library.lookupFunction<_FreeNative, _FreeDart>('ft_free');
    final argument = message.toNativeUtf8();
    Pointer<Utf8> result = nullptr;
    try {
      result = request(argument);
      if (result == nullptr) throw const TailscaleException('nativeFailure');
      // Native ABI enforces the same frame bound before allocating a response.
      return result.toDartString();
    } finally {
      calloc.free(argument);
      if (result != nullptr) free(result);
    }
  } on TailscaleException {
    rethrow;
  } catch (_) {
    throw const TailscaleException('runtimeUnavailable');
  }
}

/// Blocking C calls run outside the UI isolate. Runtime ownership is native,
/// so separate Flutter engines attach to the same process-wide node.
class NativeBridgeControl implements BridgeControl {
  static const _platform = MethodChannel('dev.fluttertailscale/network');
  int _nextId = 0;
  bool _closed = false;
  String? _ownerId;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (_closed) throw const TailscaleException('runtimeStopped');
    final id = ++_nextId;
    final message = jsonEncode({'id': id, 'method': method, 'params': params});
    if (utf8.encode(message).length > maxControlBytes) {
      throw const TailscaleException('requestTooLarge');
    }
    final String response;
    if (method == 'initialize') {
      // Kotlin registers the owner before returning, or disposes it if its
      // Flutter engine detached during the native initialization call.
      final value = await _platform.invokeMethod<String>('initialize', message);
      if (value == null) throw const TailscaleException('runtimeUnavailable');
      response = value;
    } else {
      response = await Isolate.run(() => _nativeRequest(message));
    }
    final result = decodeResponse(response, id);
    if (method == 'initialize') _ownerId = requiredString(result, 'ownerId');
    return result;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final owner = _ownerId;
    _ownerId = null;
    if (owner != null) {
      // Safe even when TailscaleNode already disposed it. This also covers a
      // protocol handshake rejection before the node accepted its owner token.
      final message = jsonEncode({
        'id': ++_nextId,
        'method': 'dispose',
        'params': {'ownerId': owner},
      });
      try {
        await Isolate.run(() => _nativeRequest(message));
      } catch (_) {}
      try {
        await _platform.invokeMethod<void>('unregisterOwner', owner);
      } catch (_) {}
    }
  }
}
