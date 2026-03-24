import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/profile.dart';
import '../../../core/models/routing_preset.dart';
import '../../../core/models/runtime_mode.dart';
import '../../../core/models/vless_node.dart';
import '../../../core/models/xhttp_download_settings.dart';
import '../../../core/services/node_importer.dart';
import '../../../core/services/runtime_bridge.dart';
import '../../../core/services/runtime_bridge_factory.dart';
import '../../../core/services/session_draft_store.dart';
import '../../../core/services/xray_config_compiler.dart';

enum _ImportAction { clipboard, clipboardPatch, manual }

enum _NodeItemAction { edit, delete }

enum _HomeTab { connection, nodes, routing, logs }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final NodeImporter _nodeImporter = NodeImporter();
  final XrayConfigCompiler _compiler = XrayConfigCompiler();
  final SessionDraftStore _draftStore = SessionDraftStore();
  final JsonEncoder _encoder = const JsonEncoder.withIndent('  ');

  late final RuntimeBridge _runtimeBridge;
  List<StoredNodeDraft> _savedNodes = <StoredNodeDraft>[];
  String? _selectedNodeId;
  int _selectedTabIndex = 0;
  RoutingPreset _routingPreset = RoutingPreset.cnDirect;
  late RuntimeMode _runtimeMode;
  Profile? _profile;
  String _configPreview = '';
  String _status = 'idle';
  final List<String> _logLines = <String>[];
  StreamSubscription<String>? _logSubscription;

  StoredNodeDraft? get _selectedDraft =>
      _nodeById(_selectedNodeId, _savedNodes);

  bool get _hasSelection => _selectedDraft != null;

  bool get _isRuntimeLocked => const <String>{
        'starting',
        'stopping',
        'running',
        'running-dry',
      }.contains(_status);

  @override
  void initState() {
    super.initState();
    _runtimeBridge = createRuntimeBridge();
    _runtimeMode = _defaultRuntimeMode();
    _logSubscription = _runtimeBridge.logs().listen(
      (String line) {
        if (!mounted) {
          return;
        }
        final String? state = _extractStateFromLogLine(line);
        setState(() {
          _logLines.insert(0, line);
          if (_logLines.length > 200) {
            _logLines.removeRange(200, _logLines.length);
          }
          if (state != null) {
            _status = state;
          }
        });
      },
      onError: (Object error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _logLines.insert(0, 'log-stream-error: $error');
        });
      },
    );
    _initializeRuntimeBridge();
    _restoreNodeCollection();
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    super.dispose();
  }

  Future<void> _restoreNodeCollection() async {
    final StoredNodeCollection collection = await _draftStore.load();
    if (!mounted) {
      return;
    }

    await _commitCollection(
      nodes: _normalizeNodes(collection.nodes),
      selectedNodeId: collection.selectedNodeId,
      successStatus: 'profile-ready',
      showSnackOnError: false,
    );
  }

  Future<void> _initializeRuntimeBridge() async {
    try {
      await _runtimeBridge.initialize();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _logLines.insert(0, 'runtime-init-error: $error');
      });
    }
  }

  RuntimeMode _defaultRuntimeMode() {
    return _runtimeBridge.normalizeRuntimeMode(RuntimeMode.vpn);
  }

  List<StoredNodeDraft> _normalizeNodes(List<StoredNodeDraft> nodes) {
    return nodes.map((StoredNodeDraft draft) {
      final RuntimeMode normalizedMode =
          _runtimeBridge.normalizeRuntimeMode(draft.runtimeMode);
      if (normalizedMode == draft.runtimeMode) {
        return draft;
      }
      return draft.copyWith(runtimeMode: normalizedMode);
    }).toList(growable: false);
  }

  Profile _buildProfileFromDraft(StoredNodeDraft draft) {
    return Profile.fromNode(
      draft.node,
      routingPreset: draft.routingPreset,
      runtimeMode: draft.runtimeMode,
    );
  }

  _CompiledDraft _compileDraft(StoredNodeDraft draft) {
    final Profile profile = _buildProfileFromDraft(draft);
    final Map<String, dynamic> config = _compiler.compile(profile);
    return _CompiledDraft(
      profile: profile,
      config: config,
      configPreview: _encoder.convert(config),
    );
  }

  StoredNodeDraft? _nodeById(String? nodeId, List<StoredNodeDraft> nodes) {
    if (nodeId == null) {
      return null;
    }

    for (final StoredNodeDraft node in nodes) {
      if (node.id == nodeId) {
        return node;
      }
    }

    return null;
  }

  Future<void> _commitCollection({
    required List<StoredNodeDraft> nodes,
    required String? selectedNodeId,
    required String successStatus,
    required bool showSnackOnError,
  }) async {
    final List<StoredNodeDraft> normalizedNodes = _normalizeNodes(nodes);
    final StoredNodeDraft? selectedDraft = _nodeById(
      selectedNodeId,
      normalizedNodes,
    );

    if (selectedDraft == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _savedNodes = normalizedNodes;
        _selectedNodeId = null;
        _routingPreset = RoutingPreset.cnDirect;
        _runtimeMode = _defaultRuntimeMode();
        _profile = null;
        _configPreview = '';
        _status = 'idle';
      });
      await _persistNodes(nodes: normalizedNodes, selectedNodeId: null);
      return;
    }

    try {
      final _CompiledDraft compiled = _compileDraft(selectedDraft);
      if (!mounted) {
        return;
      }
      setState(() {
        _savedNodes = normalizedNodes;
        _selectedNodeId = selectedDraft.id;
        _routingPreset = selectedDraft.routingPreset;
        _runtimeMode = selectedDraft.runtimeMode;
        _profile = compiled.profile;
        _configPreview = compiled.configPreview;
        _status = successStatus;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _savedNodes = normalizedNodes;
        _selectedNodeId = selectedDraft.id;
        _routingPreset = selectedDraft.routingPreset;
        _runtimeMode = selectedDraft.runtimeMode;
        _profile = null;
        _configPreview = '';
        _status = 'error';
      });
      if (showSnackOnError) {
        _showSnackBar(error.toString());
      }
    }

    await _persistNodes(
      nodes: normalizedNodes,
      selectedNodeId: selectedDraft.id,
    );
  }

  Future<void> _persistNodes({
    required List<StoredNodeDraft> nodes,
    required String? selectedNodeId,
  }) async {
    await _draftStore.save(
      StoredNodeCollection(nodes: nodes, selectedNodeId: selectedNodeId),
    );
  }

  StoredNodeDraft _createDraft(VlessNode node, {StoredNodeDraft? base}) {
    if (node.address.trim().isEmpty) {
      throw StateError('请先填写服务器地址。');
    }
    if (node.id.trim().isEmpty) {
      throw StateError('请先填写 UUID。');
    }

    return StoredNodeDraft(
      id: base?.id ?? 'node-${DateTime.now().microsecondsSinceEpoch}',
      node: node,
      routingPreset: base?.routingPreset ?? _routingPreset,
      runtimeMode: base?.runtimeMode ?? _runtimeMode,
    );
  }

  Future<void> _addNodeFromRaw(String raw) async {
    if (_isRuntimeLocked) {
      _showSnackBar('运行中请先停止连接，再导入新节点。');
      return;
    }

    try {
      final VlessNode node = _nodeImporter.parseNode(raw);
      final StoredNodeDraft draft = _createDraft(node);
      final List<StoredNodeDraft> nodes = <StoredNodeDraft>[
        draft,
        ..._savedNodes,
      ];

      await _commitCollection(
        nodes: nodes,
        selectedNodeId: draft.id,
        successStatus: 'profile-ready',
        showSnackOnError: true,
      );
      _showSnackBar('节点已导入并设为当前节点。');
    } catch (error) {
      _showSnackBar(error.toString());
    }
  }

  Future<void> _editNode(StoredNodeDraft draft) async {
    if (_isRuntimeLocked) {
      _showSnackBar('运行中请先停止连接，再编辑节点。');
      return;
    }

    final VlessNode? result = await _openNodeEditorSheet(
      title: '编辑节点',
      actionLabel: '保存修改',
      initialNode: draft.node,
    );
    if (!mounted || result == null) {
      return;
    }

    try {
      final StoredNodeDraft updatedDraft = _createDraft(result, base: draft);
      final List<StoredNodeDraft> nodes = _savedNodes
          .map(
            (StoredNodeDraft node) => node.id == draft.id ? updatedDraft : node,
          )
          .toList();

      await _commitCollection(
        nodes: nodes,
        selectedNodeId: updatedDraft.id,
        successStatus: 'profile-ready',
        showSnackOnError: true,
      );
      _showSnackBar('节点已更新。');
    } catch (error) {
      _showSnackBar(error.toString());
    }
  }

  Future<void> _deleteNode(StoredNodeDraft draft) async {
    if (_isRuntimeLocked) {
      _showSnackBar('运行中请先停止连接，再删除节点。');
      return;
    }

    final List<StoredNodeDraft> nodes = _savedNodes
        .where((StoredNodeDraft node) => node.id != draft.id)
        .toList();

    final String? nextSelectedNodeId = draft.id == _selectedNodeId
        ? (nodes.isNotEmpty ? nodes.first.id : null)
        : _selectedNodeId;

    await _commitCollection(
      nodes: nodes,
      selectedNodeId: nextSelectedNodeId,
      successStatus: 'profile-ready',
      showSnackOnError: true,
    );
    _showSnackBar('节点已删除。');
  }

  Future<void> _selectNode(StoredNodeDraft draft) async {
    if (_isRuntimeLocked) {
      if (draft.id != _selectedNodeId) {
        _showSnackBar('运行中请先停止连接，再切换节点。');
      }
      return;
    }

    await _commitCollection(
      nodes: _savedNodes,
      selectedNodeId: draft.id,
      successStatus: 'profile-ready',
      showSnackOnError: true,
    );
  }

  Future<void> _updateSelectedRoutingPreset(RoutingPreset preset) async {
    final StoredNodeDraft? selectedDraft = _selectedDraft;
    if (selectedDraft == null || _isRuntimeLocked) {
      return;
    }

    final StoredNodeDraft updatedDraft = selectedDraft.copyWith(
      routingPreset: preset,
    );
    final List<StoredNodeDraft> nodes = _savedNodes
        .map(
          (StoredNodeDraft node) =>
              node.id == updatedDraft.id ? updatedDraft : node,
        )
        .toList();

    await _commitCollection(
      nodes: nodes,
      selectedNodeId: updatedDraft.id,
      successStatus: 'profile-ready',
      showSnackOnError: true,
    );
  }

  Future<void> _updateSelectedRuntimeMode(RuntimeMode mode) async {
    final StoredNodeDraft? selectedDraft = _selectedDraft;
    if (selectedDraft == null || _isRuntimeLocked) {
      return;
    }

    final StoredNodeDraft updatedDraft = selectedDraft.copyWith(
      runtimeMode: mode,
    );
    final List<StoredNodeDraft> nodes = _savedNodes
        .map(
          (StoredNodeDraft node) =>
              node.id == updatedDraft.id ? updatedDraft : node,
        )
        .toList();

    await _commitCollection(
      nodes: nodes,
      selectedNodeId: updatedDraft.id,
      successStatus: 'profile-ready',
      showSnackOnError: true,
    );
  }

  Future<void> _importFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showSnackBar('剪贴板里没有可用的节点内容。');
      return;
    }

    await _addNodeFromRaw(text);
  }

  Future<void> _applyPatchFromClipboard() async {
    final StoredNodeDraft? draft = _selectedDraft;
    if (draft == null) {
      _showSnackBar('请先选中一个节点，再应用 split patch。');
      return;
    }
    if (_isRuntimeLocked) {
      _showSnackBar('运行中请先停止连接，再应用补丁。');
      return;
    }

    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showSnackBar('剪贴板里没有可用的补丁内容。');
      return;
    }

    try {
      final VlessNode updatedNode = _nodeImporter.applyPatch(draft.node, text);
      final StoredNodeDraft updatedDraft = _createDraft(
        updatedNode,
        base: draft,
      );
      final List<StoredNodeDraft> nodes = _savedNodes
          .map(
            (StoredNodeDraft node) => node.id == draft.id ? updatedDraft : node,
          )
          .toList();

      await _commitCollection(
        nodes: nodes,
        selectedNodeId: updatedDraft.id,
        successStatus: 'profile-ready',
        showSnackOnError: true,
      );
      _showSnackBar('split patch 已应用到当前节点。');
    } catch (error) {
      _showSnackBar(error.toString());
    }
  }

  Future<VlessNode?> _openNodeEditorSheet({
    required String title,
    required String actionLabel,
    VlessNode? initialNode,
  }) async {
    return showModalBottomSheet<VlessNode>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (BuildContext context) {
        return _NodeEditorSheet(
          title: title,
          actionLabel: actionLabel,
          initialNode: initialNode,
        );
      },
    );
  }

  Future<void> _handleImportAction(_ImportAction action) async {
    switch (action) {
      case _ImportAction.clipboard:
        await _importFromClipboard();
        break;
      case _ImportAction.clipboardPatch:
        await _applyPatchFromClipboard();
        break;
      case _ImportAction.manual:
        final VlessNode? result = await _openNodeEditorSheet(
          title: '添加节点',
          actionLabel: '保存并导入',
        );
        if (!mounted || result == null) {
          return;
        }
        if (_isRuntimeLocked) {
          _showSnackBar('运行中请先停止连接，再导入新节点。');
          return;
        }
        try {
          final StoredNodeDraft draft = _createDraft(result);
          final List<StoredNodeDraft> nodes = <StoredNodeDraft>[
            draft,
            ..._savedNodes,
          ];

          await _commitCollection(
            nodes: nodes,
            selectedNodeId: draft.id,
            successStatus: 'profile-ready',
            showSnackOnError: true,
          );
          _showSnackBar('节点已导入并设为当前节点。');
        } catch (error) {
          _showSnackBar(error.toString());
        }
        break;
    }
  }

  Future<void> _startRuntime() async {
    final StoredNodeDraft? selectedDraft = _selectedDraft;
    if (selectedDraft == null) {
      _showSnackBar('请先选择一个节点。');
      return;
    }

    try {
      final _CompiledDraft compiled = _compileDraft(selectedDraft);

      if (compiled.profile.runtimeMode == RuntimeMode.vpn) {
        await _runtimeBridge.requestVpnPermission();
      }

      await _runtimeBridge.start(compiled.profile, compiled.config);
      setState(() {
        _profile = compiled.profile;
        _configPreview = compiled.configPreview;
        _status = 'starting';
      });
    } on MissingPluginException {
      _showSnackBar('macOS runtime bridge 还没有接入完成。');
    } catch (error) {
      _showSnackBar(error.toString());
    }
  }

  Future<void> _stopRuntime() async {
    try {
      await _runtimeBridge.stop();
      setState(() {
        _status = 'stopping';
      });
    } on MissingPluginException {
      _showSnackBar('macOS runtime bridge 还没有接入完成。');
    } catch (error) {
      _showSnackBar(error.toString());
    }
  }

  Future<void> _updateGeoData() async {
    try {
      await _runtimeBridge.updateGeoData();
      _showSnackBar('已请求更新 geodata。');
    } on MissingPluginException {
      _showSnackBar('macOS runtime bridge 还没有接入完成。');
    } catch (error) {
      _showSnackBar(error.toString());
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String? _extractStateFromLogLine(String line) {
    const String prefix = 'state=';
    if (!line.startsWith(prefix)) {
      return null;
    }

    final String value = line.substring(prefix.length).trim();
    if (value.isEmpty) {
      return null;
    }

    return value;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VlessNode? node = _profile?.node ?? _selectedDraft?.node;
    final _HomeTab currentTab = _HomeTab.values[_selectedTabIndex];

    return Scaffold(
      appBar: AppBar(title: Text(_tabTitle(currentTab))),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _selectedTabIndex = index;
          });
        },
        destinations: const <Widget>[
          NavigationDestination(
            selectedIcon: Icon(Icons.shield),
            icon: Icon(Icons.shield_outlined),
            label: '连接',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.hub),
            icon: Icon(Icons.hub_outlined),
            label: '节点',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.tune),
            icon: Icon(Icons.tune_outlined),
            label: '规则',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.receipt_long),
            icon: Icon(Icons.receipt_long_outlined),
            label: '日志',
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: ListView(
            key: ValueKey<_HomeTab>(currentTab),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: _buildTabChildren(currentTab, theme, node),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTabChildren(
    _HomeTab tab,
    ThemeData theme,
    VlessNode? node,
  ) {
    switch (tab) {
      case _HomeTab.connection:
        return <Widget>[
          _buildOverviewCard(theme, node),
          const SizedBox(height: 12),
          _buildCurrentNodeCard(theme),
          const SizedBox(height: 12),
          _buildActionsCard(),
        ];
      case _HomeTab.nodes:
        return <Widget>[_buildNodeListCard(theme)];
      case _HomeTab.routing:
        return <Widget>[
          _buildPreferencesCard(theme),
          const SizedBox(height: 12),
          _buildGeoDataCard(theme),
          const SizedBox(height: 12),
          _buildExpandablePanel(
            context: context,
            icon: Icons.code_outlined,
            title: '配置预览',
            subtitle: _configPreview.isEmpty
                ? '选择节点后查看生成的 Xray JSON'
                : '当前预览长度 ${_configPreview.length} 字符',
            content: _configPreview.isEmpty
                ? '还没有可预览的配置。先导入节点，再选择分流策略和运行模式。'
                : _configPreview,
          ),
        ];
      case _HomeTab.logs:
        return <Widget>[
          _buildOverviewCard(theme, node),
          const SizedBox(height: 12),
          _buildExpandablePanel(
            context: context,
            icon: Icons.receipt_long_outlined,
            title: '运行日志',
            subtitle: _logLines.isEmpty
                ? '启动后日志会显示在这里'
                : '已缓存 ${_logLines.length} 条日志',
            content: _logLines.isEmpty
                ? '启动 macOS runtime 后，日志会实时显示在这里。'
                : _logLines.join('\n'),
          ),
        ];
    }
  }

  Widget _buildOverviewCard(ThemeData theme, VlessNode? node) {
    final ColorScheme colors = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('连接概览', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '面向 macOS 的 Xray 控制面板，支持单机 XHTTP、分离上下行 XHTTP，以及脚本导出的 REALITY/TLS 模式。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _StatusChip(
                  label: _statusLabel(_status),
                  color: _statusColor(colors, _status),
                ),
                _InfoChip(
                  icon: Icons.dns_outlined,
                  label: '${_savedNodes.length} 个节点',
                ),
                if (_hasSelection)
                  _InfoChip(
                    icon: Icons.alt_route_outlined,
                    label: _routingPreset.label,
                  ),
                if (_hasSelection)
                  _InfoChip(
                    icon: Icons.settings_ethernet_outlined,
                    label: _runtimeMode.label,
                  ),
                if (node != null)
                  _InfoChip(
                    icon: Icons.shield_outlined,
                    label: node.security.toUpperCase(),
                  ),
                if (node != null)
                  _InfoChip(
                    icon: Icons.swap_horiz_outlined,
                    label: node.network.toUpperCase(),
                  ),
                if (node?.downloadSettings != null)
                  const _InfoChip(
                    icon: Icons.call_split_outlined,
                    label: 'SPLIT',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentNodeCard(ThemeData theme) {
    final ColorScheme colors = theme.colorScheme;
    final StoredNodeDraft? selectedDraft = _selectedDraft;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('当前节点', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              selectedDraft == null
                  ? '还没有选中的节点。先从下方导入一个节点。'
                  : '启动、预览和分流配置都会基于当前节点进行。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (selectedDraft == null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '点击“导入节点”，可以从剪贴板读取 `vless://`、`client_outbound.json`，或对当前节点应用 `client_split_patch.json`。',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _draftTitle(selectedDraft),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _draftSubtitle(selectedDraft),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        _InfoChip(
                          icon: Icons.shield_outlined,
                          label: _draftSecurity(selectedDraft),
                        ),
                        _InfoChip(
                          icon: Icons.swap_horiz_outlined,
                          label: _draftNetwork(selectedDraft),
                        ),
                        if (selectedDraft.node.downloadSettings != null)
                          const _InfoChip(
                            icon: Icons.call_split_outlined,
                            label: 'SPLIT',
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: <Widget>[
                        FilledButton.tonalIcon(
                          onPressed: _isRuntimeLocked
                              ? null
                              : () {
                                  _editNode(selectedDraft);
                                },
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('编辑当前节点'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _isRuntimeLocked
                              ? null
                              : () {
                                  _deleteNode(selectedDraft);
                                },
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除当前节点'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeListCard(ThemeData theme) {
    final ColorScheme colors = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('节点列表', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '保存多个节点，本地切换当前选中节点。运行中会锁定切换和编辑，避免状态混乱。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            MenuAnchor(
              menuChildren: <Widget>[
                MenuItemButton(
                  leadingIcon: const Icon(Icons.content_paste_go_outlined),
                  onPressed: _isRuntimeLocked
                      ? null
                      : () => _handleImportAction(_ImportAction.clipboard),
                  child: const Text('导入链接 / outbound JSON'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.merge_type_outlined),
                  onPressed: _isRuntimeLocked || !_hasSelection
                      ? null
                      : () => _handleImportAction(_ImportAction.clipboardPatch),
                  child: const Text('应用 split patch'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.edit_note_outlined),
                  onPressed: _isRuntimeLocked
                      ? null
                      : () => _handleImportAction(_ImportAction.manual),
                  child: const Text('手动输入 / 编辑'),
                ),
              ],
              builder: (
                BuildContext context,
                MenuController controller,
                Widget? child,
              ) {
                return FilledButton.icon(
                  onPressed: _isRuntimeLocked
                      ? null
                      : () {
                          if (controller.isOpen) {
                            controller.close();
                          } else {
                            controller.open();
                          }
                        },
                  icon: const Icon(Icons.add_link_outlined),
                  label: const Text('导入节点'),
                );
              },
            ),
            const SizedBox(height: 16),
            if (_savedNodes.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '还没有已保存的节点。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              )
            else
              Column(
                children: _savedNodes
                    .map(
                      (StoredNodeDraft draft) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _buildNodeTile(theme, draft),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeTile(ThemeData theme, StoredNodeDraft draft) {
    final ColorScheme colors = theme.colorScheme;
    final bool isSelected = draft.id == _selectedNodeId;

    return Material(
      color:
          isSelected ? colors.secondaryContainer : colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () {
          _selectNode(draft);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      isSelected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off_outlined,
                      color:
                          isSelected ? colors.primary : colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _draftTitle(draft),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _draftSubtitle(draft),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<_NodeItemAction>(
                    onSelected: (_NodeItemAction action) {
                      switch (action) {
                        case _NodeItemAction.edit:
                          _editNode(draft);
                          break;
                        case _NodeItemAction.delete:
                          _deleteNode(draft);
                          break;
                      }
                    },
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<_NodeItemAction>>[
                      const PopupMenuItem<_NodeItemAction>(
                        value: _NodeItemAction.edit,
                        child: Text('编辑'),
                      ),
                      const PopupMenuItem<_NodeItemAction>(
                        value: _NodeItemAction.delete,
                        child: Text('删除'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    _InfoChip(
                      icon: Icons.shield_outlined,
                      label: _draftSecurity(draft),
                    ),
                    _InfoChip(
                      icon: Icons.swap_horiz_outlined,
                      label: _draftNetwork(draft),
                    ),
                    _InfoChip(
                      icon: Icons.alt_route_outlined,
                      label: draft.routingPreset.label,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreferencesCard(ThemeData theme) {
    final ColorScheme colors = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('运行偏好', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              _hasSelection ? '当前设置会保存到选中的节点里。' : '先选中一个节点，再修改它的分流策略和运行模式。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<RoutingPreset>(
              key: ValueKey<String>(
                'routing-${_selectedNodeId ?? 'none'}-${_routingPreset.name}',
              ),
              initialValue: _routingPreset,
              decoration: const InputDecoration(labelText: '分流策略'),
              items: RoutingPreset.values
                  .map(
                    (RoutingPreset preset) => DropdownMenuItem<RoutingPreset>(
                      value: preset,
                      child: Text(preset.label),
                    ),
                  )
                  .toList(),
              onChanged: !_hasSelection || _isRuntimeLocked
                  ? null
                  : (RoutingPreset? value) {
                      if (value != null) {
                        _updateSelectedRoutingPreset(value);
                      }
                    },
            ),
            const SizedBox(height: 8),
            Text(
              _routingPreset.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<RuntimeMode>(
              key: ValueKey<String>(
                'runtime-${_selectedNodeId ?? 'none'}-${_runtimeMode.name}',
              ),
              initialValue: _runtimeMode,
              decoration: const InputDecoration(labelText: '运行模式'),
              items: _runtimeBridge.supportedRuntimeModes
                  .map(
                    (RuntimeMode mode) => DropdownMenuItem<RuntimeMode>(
                      value: mode,
                      child: Text(mode.label),
                    ),
                  )
                  .toList(),
              onChanged: !_hasSelection || _isRuntimeLocked
                  ? null
                  : (RuntimeMode? value) {
                      if (value != null) {
                        _updateSelectedRuntimeMode(value);
                      }
                    },
            ),
            const SizedBox(height: 8),
            Text(
              _runtimeBridge.runtimeModeDescription(_runtimeMode),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeoDataCard(ThemeData theme) {
    final ColorScheme colors = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('规则数据', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '应用内置一份启动用 geosite/geoip，首次启动不再依赖外网下载。连接建立后，会通过本地 HTTP 代理后台刷新规则数据。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            const Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _InfoChip(
                  icon: Icons.inventory_2_outlined,
                  label: '内置首包 geodata',
                ),
                _InfoChip(icon: Icons.http_outlined, label: '127.0.0.1:10809'),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _hasSelection ? _updateGeoData : null,
                icon: const Icon(Icons.travel_explore_outlined),
                label: const Text('立即刷新 geodata'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('操作', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    _hasSelection && !_isRuntimeLocked ? _startRuntime : null,
                icon: const Icon(Icons.shield_outlined),
                label: const Text('启动连接'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _hasSelection && !_isRuntimeLocked
                    ? () {
                        _commitCollection(
                          nodes: _savedNodes,
                          selectedNodeId: _selectedNodeId,
                          successStatus: 'profile-ready',
                          showSnackOnError: true,
                        );
                      }
                    : null,
                icon: const Icon(Icons.preview_outlined),
                label: const Text('刷新配置预览'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: const <String>{
                  'starting',
                  'running',
                  'running-dry',
                }.contains(_status)
                    ? _stopRuntime
                    : null,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('停止连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpandablePanel({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required String content,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
            ),
            child: SelectionArea(
              child: Text(
                content,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _draftTitle(StoredNodeDraft draft) {
    final VlessNode node = draft.node;
    return node.name.trim().isEmpty
        ? '${node.address}:${node.port}'
        : node.name.trim();
  }

  String _draftSubtitle(StoredNodeDraft draft) {
    final VlessNode node = draft.node;
    final String splitSuffix = node.downloadSettings == null
        ? ''
        : ' -> ${node.downloadSettings!.address}:${node.downloadSettings!.port}';
    return '${node.address}:${node.port}$splitSuffix';
  }

  String _draftSecurity(StoredNodeDraft draft) {
    return draft.node.security.toUpperCase();
  }

  String _draftNetwork(StoredNodeDraft draft) {
    return draft.node.network.toUpperCase();
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'profile-ready':
        return '配置已生成';
      case 'running':
        return '运行中';
      case 'starting':
        return '启动中';
      case 'stopping':
        return '停止中';
      case 'running-dry':
        return '演示模式';
      case 'error':
        return '异常';
      case 'stopped':
        return '已停止';
      default:
        return '未启动';
    }
  }

  Color _statusColor(ColorScheme colors, String status) {
    switch (status) {
      case 'running':
        return colors.primary;
      case 'starting':
      case 'stopping':
        return colors.secondary;
      case 'running-dry':
        return colors.tertiary;
      case 'profile-ready':
        return colors.secondary;
      case 'error':
        return colors.error;
      case 'stopped':
        return colors.outline;
      default:
        return colors.outlineVariant;
    }
  }

  String _tabTitle(_HomeTab tab) {
    switch (tab) {
      case _HomeTab.connection:
        return '连接';
      case _HomeTab.nodes:
        return '节点';
      case _HomeTab.routing:
        return '规则与分流';
      case _HomeTab.logs:
        return '日志';
    }
  }
}

class _CompiledDraft {
  const _CompiledDraft({
    required this.profile,
    required this.config,
    required this.configPreview,
  });

  final Profile profile;
  final Map<String, dynamic> config;
  final String configPreview;
}

class _NodeEditorSheet extends StatefulWidget {
  const _NodeEditorSheet({
    required this.title,
    required this.actionLabel,
    this.initialNode,
  });

  final String title;
  final String actionLabel;
  final VlessNode? initialNode;

  @override
  State<_NodeEditorSheet> createState() => _NodeEditorSheetState();
}

class _NodeEditorSheetState extends State<_NodeEditorSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final VlessNode _initialNode;
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _portController;
  late final TextEditingController _idController;
  late final TextEditingController _encryptionController;
  late final TextEditingController _flowController;
  late final TextEditingController _serverNameController;
  late final TextEditingController _fingerprintController;
  late final TextEditingController _publicKeyController;
  late final TextEditingController _shortIdController;
  late final TextEditingController _spiderXController;
  late final TextEditingController _hostController;
  late final TextEditingController _pathController;
  late final TextEditingController _modeController;
  late final TextEditingController _alpnController;
  late final TextEditingController _downloadAddressController;
  late final TextEditingController _downloadPortController;
  late final TextEditingController _downloadServerNameController;
  late final TextEditingController _downloadFingerprintController;
  late final TextEditingController _downloadPublicKeyController;
  late final TextEditingController _downloadShortIdController;
  late final TextEditingController _downloadSpiderXController;
  late final TextEditingController _downloadHostController;
  late final TextEditingController _downloadPathController;
  late final TextEditingController _downloadModeController;
  late final TextEditingController _downloadAlpnController;
  late final Map<String, String> _extras;

  late final List<String> _networkOptions;
  late final List<String> _securityOptions;
  late final List<String> _downloadNetworkOptions;
  late final List<String> _downloadSecurityOptions;
  late String _selectedNetwork;
  late String _selectedSecurity;
  late String _selectedDownloadNetwork;
  late String _selectedDownloadSecurity;
  late bool _enableDownloadSettings;

  @override
  void initState() {
    super.initState();
    _initialNode = _buildInitialNode();
    _extras = Map<String, String>.from(_initialNode.extras);
    final XhttpDownloadSettings? initialDownload =
        _initialNode.downloadSettings;

    _networkOptions = _buildOptions(const <String>[
      'xhttp',
      'tcp',
      'grpc',
      'ws',
    ], _initialNode.network);
    _securityOptions = _buildOptions(const <String>[
      'reality',
      'tls',
      'none',
    ], _initialNode.security);
    _downloadNetworkOptions = _buildOptions(const <String>[
      'xhttp',
    ], initialDownload?.network ?? 'xhttp');
    _downloadSecurityOptions = _buildOptions(const <String>[
      'reality',
      'tls',
      'none',
    ], initialDownload?.security ?? _initialNode.security);

    _selectedNetwork = _initialNode.network;
    _selectedSecurity = _initialNode.security;
    _selectedDownloadNetwork = initialDownload?.network ?? 'xhttp';
    _selectedDownloadSecurity =
        initialDownload?.security ?? _initialNode.security;
    _enableDownloadSettings = initialDownload != null;

    _nameController = TextEditingController(text: _initialNode.name);
    _addressController = TextEditingController(text: _initialNode.address);
    _portController = TextEditingController(text: _initialNode.port.toString());
    _idController = TextEditingController(text: _initialNode.id);
    _encryptionController = TextEditingController(
      text: _initialNode.encryption,
    );
    _flowController = TextEditingController(text: _initialNode.flow);
    _serverNameController = TextEditingController(
      text: _initialNode.serverName,
    );
    _fingerprintController = TextEditingController(
      text: _initialNode.fingerprint,
    );
    _publicKeyController = TextEditingController(text: _initialNode.publicKey);
    _shortIdController = TextEditingController(text: _initialNode.shortId);
    _spiderXController = TextEditingController(text: _initialNode.spiderX);
    _hostController = TextEditingController(text: _initialNode.host);
    _pathController = TextEditingController(text: _initialNode.path);
    _modeController = TextEditingController(text: _initialNode.mode);
    _alpnController = TextEditingController(text: _initialNode.alpn.join(','));
    _downloadAddressController = TextEditingController(
      text: initialDownload?.address ?? '',
    );
    _downloadPortController = TextEditingController(
      text: (initialDownload?.port ?? _initialNode.port).toString(),
    );
    _downloadServerNameController = TextEditingController(
      text: initialDownload?.serverName ?? '',
    );
    _downloadFingerprintController = TextEditingController(
      text: initialDownload?.fingerprint ?? '',
    );
    _downloadPublicKeyController = TextEditingController(
      text: initialDownload?.publicKey ?? '',
    );
    _downloadShortIdController = TextEditingController(
      text: initialDownload?.shortId ?? '',
    );
    _downloadSpiderXController = TextEditingController(
      text: initialDownload?.spiderX ?? '',
    );
    _downloadHostController = TextEditingController(
      text: initialDownload?.host ?? '',
    );
    _downloadPathController = TextEditingController(
      text: initialDownload?.path ?? '',
    );
    _downloadModeController = TextEditingController(
      text: initialDownload?.mode ?? '',
    );
    _downloadAlpnController = TextEditingController(
      text: initialDownload?.alpn.join(',') ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _portController.dispose();
    _idController.dispose();
    _encryptionController.dispose();
    _flowController.dispose();
    _serverNameController.dispose();
    _fingerprintController.dispose();
    _publicKeyController.dispose();
    _shortIdController.dispose();
    _spiderXController.dispose();
    _hostController.dispose();
    _pathController.dispose();
    _modeController.dispose();
    _alpnController.dispose();
    _downloadAddressController.dispose();
    _downloadPortController.dispose();
    _downloadServerNameController.dispose();
    _downloadFingerprintController.dispose();
    _downloadPublicKeyController.dispose();
    _downloadShortIdController.dispose();
    _downloadSpiderXController.dispose();
    _downloadHostController.dispose();
    _downloadPathController.dispose();
    _downloadModeController.dispose();
    _downloadAlpnController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final bool showSecurityFields = _selectedSecurity.toLowerCase() != 'none';
    final bool showRealityFields = _selectedSecurity.toLowerCase() == 'reality';
    final bool showTlsFields = _selectedSecurity.toLowerCase() == 'tls';
    final bool showXhttpFields = _selectedNetwork.toLowerCase() == 'xhttp';
    final bool showDownloadSection = _enableDownloadSettings && showXhttpFields;
    final bool showDownloadSecurityFields = showDownloadSection &&
        _selectedDownloadSecurity.toLowerCase() != 'none';
    final bool showDownloadRealityFields = showDownloadSection &&
        _selectedDownloadSecurity.toLowerCase() == 'reality';
    final bool showDownloadTlsFields =
        showDownloadSection && _selectedDownloadSecurity.toLowerCase() == 'tls';

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: Material(
          color: theme.colorScheme.surface,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(widget.title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      '直接编辑节点字段。基础分享链接会继续保留在上传侧参数里，split 模式的 downloadSettings 也会一并保存。',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _NodeEditorSection(
                          title: '基础信息',
                          child: Column(
                            children: <Widget>[
                              TextFormField(
                                controller: _nameController,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: '配置名称',
                                  hintText: '例如：东京节点',
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _addressController,
                                autofocus: widget.initialNode == null,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: '服务器地址',
                                  hintText: 'example.com 或 1.2.3.4',
                                ),
                                validator: (String? value) {
                                  if ((value ?? '').trim().isEmpty) {
                                    return '请输入服务器地址';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _portController,
                                keyboardType: TextInputType.number,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: '服务器端口',
                                ),
                                validator: (String? value) {
                                  final int? port = int.tryParse(
                                    (value ?? '').trim(),
                                  );
                                  if (port == null ||
                                      port <= 0 ||
                                      port > 65535) {
                                    return '请输入有效端口';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _idController,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'UUID',
                                ),
                                validator: (String? value) {
                                  if ((value ?? '').trim().isEmpty) {
                                    return '请输入 UUID';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _NodeEditorSection(
                          title: '传输与安全',
                          child: Column(
                            children: <Widget>[
                              DropdownButtonFormField<String>(
                                initialValue: _selectedNetwork,
                                decoration: const InputDecoration(
                                  labelText: '传输协议',
                                ),
                                items: _networkOptions
                                    .map(
                                      (String value) =>
                                          DropdownMenuItem<String>(
                                        value: value,
                                        child: Text(value.toUpperCase()),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (String? value) {
                                  if (value == null) {
                                    return;
                                  }
                                  setState(() {
                                    _selectedNetwork = value;
                                    if (_selectedNetwork.toLowerCase() !=
                                        'xhttp') {
                                      _enableDownloadSettings = false;
                                    }
                                  });
                                },
                              ),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                initialValue: _selectedSecurity,
                                decoration: const InputDecoration(
                                  labelText: '安全类型',
                                ),
                                items: _securityOptions
                                    .map(
                                      (String value) =>
                                          DropdownMenuItem<String>(
                                        value: value,
                                        child: Text(value.toUpperCase()),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (String? value) {
                                  if (value == null) {
                                    return;
                                  }
                                  setState(() {
                                    _selectedSecurity = value;
                                  });
                                },
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _encryptionController,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'Encryption',
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _flowController,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'Flow',
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (showSecurityFields) ...<Widget>[
                          const SizedBox(height: 16),
                          _NodeEditorSection(
                            title: showRealityFields ? 'REALITY' : 'TLS',
                            child: Column(
                              children: <Widget>[
                                TextFormField(
                                  controller: _serverNameController,
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'SNI / serverName',
                                  ),
                                  validator: (String? value) {
                                    if (showSecurityFields &&
                                        (value ?? '').trim().isEmpty) {
                                      return '当前安全类型需要 serverName';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _fingerprintController,
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'Fingerprint',
                                  ),
                                  validator: (String? value) {
                                    if (showSecurityFields &&
                                        (value ?? '').trim().isEmpty) {
                                      return '当前安全类型需要 fingerprint';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),
                                if (showTlsFields)
                                  TextFormField(
                                    controller: _alpnController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: 'ALPN',
                                      hintText: '例如：h2 或 h2,http/1.1',
                                    ),
                                  ),
                                if (showRealityFields) ...<Widget>[
                                  TextFormField(
                                    controller: _publicKeyController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: 'Public Key',
                                    ),
                                    validator: (String? value) {
                                      if (showRealityFields &&
                                          (value ?? '').trim().isEmpty) {
                                        return 'REALITY 需要 public key';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _shortIdController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: 'Short ID',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _spiderXController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: 'SpiderX',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                        if (showXhttpFields) ...<Widget>[
                          const SizedBox(height: 16),
                          _NodeEditorSection(
                            title: 'XHTTP',
                            child: Column(
                              children: <Widget>[
                                TextFormField(
                                  controller: _hostController,
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'Host',
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _pathController,
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'Path',
                                  ),
                                  validator: (String? value) {
                                    if (showXhttpFields &&
                                        (value ?? '').trim().isEmpty) {
                                      return 'XHTTP 需要 path';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _modeController,
                                  textInputAction: TextInputAction.done,
                                  decoration: const InputDecoration(
                                    labelText: 'Mode',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (showXhttpFields) ...<Widget>[
                          const SizedBox(height: 16),
                          _NodeEditorSection(
                            title: '分离下行',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                SwitchListTile.adaptive(
                                  contentPadding: EdgeInsets.zero,
                                  value: _enableDownloadSettings,
                                  title: const Text('启用 downloadSettings'),
                                  subtitle: const Text(
                                    '用于 IPv6 上行 + IPv4 下行、双 VPS、CDN + VPS 这类 split 模式。',
                                  ),
                                  onChanged: (bool value) {
                                    setState(() {
                                      _enableDownloadSettings = value;
                                      if (value) {
                                        _syncDownloadDefaultsFromUpload();
                                      }
                                    });
                                  },
                                ),
                                if (showDownloadSection) ...<Widget>[
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _downloadAddressController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: '下行地址',
                                      hintText: 'IPv4、IPv6 或域名',
                                    ),
                                    validator: (String? value) {
                                      if (showDownloadSection &&
                                          (value ?? '').trim().isEmpty) {
                                        return '请输入下行地址';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _downloadPortController,
                                    keyboardType: TextInputType.number,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: '下行端口',
                                    ),
                                    validator: (String? value) {
                                      if (!showDownloadSection) {
                                        return null;
                                      }
                                      final int? port = int.tryParse(
                                        (value ?? '').trim(),
                                      );
                                      if (port == null ||
                                          port <= 0 ||
                                          port > 65535) {
                                        return '请输入有效下行端口';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  DropdownButtonFormField<String>(
                                    initialValue: _selectedDownloadNetwork,
                                    decoration: const InputDecoration(
                                      labelText: '下行传输协议',
                                    ),
                                    items: _downloadNetworkOptions
                                        .map(
                                          (String value) =>
                                              DropdownMenuItem<String>(
                                            value: value,
                                            child: Text(
                                              value.toUpperCase(),
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (String? value) {
                                      if (value == null) {
                                        return;
                                      }
                                      setState(() {
                                        _selectedDownloadNetwork = value;
                                      });
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  DropdownButtonFormField<String>(
                                    initialValue: _selectedDownloadSecurity,
                                    decoration: const InputDecoration(
                                      labelText: '下行安全类型',
                                    ),
                                    items: _downloadSecurityOptions
                                        .map(
                                          (String value) =>
                                              DropdownMenuItem<String>(
                                            value: value,
                                            child: Text(
                                              value.toUpperCase(),
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (String? value) {
                                      if (value == null) {
                                        return;
                                      }
                                      setState(() {
                                        _selectedDownloadSecurity = value;
                                      });
                                    },
                                  ),
                                  if (showDownloadSecurityFields) ...<Widget>[
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller: _downloadServerNameController,
                                      textInputAction: TextInputAction.next,
                                      decoration: const InputDecoration(
                                        labelText: '下行 SNI / serverName',
                                      ),
                                      validator: (String? value) {
                                        if (showDownloadSecurityFields &&
                                            (value ?? '').trim().isEmpty) {
                                          return '下行安全类型需要 serverName';
                                        }
                                        return null;
                                      },
                                    ),
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller:
                                          _downloadFingerprintController,
                                      textInputAction: TextInputAction.next,
                                      decoration: const InputDecoration(
                                        labelText: '下行 Fingerprint',
                                      ),
                                      validator: (String? value) {
                                        if (showDownloadSecurityFields &&
                                            (value ?? '').trim().isEmpty) {
                                          return '下行安全类型需要 fingerprint';
                                        }
                                        return null;
                                      },
                                    ),
                                  ],
                                  if (showDownloadTlsFields) ...<Widget>[
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller: _downloadAlpnController,
                                      textInputAction: TextInputAction.next,
                                      decoration: const InputDecoration(
                                        labelText: '下行 ALPN',
                                        hintText: '例如：h2',
                                      ),
                                    ),
                                  ],
                                  if (showDownloadRealityFields) ...<Widget>[
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller: _downloadPublicKeyController,
                                      textInputAction: TextInputAction.next,
                                      decoration: const InputDecoration(
                                        labelText: '下行 Public Key',
                                      ),
                                      validator: (String? value) {
                                        if (showDownloadRealityFields &&
                                            (value ?? '').trim().isEmpty) {
                                          return '下行 REALITY 需要 public key';
                                        }
                                        return null;
                                      },
                                    ),
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller: _downloadShortIdController,
                                      textInputAction: TextInputAction.next,
                                      decoration: const InputDecoration(
                                        labelText: '下行 Short ID',
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller: _downloadSpiderXController,
                                      textInputAction: TextInputAction.next,
                                      decoration: const InputDecoration(
                                        labelText: '下行 SpiderX',
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _downloadHostController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: '下行 Host',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _downloadPathController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: '下行 Path',
                                    ),
                                    validator: (String? value) {
                                      if (showDownloadSection &&
                                          (value ?? '').trim().isEmpty) {
                                        return '下行 XHTTP 需要 path';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _downloadModeController,
                                    textInputAction: TextInputAction.done,
                                    decoration: const InputDecoration(
                                      labelText: '下行 Mode',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.download_done_outlined),
                    label: Text(widget.actionLabel),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final int port = int.parse(_portController.text.trim());
    final VlessNode node = _initialNode.copyWith(
      name: _nameController.text.trim(),
      address: _addressController.text.trim(),
      port: port,
      id: _idController.text.trim(),
      network: _selectedNetwork.trim(),
      security: _selectedSecurity.trim(),
      encryption: _encryptionController.text.trim().isEmpty
          ? 'none'
          : _encryptionController.text.trim(),
      flow: _flowController.text.trim(),
      serverName: _serverNameController.text.trim(),
      fingerprint: _fingerprintController.text.trim(),
      publicKey: _publicKeyController.text.trim(),
      shortId: _shortIdController.text.trim(),
      spiderX: _spiderXController.text.trim(),
      host: _hostController.text.trim(),
      path: _pathController.text.trim(),
      mode: _modeController.text.trim(),
      alpn: _csvToList(_alpnController.text),
      downloadSettings: _buildDownloadSettings(port),
      extras: _extras,
    );

    Navigator.of(context).pop(node);
  }

  VlessNode _buildInitialNode() {
    if (widget.initialNode != null) {
      return widget.initialNode!;
    }

    return const VlessNode(
      name: '',
      address: '',
      port: 443,
      id: '',
      network: 'xhttp',
      security: 'reality',
    );
  }

  List<String> _buildOptions(List<String> defaults, String currentValue) {
    final String normalized = currentValue.trim().isEmpty
        ? defaults.first
        : currentValue.trim().toLowerCase();
    final List<String> options = defaults.toList();
    if (!options.contains(normalized)) {
      options.add(normalized);
    }
    return options;
  }

  void _syncDownloadDefaultsFromUpload() {
    if (_downloadPortController.text.trim().isEmpty) {
      _downloadPortController.text = _portController.text.trim().isEmpty
          ? '443'
          : _portController.text.trim();
    }
    if (_downloadPathController.text.trim().isEmpty) {
      _downloadPathController.text = _pathController.text.trim();
    }
    if (_downloadModeController.text.trim().isEmpty) {
      _downloadModeController.text = _modeController.text.trim();
    }
    if (_downloadHostController.text.trim().isEmpty) {
      _downloadHostController.text = _hostController.text.trim();
    }
    if (_downloadServerNameController.text.trim().isEmpty) {
      _downloadServerNameController.text = _serverNameController.text.trim();
    }
    if (_downloadFingerprintController.text.trim().isEmpty) {
      _downloadFingerprintController.text = _fingerprintController.text.trim();
    }
    if (_downloadPublicKeyController.text.trim().isEmpty) {
      _downloadPublicKeyController.text = _publicKeyController.text.trim();
    }
    if (_downloadShortIdController.text.trim().isEmpty) {
      _downloadShortIdController.text = _shortIdController.text.trim();
    }
    if (_downloadSpiderXController.text.trim().isEmpty) {
      _downloadSpiderXController.text = _spiderXController.text.trim();
    }
    if (_downloadAlpnController.text.trim().isEmpty) {
      _downloadAlpnController.text = _alpnController.text.trim();
    }
    _selectedDownloadSecurity = _selectedSecurity.trim();
  }

  XhttpDownloadSettings? _buildDownloadSettings(int fallbackPort) {
    if (!_enableDownloadSettings) {
      return null;
    }

    final int port =
        int.tryParse(_downloadPortController.text.trim()) ?? fallbackPort;
    return XhttpDownloadSettings(
      address: _downloadAddressController.text.trim(),
      port: port,
      network: _selectedDownloadNetwork.trim(),
      security: _selectedDownloadSecurity.trim(),
      serverName: _downloadServerNameController.text.trim(),
      fingerprint: _downloadFingerprintController.text.trim(),
      publicKey: _downloadPublicKeyController.text.trim(),
      shortId: _downloadShortIdController.text.trim(),
      spiderX: _downloadSpiderXController.text.trim(),
      host: _downloadHostController.text.trim(),
      path: _downloadPathController.text.trim(),
      mode: _downloadModeController.text.trim(),
      alpn: _csvToList(_downloadAlpnController.text),
    );
  }

  List<String> _csvToList(String raw) {
    return raw
        .split(',')
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toList();
  }
}

class _NodeEditorSection extends StatelessWidget {
  const _NodeEditorSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}
