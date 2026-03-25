import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/profile.dart';
import '../models/runtime_traffic_snapshot.dart';
import '../models/runtime_mode.dart';
import 'macos_system_proxy_controller.dart';
import 'runtime_bridge.dart';

class DesktopRuntimeBridge implements RuntimeBridge {
  DesktopRuntimeBridge() {
    if (Platform.isMacOS) {
      unawaited(_systemProxyController.recoverIfNeeded(log: _emit));
    }
  }

  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');
  static const List<String> _geodataFiles = <String>[
    'geoip.dat',
    'geosite.dat',
  ];
  static const String _assetLocationEnv = 'XRAY_LOCATION_ASSET';
  static const String _xrayBinaryEnv = 'XRAY_GUI_XRAY_BINARY';
  static const String _geodataBaseUrl =
      'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download';
  static const String _statsServerHost = '127.0.0.1';
  static const String _statsApiInboundTag = 'gui-api-in';
  static const String _statsApiOutboundTag = 'gui-api';
  static const String _trafficStatsPattern = 'outbound>>>proxy>>>traffic>>>';
  static const String _uplinkSuffix = '>>>uplink';
  static const String _downlinkSuffix = '>>>downlink';

  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  final StreamController<RuntimeTrafficSnapshot> _trafficController =
      StreamController<RuntimeTrafficSnapshot>.broadcast();
  final MacosSystemProxyController _systemProxyController =
      MacosSystemProxyController();

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Profile? _activeProfile;
  Timer? _trafficPollTimer;
  bool _stopRequested = false;
  bool _trafficPollInFlight = false;
  String? _xrayBinaryPath;
  int? _statsApiPort;
  DateTime? _lastTrafficPollAt;
  String _state = 'idle';

  @override
  List<RuntimeMode> get supportedRuntimeModes =>
      const <RuntimeMode>[RuntimeMode.localProxy];

  @override
  RuntimeMode normalizeRuntimeMode(RuntimeMode mode) {
    return RuntimeMode.localProxy;
  }

  @override
  String runtimeModeDescription(RuntimeMode mode) {
    switch (mode) {
      case RuntimeMode.vpn:
        return '桌面端当前还没有接入系统级 VPN/TUN，先统一使用本地代理模式。';
      case RuntimeMode.localProxy:
        return '启动本地 SOCKS/HTTP 代理端口，并在 macOS 上自动切换系统代理。';
    }
  }

  @override
  Future<void> requestVpnPermission() async {
    throw UnsupportedError('桌面版当前不支持 VPN 模式，请切换到本地代理模式。');
  }

