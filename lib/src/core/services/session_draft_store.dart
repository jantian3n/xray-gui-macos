import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/routing_preset.dart';
import '../models/runtime_mode.dart';
import '../models/vless_node.dart';
import 'vless_uri_parser.dart';

class StoredNodeDraft {
  const StoredNodeDraft({
    required this.id,
    required this.node,
    required this.routingPreset,
    required this.runtimeMode,
  });

  final String id;
  final VlessNode node;
  final RoutingPreset routingPreset;
  final RuntimeMode runtimeMode;

  StoredNodeDraft copyWith({
    String? id,
    VlessNode? node,
    RoutingPreset? routingPreset,
    RuntimeMode? runtimeMode,
  }) {
    return StoredNodeDraft(
      id: id ?? this.id,
      node: node ?? this.node,
      routingPreset: routingPreset ?? this.routingPreset,
      runtimeMode: runtimeMode ?? this.runtimeMode,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'node': node.toJson(),
      'routingPreset': routingPreset.name,
      'runtimeMode': runtimeMode.name,
    };
  }

  factory StoredNodeDraft.fromJson(Map<String, dynamic> json) {
    final VlessUriParser parser = VlessUriParser();
    final VlessNode node;

    if (json['node'] is Map) {
      node = VlessNode.fromJson(
        Map<String, dynamic>.from(json['node'] as Map<dynamic, dynamic>),
      );
    } else {
      final String legacyLink = json['link'] as String? ?? '';
      node = parser.parse(legacyLink);
    }

    return StoredNodeDraft(
      id: json['id'] as String? ?? '',
      node: node,
      routingPreset: _parseRoutingPreset(json['routingPreset'] as String?),
      runtimeMode: _parseRuntimeMode(json['runtimeMode'] as String?),
    );
  }
}

class StoredNodeCollection {
  const StoredNodeCollection({
    required this.nodes,
    required this.selectedNodeId,
  });

  final List<StoredNodeDraft> nodes;
  final String? selectedNodeId;

  StoredNodeDraft? get selectedNode {
    if (selectedNodeId == null) {
      return null;
    }

    for (final StoredNodeDraft node in nodes) {
      if (node.id == selectedNodeId) {
        return node;
      }
    }

    return null;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'selectedNodeId': selectedNodeId,
      'nodes': nodes.map((StoredNodeDraft node) => node.toJson()).toList(),
    };
  }
}

class SessionDraftStore {
  static const String _snapshotKey = 'node_list.snapshot.v1';
  static const String _legacyLinkKey = 'session_draft.link';
  static const String _legacyRoutingPresetKey = 'session_draft.routing_preset';
  static const String _legacyRuntimeModeKey = 'session_draft.runtime_mode';

  Future<StoredNodeCollection> load() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? snapshotJson = preferences.getString(_snapshotKey);

    if (snapshotJson != null && snapshotJson.trim().isNotEmpty) {
      try {
        final Map<String, dynamic> json = Map<String, dynamic>.from(
          jsonDecode(snapshotJson) as Map<dynamic, dynamic>,
        );
        final List<dynamic> rawNodes =
            json['nodes'] as List<dynamic>? ?? <dynamic>[];
        final List<StoredNodeDraft> nodes = rawNodes
            .map(
              (dynamic item) => StoredNodeDraft.fromJson(
                Map<String, dynamic>.from(item as Map<dynamic, dynamic>),
              ),
            )
            .where((StoredNodeDraft node) =>
                node.id.isNotEmpty &&
                node.node.address.trim().isNotEmpty &&
                node.node.id.trim().isNotEmpty)
            .toList();

        final String? selectedNodeId = json['selectedNodeId'] as String?;
        return StoredNodeCollection(
          nodes: nodes,
          selectedNodeId:
              nodes.any((StoredNodeDraft node) => node.id == selectedNodeId)
                  ? selectedNodeId
                  : (nodes.isNotEmpty ? nodes.first.id : null),
        );
      } catch (_) {
        await preferences.remove(_snapshotKey);
      }
    }

    final StoredNodeCollection? migrated =
        await _migrateLegacyDraft(preferences);
    return migrated ??
        const StoredNodeCollection(
          nodes: <StoredNodeDraft>[],
          selectedNodeId: null,
        );
  }

  Future<void> save(StoredNodeCollection collection) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();

    if (collection.nodes.isEmpty) {
      await preferences.remove(_snapshotKey);
      return;
    }

    await preferences.setString(_snapshotKey, jsonEncode(collection.toJson()));
  }

  Future<void> clear() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.remove(_snapshotKey);
    await preferences.remove(_legacyLinkKey);
    await preferences.remove(_legacyRoutingPresetKey);
    await preferences.remove(_legacyRuntimeModeKey);
  }

  Future<StoredNodeCollection?> _migrateLegacyDraft(
    SharedPreferences preferences,
  ) async {
    final String link = preferences.getString(_legacyLinkKey)?.trim() ?? '';
    if (link.isEmpty) {
      return null;
    }

    final VlessUriParser parser = VlessUriParser();

    final StoredNodeDraft migratedNode = StoredNodeDraft(
      id: 'legacy-${DateTime.now().microsecondsSinceEpoch}',
      node: parser.parse(link),
      routingPreset: _parseRoutingPreset(
        preferences.getString(_legacyRoutingPresetKey),
      ),
      runtimeMode: _parseRuntimeMode(
        preferences.getString(_legacyRuntimeModeKey),
      ),
    );

    final StoredNodeCollection collection = StoredNodeCollection(
      nodes: <StoredNodeDraft>[migratedNode],
      selectedNodeId: migratedNode.id,
    );

    await save(collection);
    await preferences.remove(_legacyLinkKey);
    await preferences.remove(_legacyRoutingPresetKey);
    await preferences.remove(_legacyRuntimeModeKey);
    return collection;
  }
}

RoutingPreset _parseRoutingPreset(String? value) {
  return RoutingPreset.values.firstWhere(
    (RoutingPreset preset) => preset.name == value,
    orElse: () => RoutingPreset.cnDirect,
  );
}

RuntimeMode _parseRuntimeMode(String? value) {
  return RuntimeMode.values.firstWhere(
    (RuntimeMode mode) => mode.name == value,
    orElse: () => RuntimeMode.vpn,
  );
}
