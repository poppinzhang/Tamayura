enum NodeState {
  signedOut,
  authorizing,
  awaitingApproval,
  connected,
  connecting,
  stopped,
  error,
  unknown,
}

enum NodeControlState { unknown, connected, disconnected }

/// A candidate's authenticated identity, scoped to this embedded node's login.
/// Addresses and display names are deliberately excluded from identity.
class PeerRef {
  const PeerRef({required this.networkScope, required this.nodeId});
  final String networkScope;
  final String nodeId;

  factory PeerRef.fromJson(Map<String, dynamic> json) => PeerRef(
    networkScope: requiredString(json, 'networkScope'),
    nodeId: requiredString(json, 'nodeId'),
  );

  Map<String, Object> toJson() => {
    'networkScope': networkScope,
    'nodeId': nodeId,
  };

  @override
  bool operator ==(Object other) =>
      other is PeerRef &&
      other.networkScope == networkScope &&
      other.nodeId == nodeId;
  @override
  int get hashCode => Object.hash(networkScope, nodeId);
}

class TailscalePeer {
  const TailscalePeer({
    required this.ref,
    required this.name,
    required this.addresses,
    required this.online,
  });
  final PeerRef ref;
  final String name;
  final List<String> addresses;

  /// Control-plane presence; applications must probe their own service.
  final bool online;

  factory TailscalePeer.fromJson(Map<String, dynamic> json) => TailscalePeer(
    ref: PeerRef.fromJson(json),
    name: requiredString(json, 'name', allowEmpty: true),
    addresses: List.unmodifiable((json['addresses'] as List).cast<String>()),
    online: json['online'] == true,
  );
}

class NodeStatus {
  const NodeStatus({
    required this.sessionEpoch,
    required this.state,
    this.networkScope,
    this.selfNodeId,
    this.authUrl,
    this.controlState = NodeControlState.unknown,
  });
  final String sessionEpoch;
  final NodeState state;
  final String? networkScope;
  final String? selfNodeId;

  /// Control-plane health is independent of existing data-plane connections.
  final NodeControlState controlState;

  /// Sensitive, short-lived authentication URL. Never persist or log this.
  final Uri? authUrl;
  bool get registered =>
      (state == NodeState.connected || state == NodeState.connecting) &&
      (networkScope?.isNotEmpty ?? false);
  bool get signedIn => registered;

  factory NodeStatus.fromJson(Map<String, dynamic> json) {
    final state =
        NodeState.values.where((s) => s.name == json['state']).firstOrNull ??
        NodeState.unknown;
    final rawUrl = json['authUrl'];
    Uri? authUrl;
    if (rawUrl is String && rawUrl.isNotEmpty) {
      final uri = Uri.tryParse(rawUrl);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'login.tailscale.com' ||
          uri.userInfo.isNotEmpty ||
          (uri.hasPort && uri.port != 443)) {
        throw const TailscaleException('invalidAuthUrl');
      }
      authUrl = uri;
    }
    return NodeStatus(
      sessionEpoch: requiredString(json, 'sessionEpoch'),
      state: state,
      networkScope: json['networkScope'] as String?,
      selfNodeId: json['selfNodeId'] as String?,
      authUrl: authUrl,
      controlState:
          NodeControlState.values
              .where((value) => value.name == json['controlState'])
              .firstOrNull ??
          NodeControlState.unknown,
    );
  }
}

/// Stable, sanitized failure. Native details and credentials never appear here.
class TailscaleException implements Exception {
  const TailscaleException(this.code);
  final String code;
  @override
  String toString() => 'TailscaleException($code)';
}

String requiredString(
  Map<String, dynamic> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw const TailscaleException('invalidResponse');
  }
  return value;
}
