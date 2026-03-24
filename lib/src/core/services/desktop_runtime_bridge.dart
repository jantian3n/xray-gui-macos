import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/profile.dart';
import '../models/runtime_mode.dart';
import 'runtime_bridge.dart';

class DesktopRuntimeBridge implements RuntimeBridge {
  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');
  static const List<String> _geodataFiles = <String>[
    'geoip.dat',
    'geosite.dat',
  ];
  static const String _assetLocationEnv = 'XRAY_LOCATION_ASSET';
  static const String _xrayBinaryEnv = 'XRAY_GUI_XRAY_BINARY';
  static const String _geodataBaseUrl =
      'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download';

  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Profile? _activeProfile;
  bool _stopRequested = false;
  String _state = 'idle';

  @override
  List<RuntimeMode> get supportedRuntimeModes => const <RuntimeMode>[
    RuntimeMode.localProxy,
  ];

  @override
  RuntimeMode normalizeRuntimeMode(RuntimeMode mode) {
    return RuntimeMode.localProxy;
  }

  @override
  String runtimeModeDescription(RuntimeMode mode) {
    switch (mode) {
      case RuntimeMode.vpn:
        return 'macOS 版当前还没有接入系统级 VPN/TUN，先统一使用本地代理模式。';
      case RuntimeMode.localProxy:
        return '启动本地 SOCKS/HTTP 代理端口，适合当前这版 macOS 客户端。';
    }
  }

  @override
  Future<void> requestVpnPermission() async {
    throw UnsupportedError('macOS 版当前不支持 VPN 模式，请切换到本地代理模式。');
  }

  @override
  Future<void> start(Profile profile, Map<String, dynamic> config) async {
    if (profile.runtimeMode != RuntimeMode.localProxy) {
      throw UnsupportedError('macOS 版当前仅支持本地代理模式。');
    }

    await stop();

    final _DesktopRuntimeLayout layout = await _prepareLayout();
    final String xrayBinaryPath = await _resolveXrayBinary(layout);
    final File configFile = File(
      path.join(layout.runtimeDir.path, 'config.json'),
    );
    final File profileFile = File(
      path.join(layout.runtimeDir.path, 'profile.json'),
    );

    await configFile.writeAsString(_encoder.convert(config));
    await profileFile.writeAsString(_encoder.convert(profile.toJson()));

    _emit('wrote config to ${configFile.path}');
    _emit('using geodata at ${layout.geodataDir.path}');
    _emit('using xray binary at $xrayBinaryPath');

    _activeProfile = profile;
    _stopRequested = false;
    _setState('starting');

    try {
      final Process process = await Process.start(
        xrayBinaryPath,
        <String>['run', '-c', configFile.path],
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
      _setState('running');
    } catch (error) {
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
    final int? proxyPort = _state == 'running'
        ? _activeProfile?.httpPort
        : null;
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

    final File stampFile = File(
      path.join(layout.geodataDir.path, 'LAST_UPDATE.txt'),
    );
    await stampFile.writeAsString(
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    _emit('Geodata update finished.');
  }

  @override
  Stream<String> logs() => _logController.stream;

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
  }

  Future<_DesktopRuntimeLayout> _prepareLayout() async {
    final Directory supportDir = await getApplicationSupportDirectory();
    final Directory runtimeDir = Directory(
      path.join(supportDir.path, 'xray_gui'),
    );
    runtimeDir.createSync(recursive: true);
    final Directory geodataDir = Directory(
      path.join(runtimeDir.path, 'geodata'),
    );
    geodataDir.createSync(recursive: true);
    final Directory extractedBinDir = Directory(
      path.join(runtimeDir.path, 'bin'),
    );
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

      final ByteData? data = await _loadOptionalAsset(
        'assets/bootstrap-geodata/$fileName',
      );
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
      throw StateError('XRAY_GUI_XRAY_BINARY 指向的文件不存在: ${file.path}');
    }

    final String? bundledBinaryPath = await _extractBundledBinary(layout);
    if (bundledBinaryPath != null) {
      return bundledBinaryPath;
    }

    final String binaryName = _xrayBinaryName;
    final File executablePeer = File(
      path.join(File(Platform.resolvedExecutable).parent.path, binaryName),
    );
    if (await executablePeer.exists()) {
      return executablePeer.path;
    }

    final String? pathBinary = await _findBinaryOnPath(binaryName);
    if (pathBinary != null) {
      return pathBinary;
    }

    throw StateError(
      '未找到 xray 可执行文件。请设置 XRAY_GUI_XRAY_BINARY，'
      '或先运行 scripts/build_desktop_xray.sh 生成 assets/bin/$_platformAssetFolder/$_xrayBinaryName 后再重新构建桌面应用。',
    );
  }

  Future<String?> _extractBundledBinary(_DesktopRuntimeLayout layout) async {
    final String assetKey = 'assets/bin/$_platformAssetFolder/$_xrayBinaryName';
    final ByteData? data = await _loadOptionalAsset(assetKey);
    if (data == null) {
      return null;
    }

    final File binaryFile = File(
      path.join(layout.extractedBinDir.path, _xrayBinaryName),
    );
    await binaryFile.writeAsBytes(_asUint8List(data), flush: true);

    if (!Platform.isWindows) {
      final ProcessResult result = await Process.run('chmod', <String>[
        '755',
        binaryFile.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('无法为 ${binaryFile.path} 设置可执行权限。');
      }
    }

    return binaryFile.path;
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
    final ProcessResult result = await Process.run(finder, <String>[
      binaryName,
    ], runInShell: Platform.isWindows);
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
    final File tempFile = File(
      path.join(geodataDir.path, '$fileName.download'),
    );
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
        .firstWhere((String line) => line.isNotEmpty, orElse: () => '');
    final List<String> checksumParts = checksumLine
        .split(RegExp(r'\s+'))
        .where((String item) => item.isNotEmpty)
        .toList(growable: false);
    final String expectedHash = checksumParts.isEmpty
        ? ''
        : checksumParts.first;

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

  Future<String> _downloadText(String url, {int? proxyPort}) async {
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