  @override
  Future<void> start(Profile profile, Map<String, dynamic> config) async {
    if (profile.runtimeMode != RuntimeMode.localProxy) {
      throw UnsupportedError('桌面版当前仅支持本地代理模式。');
    }

    await stop();

    final _DesktopRuntimeLayout layout = await _prepareLayout();
    final String xrayBinaryPath = await _resolveXrayBinary(layout);
    final int statsApiPort = await _allocateLoopbackPort();
    final Map<String, dynamic> runtimeConfig =
        _withDesktopStatsApi(config, statsApiPort);
    final File configFile =
        File(path.join(layout.runtimeDir.path, 'config.json'));
    final File profileFile =
        File(path.join(layout.runtimeDir.path, 'profile.json'));

    await configFile.writeAsString(_encoder.convert(runtimeConfig));
    await profileFile.writeAsString(_encoder.convert(profile.toJson()));

    _emit('wrote config to ${configFile.path}');
    _emit('using geodata at ${layout.geodataDir.path}');
    _emit('using xray binary at $xrayBinaryPath');

    _activeProfile = profile;
    _xrayBinaryPath = xrayBinaryPath;
    _statsApiPort = statsApiPort;
    _stopRequested = false;
    _setState('starting');
    _resetTrafficStats();

    try {
      final Process process = await Process.start(
        xrayBinaryPath,
        <String>[
          'run',
          '-c',
          configFile.path,
        ],
        workingDirectory: layout.runtimeDir.path,
        environment: <String, String>{
          ...Platform.environment,
          _assetLocationEnv: layout.geodataDir.path,
        },
        runInShell: Platform.isWindows,
      );

      _process = process;
      _stdoutSubscription = _listenToOutput(process.stdout);
      _stderrSubscription = _listenToOutput(process.stderr, prefix: 'stderr: ');
      unawaited(_watchExit(process));
      await _systemProxyController.enable(
        httpPort: profile.httpPort,
        socksPort: profile.socksPort,
        log: _emit,
      );
      _startTrafficPolling();
      _setState('running');
    } catch (error) {
      final Process? process = _process;
      if (process != null) {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
        }
      }
      await _systemProxyController.disable(log: _emit);
      _stopTrafficPolling();
      _xrayBinaryPath = null;
      _statsApiPort = null;
      _setState('error');
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final Process? process = _process;
    if (process == null) {
      _activeProfile = null;
      _setState('stopped');
      return;
    }

    _stopRequested = true;
    _setState('stopping');

    process.kill();

    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5));
    }
  }

  @override
  Future<String> runtimeState() async {
    return _state;
  }

  @override
  Future<void> updateGeoData() async {
    final _DesktopRuntimeLayout layout = await _prepareLayout();
    final int? proxyPort =
        _state == 'running' ? _activeProfile?.httpPort : null;
    final String routeLabel = proxyPort == null
        ? 'direct network'
        : 'local HTTP proxy 127.0.0.1:$proxyPort';

    _emit('Updating geodata into ${layout.geodataDir.path} via $routeLabel');

    for (final String fileName in _geodataFiles) {
      await _downloadAndVerifyGeodataFile(
        layout.geodataDir,
        fileName,
        proxyPort: proxyPort,
      );
    }

    final File stampFile =
        File(path.join(layout.geodataDir.path, 'LAST_UPDATE.txt'));
    await stampFile.writeAsString(
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    _emit('Geodata update finished.');
  }

  @override
  Stream<String> logs() => _logController.stream;

  @override
  Stream<RuntimeTrafficSnapshot> traffic() => _trafficController.stream;

  StreamSubscription<String> _listenToOutput(
    Stream<List<int>> stream, {
    String prefix = '',
  }) {
    return stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) {
        return;
      }
      _emit('$prefix$trimmed');
    });
  }

  Future<void> _watchExit(Process process) async {
    final int exitCode = await process.exitCode;
    if (!identical(_process, process)) {
      return;
    }

    await _systemProxyController.disable(log: _emit);
    _stopTrafficPolling();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;

    final bool stopRequested = _stopRequested;
    _stopRequested = false;

    if (exitCode == 0) {
      _emit(stopRequested ? 'xray stopped.' : 'xray exited normally.');
      _setState('stopped');
    } else {
      _emit('xray exited with code $exitCode.');
      _setState(stopRequested ? 'stopped' : 'error');
    }

    _activeProfile = null;
    _xrayBinaryPath = null;
    _statsApiPort = null;
  }

  Future<int> _allocateLoopbackPort() async {
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = socket.port;
    await socket.close();
    return port;
  }

  Map<String, dynamic> _withDesktopStatsApi(
    Map<String, dynamic> config,
    int statsApiPort,
  ) {
    final Map<String, dynamic> runtimeConfig = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(config)) as Map<dynamic, dynamic>,
    );

    runtimeConfig['stats'] = <String, dynamic>{};

    final Map<String, dynamic> policy =
        runtimeConfig['policy'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(
                runtimeConfig['policy'] as Map<String, dynamic>,
              )
            : runtimeConfig['policy'] is Map
                ? Map<String, dynamic>.from(
                    runtimeConfig['policy'] as Map<dynamic, dynamic>,
                  )
                : <String, dynamic>{};

    final Map<String, dynamic> systemPolicy =
        policy['system'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(
                policy['system'] as Map<String, dynamic>,
              )
            : policy['system'] is Map
                ? Map<String, dynamic>.from(
                    policy['system'] as Map<dynamic, dynamic>,
                  )
                : <String, dynamic>{};

    systemPolicy['statsInboundUplink'] = true;
    systemPolicy['statsInboundDownlink'] = true;
    systemPolicy['statsOutboundUplink'] = true;
    systemPolicy['statsOutboundDownlink'] = true;
    policy['system'] = systemPolicy;
    runtimeConfig['policy'] = policy;

    runtimeConfig['api'] = <String, dynamic>{
      'tag': _statsApiOutboundTag,
      'services': <String>['StatsService'],
    };

    final List<Map<String, dynamic>> inbounds = _asMapList(
      runtimeConfig['inbounds'],
    );
    final bool hasApiInbound = inbounds.any(
      (Map<String, dynamic> inbound) => inbound['tag'] == _statsApiInboundTag,
    );
    if (!hasApiInbound) {
      inbounds.add(
        <String, dynamic>{
          'tag': _statsApiInboundTag,
          'listen': _statsServerHost,
          'port': statsApiPort,
          'protocol': 'dokodemo-door',
          'settings': <String, dynamic>{
            'address': _statsServerHost,
          },
        },
      );
    }
    runtimeConfig['inbounds'] = inbounds;

    final List<Map<String, dynamic>> outbounds = _asMapList(
      runtimeConfig['outbounds'],
    );
    final bool hasApiOutbound = outbounds.any(
      (Map<String, dynamic> outbound) =>
          outbound['tag'] == _statsApiOutboundTag,
    );
    if (!hasApiOutbound) {
      outbounds.add(
        <String, dynamic>{
          'tag': _statsApiOutboundTag,
          'protocol': 'freedom',
          'settings': <String, dynamic>{},
        },
      );
    }
    runtimeConfig['outbounds'] = outbounds;

    final Map<String, dynamic> routing =
        runtimeConfig['routing'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(
                runtimeConfig['routing'] as Map<String, dynamic>,
              )
            : runtimeConfig['routing'] is Map
                ? Map<String, dynamic>.from(
                    runtimeConfig['routing'] as Map<dynamic, dynamic>,
                  )
                : <String, dynamic>{};
    final List<Map<String, dynamic>> rules = _asMapList(routing['rules']);
    final bool hasApiRule = rules.any(
      (Map<String, dynamic> rule) =>
          rule['outboundTag'] == _statsApiOutboundTag &&
          (rule['inboundTag'] as List<dynamic>? ?? const <dynamic>[])
              .contains(_statsApiInboundTag),
    );
    if (!hasApiRule) {
      rules.insert(
        0,
        <String, dynamic>{
          'type': 'field',
          'inboundTag': <String>[_statsApiInboundTag],
          'outboundTag': _statsApiOutboundTag,
        },
      );
    }
    routing['rules'] = rules;
    runtimeConfig['routing'] = routing;

    return runtimeConfig;
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is List<Map<String, dynamic>>) {
      return value
          .map((Map<String, dynamic> item) => Map<String, dynamic>.from(item))
          .toList();
    }
    if (value is List) {
      return value
          .whereType<Map>()
          .map(
            (Map<dynamic, dynamic> item) => Map<String, dynamic>.from(item),
          )
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  void _startTrafficPolling() {
    _stopTrafficPolling();
    if (_xrayBinaryPath == null || _statsApiPort == null) {
      return;
    }

    _lastTrafficPollAt = DateTime.now();
    _trafficPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        unawaited(_pollTrafficStats());
      },
    );
  }

  void _stopTrafficPolling() {
    _trafficPollTimer?.cancel();
    _trafficPollTimer = null;
    _trafficPollInFlight = false;
    _lastTrafficPollAt = null;
    _resetTrafficStats();
  }

  void _resetTrafficStats() {
    if (_trafficController.isClosed) {
      return;
    }
    _trafficController.add(const RuntimeTrafficSnapshot.zero());
  }

  Future<void> _pollTrafficStats() async {
    final String? xrayBinaryPath = _xrayBinaryPath;
    final int? statsApiPort = _statsApiPort;
    final DateTime? lastTrafficPollAt = _lastTrafficPollAt;
    if (_trafficPollInFlight ||
        xrayBinaryPath == null ||
        statsApiPort == null ||
        lastTrafficPollAt == null) {
      return;
    }

    _trafficPollInFlight = true;
    try {
      final _RawTrafficStats? rawStats = await _queryTrafficStats(
        xrayBinaryPath: xrayBinaryPath,
        statsApiPort: statsApiPort,
      );
      if (rawStats == null) {
        return;
      }

      final DateTime now = DateTime.now();
      final int intervalMs = now.difference(lastTrafficPollAt).inMilliseconds;
      if (intervalMs <= 0) {
        _lastTrafficPollAt = now;
        return;
      }

      _lastTrafficPollAt = now;
      if (_trafficController.isClosed) {
        return;
      }

      _trafficController.add(
        RuntimeTrafficSnapshot(
          uploadBytesPerSecond:
              (rawStats.uploadBytes * 1000 / intervalMs).round(),
          downloadBytesPerSecond:
              (rawStats.downloadBytes * 1000 / intervalMs).round(),
        ),
      );
    } finally {
      _trafficPollInFlight = false;
    }
  }

  Future<_RawTrafficStats?> _queryTrafficStats({
    required String xrayBinaryPath,
    required int statsApiPort,
  }) async {
    try {
      final ProcessResult result = await Process.run(
        xrayBinaryPath,
        <String>[
          'api',
          'statsquery',
          '--server=$_statsServerHost:$statsApiPort',
          '-pattern',
          _trafficStatsPattern,
          '-reset',
        ],
        runInShell: Platform.isWindows,
      );
      if (result.exitCode != 0) {
        return null;
      }

      final String output = '${result.stdout}'.trim();
      if (output.isEmpty) {
        return const _RawTrafficStats.zero();
      }

      final Map<String, dynamic> response = Map<String, dynamic>.from(
        jsonDecode(output) as Map<dynamic, dynamic>,
      );
      int uploadBytes = 0;
      int downloadBytes = 0;

      for (final dynamic entry
          in response['stat'] as List<dynamic>? ?? const <dynamic>[]) {
        if (entry is! Map) {
          continue;
        }
        final Map<String, dynamic> stat = Map<String, dynamic>.from(entry);
        final String name = stat['name'] as String? ?? '';
        final int value = (stat['value'] as num?)?.toInt() ?? 0;
        if (name.endsWith(_uplinkSuffix)) {
          uploadBytes = value;
        } else if (name.endsWith(_downlinkSuffix)) {
          downloadBytes = value;
        }
      }

      return _RawTrafficStats(
        uploadBytes: uploadBytes,
        downloadBytes: downloadBytes,
      );
    } on Object {
      return null;
    }
  }

  Future<_DesktopRuntimeLayout> _prepareLayout() async {
    final Directory supportDir = await getApplicationSupportDirectory();
    final Directory runtimeDir =
        Directory(path.join(supportDir.path, 'xray_gui'));
    runtimeDir.createSync(recursive: true);
    final Directory geodataDir =
        Directory(path.join(runtimeDir.path, 'geodata'));
    geodataDir.createSync(recursive: true);
    final Directory extractedBinDir =
        Directory(path.join(runtimeDir.path, 'bin'));
    extractedBinDir.createSync(recursive: true);

    await _installBundledGeodataIfMissing(geodataDir);

    return _DesktopRuntimeLayout(
      runtimeDir: runtimeDir,
      geodataDir: geodataDir,
      extractedBinDir: extractedBinDir,
    );
  }

  Future<void> _installBundledGeodataIfMissing(Directory geodataDir) async {
    for (final String fileName in _geodataFiles) {
      final File targetFile = File(path.join(geodataDir.path, fileName));
      if (await targetFile.exists() && await targetFile.length() > 0) {
        continue;
      }

      final ByteData? data =
          await _loadOptionalAsset('assets/bootstrap-geodata/$fileName');
      if (data == null) {
        _emit('Bundled $fileName not found in Flutter assets.');
        continue;
      }

      await targetFile.writeAsBytes(_asUint8List(data), flush: true);
      _emit('Installed bundled $fileName from Flutter assets.');
    }
  }

  Future<String> _resolveXrayBinary(_DesktopRuntimeLayout layout) async {
    final String? envBinary = Platform.environment[_xrayBinaryEnv];
    if (envBinary != null && envBinary.trim().isNotEmpty) {
      final File file = File(envBinary.trim());
      if (await file.exists()) {
        return file.path;
      }
      throw StateError(
        'XRAY_GUI_XRAY_BINARY 指向的文件不存在: ${file.path}',
      );
    }

    final String? bundledBinaryPath = await _extractBundledBinary(layout);
    if (bundledBinaryPath != null) {
      return bundledBinaryPath;
    }

    final String binaryName = _xrayBinaryName;
    final File executablePeer = File(
        path.join(File(Platform.resolvedExecutable).parent.path, binaryName));
    if (await executablePeer.exists()) {
      return executablePeer.path;
    }

    final String? pathBinary = await _findBinaryOnPath(binaryName);
    if (pathBinary != null) {
      return pathBinary;
    }

    throw StateError(
      '未找到 xray 可执行文件。请先确认桌面包里已经包含 '
      'assets/bin/$_platformAssetFolder/$_xrayBinaryName，'
      '并重新执行 flutter build macos；'
      '或者手动设置 XRAY_GUI_XRAY_BINARY=/absolute/path/to/$_xrayBinaryName 。',
    );
  }

  Future<String?> _extractBundledBinary(_DesktopRuntimeLayout layout) async {
    final String assetKey = 'assets/bin/$_platformAssetFolder/$_xrayBinaryName';
    final ByteData? data = await _loadOptionalAsset(assetKey);
    if (data == null) {
      return null;
    }

    final File binaryFile =
        File(path.join(layout.extractedBinDir.path, _xrayBinaryName));
    await binaryFile.writeAsBytes(_asUint8List(data), flush: true);

    await _prepareExtractedBinary(binaryFile);

    return binaryFile.path;
  }

  Future<void> _prepareExtractedBinary(File binaryFile) async {
    if (!Platform.isWindows) {
      final ProcessResult chmodResult = await Process.run(
        '/bin/chmod',
        <String>['755', binaryFile.path],
      );
      if (chmodResult.exitCode != 0) {
        throw StateError('无法为 ${binaryFile.path} 设置可执行权限。');
      }
    }

    if (!Platform.isMacOS) {
      return;
    }

    for (final String attribute in <String>[
      'com.apple.quarantine',
      'com.apple.provenance',
    ]) {
      await Process.run(
        '/usr/bin/xattr',
        <String>['-d', attribute, binaryFile.path],
      );
    }
  }

  Future<ByteData?> _loadOptionalAsset(String assetKey) async {
    try {
      return await rootBundle.load(assetKey);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _findBinaryOnPath(String binaryName) async {
    final String finder = Platform.isWindows ? 'where' : 'which';
    final ProcessResult result = await Process.run(
      finder,
      <String>[binaryName],
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      return null;
    }

    final String output = '${result.stdout}'.trim();
    if (output.isEmpty) {
      return null;
    }

    final String candidate = output
        .split(RegExp(r'[\r\n]+'))
        .map((String line) => line.trim())
        .firstWhere((String line) => line.isNotEmpty, orElse: () => '');
    return candidate.isEmpty ? null : candidate;
  }

  Future<void> _downloadAndVerifyGeodataFile(
    Directory geodataDir,
    String fileName, {
    int? proxyPort,
  }) async {
    final File tempFile =
        File(path.join(geodataDir.path, '$fileName.download'));
    final File targetFile = File(path.join(geodataDir.path, fileName));

    _emit('Downloading $fileName');
    await _downloadToFile(
      '$_geodataBaseUrl/$fileName',
      tempFile,
      proxyPort: proxyPort,
    );

    final String checksumText = await _downloadText(
      '$_geodataBaseUrl/$fileName.sha256sum',
      proxyPort: proxyPort,
    );
    final String checksumLine = checksumText
        .split(RegExp(r'[\r\n]+'))
        .map((String line) => line.trim())
        .firstWhere(
          (String line) => line.isNotEmpty,
          orElse: () => '',
        );
    final List<String> checksumParts = checksumLine
        .split(RegExp(r'\s+'))
        .where((String item) => item.isNotEmpty)
        .toList(growable: false);
    final String expectedHash =
        checksumParts.isEmpty ? '' : checksumParts.first;

    if (expectedHash.isEmpty) {
      await _deleteIfExists(tempFile);
      throw StateError('$fileName 的 checksum 文件为空。');
    }

    final Digest actualHash = sha256.convert(await tempFile.readAsBytes());
    if (actualHash.toString().toLowerCase() != expectedHash.toLowerCase()) {
      await _deleteIfExists(tempFile);
      throw StateError(
        '$fileName 的 checksum 校验失败。expected=$expectedHash actual=$actualHash',
      );
    }

    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await tempFile.rename(targetFile.path);
    _emit('Verified and installed $fileName');
  }

  Future<String> _downloadText(
    String url, {
    int? proxyPort,
  }) async {
    final HttpClient client = _createHttpClient(proxyPort: proxyPort);
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      final HttpClientResponse response = await request.close();
      _ensureOk(response, url);
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadToFile(
    String url,
    File output, {
    int? proxyPort,
  }) async {
    final HttpClient client = _createHttpClient(proxyPort: proxyPort);
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      final HttpClientResponse response = await request.close();
      _ensureOk(response, url);
      final IOSink sink = output.openWrite();
      try {
        await response.pipe(sink);
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  HttpClient _createHttpClient({int? proxyPort}) {
    final HttpClient client = HttpClient();
    if (proxyPort != null) {
      client.findProxy = (Uri _) => 'PROXY 127.0.0.1:$proxyPort';
    }
    return client;
  }

  void _ensureOk(HttpClientResponse response, String url) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw HttpException(
      'Unexpected HTTP ${response.statusCode} for $url',
      uri: Uri.parse(url),
    );
  }

  Uint8List _asUint8List(ByteData data) {
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<void> _deleteIfExists(File file) async {
    if (!await file.exists()) {
      return;
    }

    try {
      await file.delete();
    } on FileSystemException {
      // Best-effort cleanup only.
    }
  }

  void _setState(String value) {
    _state = value;
    _emit('state=$value');
  }

  void _emit(String message) {
    if (_logController.isClosed) {
      return;
    }
    _logController.add(message);
  }

  String get _platformAssetFolder {
    if (Platform.isMacOS) {
      return 'macos';
    }
    if (Platform.isWindows) {
      return 'windows';
    }
    return 'desktop';
  }

  String get _xrayBinaryName {
    return Platform.isWindows ? 'xray.exe' : 'xray';
  }
}

class _DesktopRuntimeLayout {
  const _DesktopRuntimeLayout({
    required this.runtimeDir,
    required this.geodataDir,
    required this.extractedBinDir,
  });

  final Directory runtimeDir;
  final Directory geodataDir;
  final Directory extractedBinDir;
}

class _RawTrafficStats {
  const _RawTrafficStats({
    required this.uploadBytes,
    required this.downloadBytes,
  });

  const _RawTrafficStats.zero()
      : uploadBytes = 0,
        downloadBytes = 0;

  final int uploadBytes;
  final int downloadBytes;
}
