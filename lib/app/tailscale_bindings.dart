import 'dart:convert';

import 'package:flutter_tailscale/flutter_tailscale.dart';

/// User-approved association, scoped to a tailnet and a stable node identity.
/// Addresses and control-plane online flags are deliberately not persisted.
class TailscaleBinding {
  const TailscaleBinding({
    required this.deviceId,
    required this.name,
    required this.ref,
  });

  final String deviceId;
  final String name;
  final PeerRef ref;

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'networkScope': ref.networkScope,
    'nodeId': ref.nodeId,
  };
}

/// Versioned independently of SQLite's unchanged v7 schema. Unknown or corrupt
/// configuration is rejected and retained; it is never silently overwritten.
class TailscaleBindings {
  static const settingKey = 'tailscale_bindings_v1';
  static const enabledKey = 'tailscale_enabled_v1';

  static List<TailscaleBinding> decode(String? value) {
    if (value == null) return [];
    final decoded = jsonDecode(value);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['bindings'] is! List) {
      throw const FormatException(
        'Unsupported Tailscale binding configuration',
      );
    }
    final result = <TailscaleBinding>[];
    final devices = <String>{};
    final nodes = <String>{};
    for (final entry in decoded['bindings'] as List) {
      if (entry is! Map) {
        throw const FormatException('Invalid Tailscale binding configuration');
      }
      String read(String key) {
        final value = entry[key];
        if (value is! String ||
            value.isEmpty ||
            value.length > 1024 ||
            value.contains('\u0000')) {
          throw const FormatException(
            'Invalid Tailscale binding configuration',
          );
        }
        return value;
      }

      final binding = TailscaleBinding(
        deviceId: read('deviceId'),
        name: read('name'),
        ref: PeerRef(
          networkScope: read('networkScope'),
          nodeId: read('nodeId'),
        ),
      );
      final scope = binding.ref.networkScope;
      if (!devices.add(jsonEncode([scope, binding.deviceId])) ||
          !nodes.add(jsonEncode([scope, binding.ref.nodeId]))) {
        throw const FormatException(
          'Conflicting Tailscale binding configuration',
        );
      }
      result.add(binding);
    }
    return result;
  }

  static String encode(Iterable<TailscaleBinding> bindings) => jsonEncode({
    'version': 1,
    'bindings': bindings.map((entry) => entry.toJson()).toList(),
  });
}
