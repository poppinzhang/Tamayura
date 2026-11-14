import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';

import 'flutter_tailscale.dart';
import 'src/grpc_transport.dart';

/// HTTP/2 begins only after the SDK completes pinned TLS and CONNECT.
/// This adapter uses Tailscale transport encryption. It does not add a second
/// end-to-end application TLS layer or accept application TLS credentials.
class TailscaleChannel extends ClientTransportConnectorChannel {
  factory TailscaleChannel(
    TailscaleNode node,
    PeerRef peer, {
    required int port,
  }) => TailscaleChannel._(
    BridgeGrpcConnector(
      () => node.openTcp(peer, port: port),
      authority: 'tailscale:$port',
    ),
  );

  TailscaleChannel._(this._connector)
    : super(
        _connector,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );

  final BridgeGrpcConnector _connector;

  /// gRPC 4 wraps connector errors as UNAVAILABLE. Consumers can inspect this
  /// typed cause to avoid retrying a verified identity or authorization failure.
  /// It is cleared after a successful new connection.
  TailscaleException? get lastConnectionFailure =>
      _connector.lastConnectionFailure;
}

Future<void> serveGrpcConnection(Server server, BridgeConnection connection) =>
    server.serveConnection(
      connection: ServerTransportConnection.viaStreams(
        connection.incoming,
        connection.outgoing,
      ),
    );
