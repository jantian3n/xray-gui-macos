import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class MacosSystemProxyController {
  static const String _backupFileName = 'system_proxy_backup.v1.json';

  _ProxyBackup? _activeBackup;

  Future<void> recoverIfNeeded({
    required void Function(String message) log,
  }) async {
    if (!Platform.isMacOS) {
      return;
    }

    final _ProxyBackup? backup = _activeBackup ?? await _readBackup();
    if (backup == null) {
      return;
    }

    await _restoreBackup(backup);
    await _deleteBackup();
    _activeBackup = null;
    log('restored macOS system proxy from a previous session.');
  }

  Future<void> enable({
    required int httpPort,
    required int socksPort,
    required void Function(String message) log,
  }) async {
    if (!Platform.isMacOS) {
      return;
    }

    await recoverIfNeeded(log: log);

    final _NetworkService service = await _resolvePrimaryService();
    final _ProxyBackup backup = await _captureBackup(service.name);
    _ensureBackupIsSafeToOverride(backup);

    final List<String> bypassDomains = <String>{
      ...backup.bypassDomains,
      '127.0.0.1',
      'localhost',
    }.toList()
      ..sort();

    await _applyProxyBypassDomains(service.name, bypassDomains);
    await _applyProxyState(
      service.name,
      const _ProxyCommandPair(
        setter: '-setwebproxy',
        stateSetter: '-setwebproxystate',
      ),
      _ProxyState.enabled(
        server: '127.0.0.1',
        port: httpPort,
      ),
    );
    await _applyProxyState(
      service.name,
      const _ProxyCommandPair(
        setter: '-setsecurewebproxy',
        stateSetter: '-setsecurewebproxystate',
      ),
      _ProxyState.enabled(
        server: '127.0.0.1',
        port: httpPort,
      ),
    );
    await _applyProxyState(
      service.name,
      const _ProxyCommandPair(
        setter: '-setsocksfirewallproxy',
        stateSetter: '-setsocksfirewallproxystate',
      ),
      _ProxyState.enabled(
        server: '127.0.0.1',
        port: socksPort,
      ),
    );

    _activeBackup = backup;
    await _writeBackup(backup);
    log(
      'enabled macOS system proxy on ${service.name}: '
      'http=127.0.0.1:$httpPort socks=127.0.0.1:$socksPort',
    );
  }

  Future<void> disable({
    required void Function(String message) log,
  }) async {
    if (!Platform.isMacOS) {
      return;
    }

    final _ProxyBackup? backup = _activeBackup ?? await _readBackup();
    if (backup == null) {
      return;
    }

    await _restoreBackup(backup);
    await _deleteBackup();
    _activeBackup = null;
    log('restored macOS system proxy on ${backup.serviceName}.');
  }

  void _ensureBackupIsSafeToOverride(_ProxyBackup backup) {
    final List<_ProxyState> states = <_ProxyState>[
      backup.web,
      backup.secureWeb,
      backup.socks,
    ];
    if (states.any((state) => state.authenticated)) {
      throw UnsupportedError(
        '当前网络服务已经启用了需要认证的系统代理，'
        '自动切换暂不支持覆盖这种配置。',
      );
    }
  }

  Future<_NetworkService> _resolvePrimaryService() async {
    final String output = await _runNetworkSetup(
      const <String>['-listnetworkserviceorder'],
    );
    final List<String> lines = output
        .split(RegExp(r'[\r\n]+'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);

    final List<_NetworkService> services = <_NetworkService>[];
    final RegExp servicePattern = RegExp(r'^\((\d+|\*)\)\s+(.+)$');
    final RegExp devicePattern =
        RegExp(r'^\(Hardware Port:\s*(.*), Device:\s*(.*)\)$');

    for (int index = 0; index < lines.length; index += 1) {
      final Match? serviceMatch = servicePattern.firstMatch(lines[index]);
      if (serviceMatch == null) {
        continue;
      }
      if (index + 1 >= lines.length) {
        break;
      }
      final Match? deviceMatch = devicePattern.firstMatch(lines[index + 1]);
      if (deviceMatch == null) {
        continue;
      }
      services.add(
        _NetworkService(
          name: serviceMatch.group(2)?.trim() ?? '',
          device: deviceMatch.group(2)?.trim() ?? '',
          disabled: serviceMatch.group(1) == '*',
        ),
      );
    }

    final Iterable<_NetworkService> candidates = services.where(
      (_NetworkService service) =>
          !service.disabled && service.device.isNotEmpty,
    );
    for (final _NetworkService service in candidates) {
      final String info =
          await _runNetworkSetup(<String>['-getinfo', service.name]);
      final Match? ipMatch = RegExp(
        r'^IP address:\s*(.+)$',
        multiLine: true,
      ).firstMatch(info);
      final String ipAddress = ipMatch?.group(1)?.trim() ?? '';
      if (ipAddress.isNotEmpty && ipAddress.toLowerCase() != 'none') {
        return service;
      }
    }

    final _NetworkService? fallback =
        candidates.cast<_NetworkService?>().firstWhere(
              (_NetworkService? service) => service != null,
              orElse: () => null,
            );
    if (fallback != null) {
      return fallback;
    }

    throw StateError('未找到可用的 macOS 网络服务，无法自动设置系统代理。');
  }

  Future<_ProxyBackup> _captureBackup(String serviceName) async {
    return _ProxyBackup(
      serviceName: serviceName,
      web: await _readProxyState(serviceName, '-getwebproxy'),
      secureWeb: await _readProxyState(serviceName, '-getsecurewebproxy'),
      socks: await _readProxyState(serviceName, '-getsocksfirewallproxy'),
      bypassDomains: await _readBypassDomains(serviceName),
    );
  }

  Future<_ProxyState> _readProxyState(
    String serviceName,
    String getter,
  ) async {
    final String output = await _runNetworkSetup(<String>[getter, serviceName]);
    final Map<String, String> values = <String, String>{};
    for (final String line in output.split(RegExp(r'[\r\n]+'))) {
      final int separatorIndex = line.indexOf(':');
      if (separatorIndex <= 0) {
        continue;
      }
      values[line.substring(0, separatorIndex).trim()] =
          line.substring(separatorIndex + 1).trim();
    }

    return _ProxyState(
      enabled: (values['Enabled'] ?? '').toLowerCase() == 'yes',
      server: values['Server'] ?? '',
      port: int.tryParse(values['Port'] ?? '') ?? 0,
      authenticated:
          (values['Authenticated Proxy Enabled'] ?? '').trim() == '1',
    );
  }

  Future<List<String>> _readBypassDomains(String serviceName) async {
    final String output = await _runNetworkSetup(
      <String>['-getproxybypassdomains', serviceName],
    );
    return output
        .split(RegExp(r'[\r\n]+'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _restoreBackup(_ProxyBackup backup) async {
    await _applyProxyBypassDomains(backup.serviceName, backup.bypassDomains);
    await _applyProxyState(
      backup.serviceName,
      const _ProxyCommandPair(
        setter: '-setwebproxy',
        stateSetter: '-setwebproxystate',
      ),
      backup.web,
    );
    await _applyProxyState(
      backup.serviceName,
      const _ProxyCommandPair(
        setter: '-setsecurewebproxy',
        stateSetter: '-setsecurewebproxystate',
      ),
      backup.secureWeb,
    );
    await _applyProxyState(
      backup.serviceName,
      const _ProxyCommandPair(
        setter: '-setsocksfirewallproxy',
        stateSetter: '-setsocksfirewallproxystate',
      ),
      backup.socks,
    );
  }

  Future<void> _applyProxyBypassDomains(
    String serviceName,
    List<String> domains,
  ) async {
    await _runNetworkSetup(
      <String>[
        '-setproxybypassdomains',
        serviceName,
        if (domains.isEmpty) 'Empty' else ...domains,
      ],
    );
  }

  Future<void> _applyProxyState(
    String serviceName,
    _ProxyCommandPair commands,
    _ProxyState state,
  ) async {
    if (state.enabled) {
      await _runNetworkSetup(
        <String>[
          commands.setter,
          serviceName,
          state.server,
          '${state.port}',
          'off',
        ],
      );
      await _runNetworkSetup(<String>[commands.stateSetter, serviceName, 'on']);
      return;
    }

    await _runNetworkSetup(<String>[commands.stateSetter, serviceName, 'off']);
  }

  Future<String> _runNetworkSetup(List<String> arguments) async {
    final ProcessResult result = await Process.run(
      '/usr/sbin/networksetup',
      arguments,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        '/usr/sbin/networksetup',
        arguments,
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return '${result.stdout}';
  }

  Future<File> _backupFile() async {
    final Directory supportDir = await getApplicationSupportDirectory();
    return File(path.join(supportDir.path, _backupFileName));
  }

  Future<void> _writeBackup(_ProxyBackup backup) async {
    final File file = await _backupFile();
    await file.writeAsString(jsonEncode(backup.toJson()), flush: true);
  }

  Future<_ProxyBackup?> _readBackup() async {
    final File file = await _backupFile();
    if (!await file.exists()) {
      return null;
    }

    try {
      final Map<String, dynamic> json = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map<dynamic, dynamic>,
      );
      return _ProxyBackup.fromJson(json);
    } catch (_) {
      await _deleteBackup();
      return null;
    }
  }

  Future<void> _deleteBackup() async {
    final File file = await _backupFile();
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class _NetworkService {
  const _NetworkService({
    required this.name,
    required this.device,
    required this.disabled,
  });

  final String name;
  final String device;
  final bool disabled;
}

class _ProxyCommandPair {
  const _ProxyCommandPair({
    required this.setter,
    required this.stateSetter,
  });

  final String setter;
  final String stateSetter;
}

class _ProxyState {
  const _ProxyState({
    required this.enabled,
    required this.server,
    required this.port,
    required this.authenticated,
  });

  const _ProxyState.enabled({
    required String server,
    required int port,
  }) : this(
          enabled: true,
          server: server,
          port: port,
          authenticated: false,
        );

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

  factory _ProxyState.fromJson(Map<String, dynamic> json) {
    return _ProxyState(
      enabled: json['enabled'] as bool? ?? false,
      server: json['server'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      authenticated: json['authenticated'] as bool? ?? false,
    );
  }
}

class _ProxyBackup {
  const _ProxyBackup({
    required this.serviceName,
    required this.web,
    required this.secureWeb,
    required this.socks,
    required this.bypassDomains,
  });

  final String serviceName;
  final _ProxyState web;
  final _ProxyState secureWeb;
  final _ProxyState socks;
  final List<String> bypassDomains;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'serviceName': serviceName,
      'web': web.toJson(),
      'secureWeb': secureWeb.toJson(),
      'socks': socks.toJson(),
      'bypassDomains': bypassDomains,
    };
  }

  factory _ProxyBackup.fromJson(Map<String, dynamic> json) {
    return _ProxyBackup(
      serviceName: json['serviceName'] as String? ?? '',
      web: _ProxyState.fromJson(
        Map<String, dynamic>.from(
          json['web'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{},
        ),
      ),
      secureWeb: _ProxyState.fromJson(
        Map<String, dynamic>.from(
          json['secureWeb'] as Map<dynamic, dynamic>? ??
              const <dynamic, dynamic>{},
        ),
      ),
      socks: _ProxyState.fromJson(
        Map<String, dynamic>.from(
          json['socks'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{},
        ),
      ),
      bypassDomains:
          (json['bypassDomains'] as List<dynamic>? ?? const <dynamic>[])
              .map((dynamic item) => '$item'.trim())
              .where((String item) => item.isNotEmpty)
              .toList(growable: false),
    );
  }
}
