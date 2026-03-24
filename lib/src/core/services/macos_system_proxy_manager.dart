import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/profile.dart';

class MacosSystemProxyManager {
  MacosSystemProxyManager({
    required Directory runtimeDir,
    required void Function(String) emit,
  })  : _emit = emit,
        _snapshotFile = File(
          path.join(runtimeDir.path, 'system_proxy_snapshot.json'),
        );

  final void Function(String) _emit;
  final File _snapshotFile;

  Future<void> restoreStaleSnapshotIfNeeded() async {
    if (!await _snapshotFile.exists()) {
      return;
    }

    _emit(
        'found stale macOS system proxy snapshot, restoring previous settings');
    await _restoreSnapshot(await _loadSnapshot());
    await _deleteSnapshot();
  }

  Future<void> enable(Profile profile) async {
    final List<_MacosNetworkService> services = await _listManagedServices();
    if (services.isEmpty) {
      throw StateError('没有找到可写入系统代理的 macOS 网络服务。');
    }

    final _MacosProxySnapshot snapshot = await _captureSnapshot(services);
    _assertRestorable(snapshot);
    await _snapshotFile.writeAsString(
      jsonEncode(snapshot.toJson()),
      flush: true,
    );

    for (final _MacosNetworkServiceState serviceState in snapshot.services) {
      _emit(
        'enabling macOS system proxy on ${serviceState.name} (${serviceState.device})',
      );
      await _runNetworksetup(<String>[
        '-setwebproxy',
        serviceState.name,
        '127.0.0.1',
        profile.httpPort.toString(),
        'off',
      ]);
      await _runNetworksetup(<String>[
        '-setsecurewebproxy',
        serviceState.name,
        '127.0.0.1',
        profile.httpPort.toString(),
        'off',
      ]);
      await _runNetworksetup(<String>[
        '-setsocksfirewallproxy',
        serviceState.name,
        '127.0.0.1',
        profile.socksPort.toString(),
        'off',
      ]);
      await _runNetworksetup(<String>[
        '-setproxybypassdomains',
        serviceState.name,
        ..._managedBypassDomains(serviceState.bypassDomains),
      ]);
    }

    _emit(
      'macOS system proxy enabled on ${snapshot.services.length} network services.',
    );
  }

  Future<void> restoreIfNeeded() async {
    if (!await _snapshotFile.exists()) {
      return;
    }

    final _MacosProxySnapshot snapshot = await _loadSnapshot();
    await _restoreSnapshot(snapshot);
    await _deleteSnapshot();
  }

  Future<_MacosProxySnapshot> _loadSnapshot() async {
    final Map<String, dynamic> json = Map<String, dynamic>.from(
      jsonDecode(await _snapshotFile.readAsString()) as Map<dynamic, dynamic>,
    );
    return _MacosProxySnapshot.fromJson(json);
  }

  Future<void> _restoreSnapshot(_MacosProxySnapshot snapshot) async {
    for (final _MacosNetworkServiceState serviceState in snapshot.services) {
      _emit(
        'restoring macOS proxy settings on ${serviceState.name} (${serviceState.device})',
      );
      await _restoreProxy(serviceState.name, _ProxyKind.web, serviceState.web);
      await _restoreProxy(
        serviceState.name,
        _ProxyKind.secureWeb,
        serviceState.secureWeb,
      );
      await _restoreProxy(
        serviceState.name,
        _ProxyKind.socks,
        serviceState.socks,
      );
      await _runNetworksetup(<String>[
        '-setproxybypassdomains',
        serviceState.name,
        ..._restoreBypassDomains(serviceState.bypassDomains),
      ]);
    }

    _emit('macOS system proxy restored.');
  }

  Future<void> _restoreProxy(
    String serviceName,
    _ProxyKind kind,
    _MacosProxySetting setting,
  ) async {
    if (setting.authenticated) {
      throw StateError(
        '检测到已开启认证代理的系统设置，当前版本不会覆盖它，请先手动恢复原始代理设置。',
      );
    }

    if (!setting.enabled) {
      await _runNetworksetup(<String>[
        _stateFlag(kind),
        serviceName,
        'off',
      ]);
      return;
    }

    await _runNetworksetup(<String>[
      _setFlag(kind),
      serviceName,
      setting.server,
      setting.port.toString(),
      'off',
    ]);
    await _runNetworksetup(<String>[
      _stateFlag(kind),
      serviceName,
      'on',
    ]);
  }

