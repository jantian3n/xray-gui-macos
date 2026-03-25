import 'dart:async';
import 'dart:convert';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../models/runtime_traffic_snapshot.dart';
import 'session_draft_store.dart';

class MacosStatusBarController with TrayListener, WindowListener {
  MacosStatusBarController({
    required Future<void> Function(String nodeId) onSelectNode,
    required Future<void> Function() onQuitApp,
  })  : _onSelectNode = onSelectNode,
        _onQuitApp = onQuitApp;

  static const String _trayIconAssetPath =
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png';

  final Future<void> Function(String nodeId) _onSelectNode;
  final Future<void> Function() _onQuitApp;

  bool _initialized = false;
  bool _terminating = false;
  bool _syncInFlight = false;
  _StatusBarSyncRequest? _pendingSyncRequest;
  String? _lastAppliedTitle;
  String? _lastAppliedToolTip;
  String? _lastAppliedMenuSignature;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    trayManager.addListener(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await trayManager.setIcon(
      _trayIconAssetPath,
      iconSize: 16,
    );
    await trayManager.setToolTip('Xray GUI');
    _initialized = true;
  }

  Future<void> sync({
    required List<StoredNodeDraft> nodes,
    required String? selectedNodeId,
    required String status,
    required RuntimeTrafficSnapshot traffic,
    required bool canSwitchNodes,
  }) async {
    if (!_initialized || _terminating) {
      return;
    }

    _pendingSyncRequest = _StatusBarSyncRequest(
      nodes: List<StoredNodeDraft>.unmodifiable(nodes),
      selectedNodeId: selectedNodeId,
      status: status,
      traffic: traffic,
      canSwitchNodes: canSwitchNodes,
    );
    await _drainPendingSyncRequests();
  }

