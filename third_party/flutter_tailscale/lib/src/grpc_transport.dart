import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';

import 'models.dart';
import 'transport.dart';

/// Internal adapter shared by the public channel and transport contract tests.
class BridgeGrpcConnector implements ClientTransportConnector {
  BridgeGrpcConnector(this.open, {required this.authority});
  final Future<BridgeConnection> Function() open;
  @override
  final String authority;
  BridgeConnection? _connection;
  bool _stopped = false;
  final _initialDone = Completer<void>();
  TailscaleException? lastConnectionFailure;

  @override
  Future<void> get done => _connection?.done ?? _initialDone.future;

  @override
  Future<ClientTransportConnection> connect() async {
    if (_stopped) throw const TailscaleException('connectionClosed');
    final BridgeConnection connection;
    try {
      connection = await open();
      lastConnectionFailure = null;
    } on TailscaleException catch (error) {
      lastConnectionFailure = error;
      rethrow;
    }
    if (_stopped) {
      await connection.close();
      throw const TailscaleException('connectionClosed');
    }
    _connection = connection;
    return ClientTransportConnection.viaStreams(
      connection.incoming,
      connection.outgoing,
    );
  }

  @override
  void shutdown() {
    _stopped = true;
    if (!_initialDone.isCompleted) _initialDone.complete();
    unawaited(_connection?.close());
  }
}