  Future<_MacosProxySnapshot> _captureSnapshot(
    List<_MacosNetworkService> services,
  ) async {
    final List<_MacosNetworkServiceState> states =
        <_MacosNetworkServiceState>[];

    for (final _MacosNetworkService service in services) {
      final String webOutput = await _runNetworksetup(<String>[
        '-getwebproxy',
        service.name,
      ]);
      final String secureWebOutput = await _runNetworksetup(<String>[
        '-getsecurewebproxy',
        service.name,
      ]);
      final String socksOutput = await _runNetworksetup(<String>[
        '-getsocksfirewallproxy',
        service.name,
      ]);
      final String bypassOutput = await _runNetworksetup(<String>[
        '-getproxybypassdomains',
        service.name,
      ]);

      states.add(
        _MacosNetworkServiceState(
          name: service.name,
          device: service.device,
          web: _parseProxySetting(webOutput),
          secureWeb: _parseProxySetting(secureWebOutput),
          socks: _parseProxySetting(socksOutput),
          bypassDomains: _parseBypassDomains(bypassOutput),
        ),
      );
    }

    return _MacosProxySnapshot(services: states);
  }

  void _assertRestorable(_MacosProxySnapshot snapshot) {
    for (final _MacosNetworkServiceState serviceState in snapshot.services) {
      for (final _MacosProxySetting setting in <_MacosProxySetting>[
        serviceState.web,
        serviceState.secureWeb,
        serviceState.socks,
      ]) {
        if (setting.authenticated) {
          throw StateError(
            '检测到 ${serviceState.name} 已启用认证代理。'
            '当前版本不会覆盖这种系统代理，请先切换到“本地代理”模式或手动关闭原代理。',
          );
        }
      }
    }
  }

  Future<List<_MacosNetworkService>> _listManagedServices() async {
    final String output = await _runNetworksetup(<String>[
      '-listnetworkserviceorder',
    ]);
    return _parseNetworkServices(output);
  }

  List<_MacosNetworkService> _parseNetworkServices(String output) {
    final List<String> lines = output
        .split(RegExp(r'[\r\n]+'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
    final List<_MacosNetworkService> services = <_MacosNetworkService>[];
    final RegExp servicePattern = RegExp(r'^\((\*|\d+)\)\s+(.+)$');
    final RegExp hardwarePattern = RegExp(
      r'^\(Hardware Port: .*?, Device: (.*?)\)$',
    );

    for (int index = 0; index < lines.length; index += 1) {
      final RegExpMatch? serviceMatch = servicePattern.firstMatch(lines[index]);
      if (serviceMatch == null) {
        continue;
      }

      final bool disabled = serviceMatch.group(1) == '*';
      final String name = serviceMatch.group(2)?.trim() ?? '';
      final String nextLine = index + 1 < lines.length ? lines[index + 1] : '';
      final RegExpMatch? hardwareMatch = hardwarePattern.firstMatch(nextLine);
      final String device = hardwareMatch?.group(1)?.trim() ?? '';

      if (disabled || name.isEmpty || device.isEmpty) {
        continue;
      }

      services.add(_MacosNetworkService(name: name, device: device));
    }

    return services;
  }

  _MacosProxySetting _parseProxySetting(String output) {
    final Map<String, String> values = <String, String>{};
    for (final String line in output.split(RegExp(r'[\r\n]+'))) {
      final int separator = line.indexOf(':');
      if (separator < 0) {
        continue;
      }
      final String key = line.substring(0, separator).trim();
      final String value = line.substring(separator + 1).trim();
      values[key] = value;
    }

    return _MacosProxySetting(
      enabled: _parseEnabled(values['Enabled']),
      server: values['Server'] ?? '',
      port: int.tryParse(values['Port'] ?? '') ?? 0,
      authenticated: _parseEnabled(values['Authenticated Proxy Enabled']),
    );
  }

  List<String> _parseBypassDomains(String output) {
    final List<String> lines = output
        .split(RegExp(r'[\r\n]+'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);

    if (lines.isEmpty) {
      return const <String>[];
    }
    if (lines.first.startsWith("There aren't any")) {
      return const <String>[];
    }

    return lines;
  }

  bool _parseEnabled(String? raw) {
    final String value = raw?.trim().toLowerCase() ?? '';
    return value == 'yes' || value == 'on' || value == '1' || value == 'true';
  }

  List<String> _managedBypassDomains(List<String> current) {
    final List<String> merged = <String>[...current];
    for (final String domain in const <String>[
      '127.0.0.1',
      'localhost',
      '::1',
      '*.local',
    ]) {
      if (!merged.contains(domain)) {
        merged.add(domain);
      }
    }
    return merged.isEmpty ? const <String>['Empty'] : merged;
  }

  List<String> _restoreBypassDomains(List<String> domains) {
    return domains.isEmpty ? const <String>['Empty'] : domains;
  }

  String _setFlag(_ProxyKind kind) {
    switch (kind) {
      case _ProxyKind.web:
        return '-setwebproxy';
      case _ProxyKind.secureWeb:
        return '-setsecurewebproxy';
      case _ProxyKind.socks:
        return '-setsocksfirewallproxy';
    }
  }

  String _stateFlag(_ProxyKind kind) {
    switch (kind) {
      case _ProxyKind.web:
        return '-setwebproxystate';
      case _ProxyKind.secureWeb:
        return '-setsecurewebproxystate';
      case _ProxyKind.socks:
        return '-setsocksfirewallproxystate';
    }
  }

  Future<String> _runNetworksetup(List<String> arguments) async {
    final ProcessResult result = await Process.run(
      '/usr/sbin/networksetup',
      arguments,
    );
    if (result.exitCode != 0) {
      final String stderr = '${result.stderr}'.trim();
      throw ProcessException(
        '/usr/sbin/networksetup',
        arguments,
        stderr.isEmpty ? '${result.stdout}'.trim() : stderr,
        result.exitCode,
      );
    }
    return '${result.stdout}';
  }

  Future<void> _deleteSnapshot() async {
    if (!await _snapshotFile.exists()) {
      return;
    }

    await _snapshotFile.delete();
  }
}

enum _ProxyKind {
  web,
  secureWeb,
  socks,
}

class _MacosNetworkService {
  const _MacosNetworkService({
    required this.name,
    required this.device,
  });

  final String name;
  final String device;
}

class _MacosProxySnapshot {
  const _MacosProxySnapshot({
    required this.services,
  });

  factory _MacosProxySnapshot.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawServices =
        json['services'] as List<dynamic>? ?? <dynamic>[];
    return _MacosProxySnapshot(
      services: rawServices
          .map(
            (dynamic item) => _MacosNetworkServiceState.fromJson(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>),
            ),
          )
          .toList(growable: false),
    );
  }

  final List<_MacosNetworkServiceState> services;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'services': services
          .map((_MacosNetworkServiceState service) => service.toJson())
          .toList(growable: false),
    };
  }
}