  Future<void> showApp() async {
    if (_terminating) {
      return;
    }

    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> terminateApp() async {
    if (_terminating) {
      return;
    }

    _terminating = true;
    _pendingSyncRequest = null;
    try {
      await trayManager.destroy();
    } on Object {
      // Ignore tray teardown failures during shutdown.
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  Future<void> dispose() async {
    if (!_initialized) {
      return;
    }

    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _initialized = false;
  }

  Future<void> _drainPendingSyncRequests() async {
    if (_syncInFlight || _terminating) {
      return;
    }

    _syncInFlight = true;
    try {
      while (!_terminating) {
        final _StatusBarSyncRequest? request = _pendingSyncRequest;
        _pendingSyncRequest = null;
        if (request == null) {
          break;
        }
        await _applySyncRequest(request);
      }
    } finally {
      _syncInFlight = false;
      if (_pendingSyncRequest != null && !_terminating) {
        unawaited(_drainPendingSyncRequests());
      }
    }
  }

  Future<void> _applySyncRequest(_StatusBarSyncRequest request) async {
    final String title = _buildTitle(request.status, request.traffic);
    if (title != _lastAppliedTitle) {
      await trayManager.setTitle(title);
      _lastAppliedTitle = title;
    }

    final String toolTip = _buildToolTip(
      nodes: request.nodes,
      selectedNodeId: request.selectedNodeId,
      status: request.status,
      traffic: request.traffic,
    );
    if (toolTip != _lastAppliedToolTip) {
      await trayManager.setToolTip(toolTip);
      _lastAppliedToolTip = toolTip;
    }

    final String menuSignature = _buildMenuSignature(
      nodes: request.nodes,
      selectedNodeId: request.selectedNodeId,
      canSwitchNodes: request.canSwitchNodes,
    );
    if (menuSignature != _lastAppliedMenuSignature) {
      await trayManager.setContextMenu(
        _buildMenu(
          nodes: request.nodes,
          selectedNodeId: request.selectedNodeId,
          canSwitchNodes: request.canSwitchNodes,
        ),
      );
      _lastAppliedMenuSignature = menuSignature;
    }
  }

  Menu _buildMenu({
    required List<StoredNodeDraft> nodes,
    required String? selectedNodeId,
    required bool canSwitchNodes,
  }) {
    return Menu(
      items: <MenuItem>[
        MenuItem(
          key: 'open-app',
          label: '打开软件',
          onClick: (_) {
            unawaited(showApp());
          },
        ),
        if (nodes.length > 1)
          MenuItem.submenu(
            key: 'switch-node',
            label: '切换节点',
            disabled: !canSwitchNodes,
            submenu: Menu(
              items: nodes.map((StoredNodeDraft draft) {
                return MenuItem.checkbox(
                  key: 'node-${draft.id}',
                  label: _draftLabel(draft),
                  checked: draft.id == selectedNodeId,
                  onClick: (_) {
                    unawaited(_onSelectNode(draft.id));
                  },
                );
              }).toList(growable: false),
            ),
          ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit-app',
          label: '退出软件',
          onClick: (_) {
            unawaited(_onQuitApp());
          },
        ),
      ],
    );
  }

  String _buildTitle(String status, RuntimeTrafficSnapshot traffic) {
    if (status == 'running') {
      return '↑ ${_formatRate(traffic.uploadBytesPerSecond)} '
          '↓ ${_formatRate(traffic.downloadBytesPerSecond)}';
    }
    if (status == 'starting') {
      return '连接中';
    }
    if (status == 'stopping') {
      return '停止中';
    }
    return '未连接';
  }

  String _buildToolTip({
    required List<StoredNodeDraft> nodes,
    required String? selectedNodeId,
    required String status,
    required RuntimeTrafficSnapshot traffic,
  }) {
    final StoredNodeDraft? selectedNode = nodes
        .where((StoredNodeDraft draft) => draft.id == selectedNodeId)
        .firstOrNull;
    final String nodeLabel =
        selectedNode == null ? '未选择节点' : _draftLabel(selectedNode);
    final String speedLabel =
        '上传 ${_formatRate(traffic.uploadBytesPerSecond)} / '
        '下载 ${_formatRate(traffic.downloadBytesPerSecond)}';
    return 'Xray GUI\n状态: ${_statusLabel(status)}\n节点: $nodeLabel\n$speedLabel';
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'running':
        return '运行中';
      case 'starting':
        return '连接中';
      case 'stopping':
        return '停止中';
      case 'profile-ready':
        return '已就绪';
      case 'error':
        return '错误';
      default:
        return '未连接';
    }
  }

  String _draftLabel(StoredNodeDraft draft) {
    final String name = draft.node.name.trim();
    if (name.isNotEmpty) {
      return name;
    }
    return '${draft.node.address}:${draft.node.port}';
  }

  String _buildMenuSignature({
    required List<StoredNodeDraft> nodes,
    required String? selectedNodeId,
    required bool canSwitchNodes,
  }) {
    return jsonEncode(<String, dynamic>{
      'selectedNodeId': selectedNodeId,
      'canSwitchNodes': canSwitchNodes,
      'nodes': nodes
          .map((StoredNodeDraft draft) => <String, dynamic>{
                'id': draft.id,
                'label': _draftLabel(draft),
              })
          .toList(growable: false),
    });
  }

  String _formatRate(int bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond}B/s';
    }

    final double kilobytes = bytesPerSecond / 1024;
    if (kilobytes < 1024) {
      if (kilobytes >= 100) {
        return '${kilobytes.round()}KB/s';
      }
      return '${kilobytes.toStringAsFixed(kilobytes >= 10 ? 1 : 2)}KB/s';
    }

    final double megabytes = kilobytes / 1024;
    if (megabytes >= 100) {
      return '${megabytes.round()}MB/s';
    }
    return '${megabytes.toStringAsFixed(megabytes >= 10 ? 1 : 2)}MB/s';
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showApp());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onWindowClose() {
    if (_terminating) {
      return;
    }
    unawaited(windowManager.hide());
  }
}

extension on Iterable<StoredNodeDraft> {
  StoredNodeDraft? get firstOrNull {
    final Iterator<StoredNodeDraft> iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}

class _StatusBarSyncRequest {
  const _StatusBarSyncRequest({
    required this.nodes,
    required this.selectedNodeId,
    required this.status,
    required this.traffic,
    required this.canSwitchNodes,
  });

  final List<StoredNodeDraft> nodes;
  final String? selectedNodeId;
  final String status;
  final RuntimeTrafficSnapshot traffic;
  final bool canSwitchNodes;
}
