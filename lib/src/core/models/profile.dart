import 'routing_preset.dart';
import 'runtime_mode.dart';
import 'vless_node.dart';

class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.node,
    this.routingPreset = RoutingPreset.cnDirect,
    this.runtimeMode = RuntimeMode.vpn,
    this.socksPort = 10808,
    this.httpPort = 10809,
    this.tunMtu = 1500,
  });

  final String id;
  final String name;
  final VlessNode node;
  final RoutingPreset routingPreset;
  final RuntimeMode runtimeMode;
  final int socksPort;
  final int httpPort;
  final int tunMtu;

  factory Profile.fromNode(
    VlessNode node, {
    RoutingPreset routingPreset = RoutingPreset.cnDirect,
    RuntimeMode runtimeMode = RuntimeMode.vpn,
  }) {
    final safeName = node.name.trim().isEmpty ? '${node.address}:${node.port}' : node.name.trim();
    return Profile(
      id: _slugify(safeName),
      name: safeName,
      node: node,
      routingPreset: routingPreset,
      runtimeMode: runtimeMode,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'routingPreset': routingPreset.name,
      'runtimeMode': runtimeMode.name,
      'socksPort': socksPort,
      'httpPort': httpPort,
      'tunMtu': tunMtu,
      'node': node.toJson(),
    };
  }

  static String _slugify(String value) {
    final normalized = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return normalized.replaceAll(RegExp(r'^-+|-+$'), '');
  }
}