class _MacosNetworkServiceState {
  const _MacosNetworkServiceState({
    required this.name,
    required this.device,
    required this.web,
    required this.secureWeb,
    required this.socks,
    required this.bypassDomains,
  });

  factory _MacosNetworkServiceState.fromJson(Map<String, dynamic> json) {
    return _MacosNetworkServiceState(
      name: json['name'] as String? ?? '',
      device: json['device'] as String? ?? '',
      web: _MacosProxySetting.fromJson(
        Map<String, dynamic>.from(json['web'] as Map<dynamic, dynamic>),
      ),
      secureWeb: _MacosProxySetting.fromJson(
        Map<String, dynamic>.from(
          json['secureWeb'] as Map<dynamic, dynamic>,
        ),
      ),
      socks: _MacosProxySetting.fromJson(
        Map<String, dynamic>.from(json['socks'] as Map<dynamic, dynamic>),
      ),
      bypassDomains: (json['bypassDomains'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic item) => '$item')
          .toList(growable: false),
    );
  }

  final String name;
  final String device;
  final _MacosProxySetting web;
  final _MacosProxySetting secureWeb;
  final _MacosProxySetting socks;
  final List<String> bypassDomains;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'device': device,
      'web': web.toJson(),
      'secureWeb': secureWeb.toJson(),
      'socks': socks.toJson(),
      'bypassDomains': bypassDomains,
    };
  }
}

class _MacosProxySetting {
  const _MacosProxySetting({
    required this.enabled,
    required this.server,
    required this.port,
    required this.authenticated,
  });

  factory _MacosProxySetting.fromJson(Map<String, dynamic> json) {
    return _MacosProxySetting(
      enabled: json['enabled'] as bool? ?? false,
      server: json['server'] as String? ?? '',
      port: json['port'] as int? ?? 0,
      authenticated: json['authenticated'] as bool? ?? false,
    );
  }

  final bool enabled;
  final String server;
  final int port;
  final bool authenticated;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'enabled': enabled,
      'server': server,
      'port': port,
      'authenticated': authenticated,
    };
  }
}
