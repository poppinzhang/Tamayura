import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:path/path.dart' as p;

import '../data/platform_database.dart';

/// Foreground and Android headless engines attach to the same private node.
/// The SDK owns the native owner leases; closing a worker does not log out an
/// active foreground engine. State is durable app data, never download cache.
Future<TailscaleNode> openTamayuraTailscaleNode(String deviceId) async {
  final factory = await platformDatabaseFactory();
  return TailscaleNode.open(
    stateDirectory: p.join(await factory.getDatabasesPath(), 'tailscale-node'),
    hostname: 'tamayura',
  );
}
