import '../models/runtime_mode.dart';
import '../models/profile.dart';

abstract class RuntimeBridge {
  Future<void> initialize();

  List<RuntimeMode> get supportedRuntimeModes;

  RuntimeMode normalizeRuntimeMode(RuntimeMode mode);

  String runtimeModeDescription(RuntimeMode mode);

  Future<void> requestVpnPermission();

  Future<void> start(Profile profile, Map<String, dynamic> config);

  Future<void> stop();

  Future<String> runtimeState();

  Future<void> updateGeoData();

  Stream<String> logs();
}

class UnsupportedRuntimeBridge implements RuntimeBridge {
  UnsupportedRuntimeBridge();

  static const String _message = '当前平台还没有接入 Xray runtime bridge。';

  @override
  Future<void> initialize() async {}

  @override
  List<RuntimeMode> get supportedRuntimeModes =>
      const <RuntimeMode>[RuntimeMode.systemProxy, RuntimeMode.localProxy];

  @override
  RuntimeMode normalizeRuntimeMode(RuntimeMode mode) {
    if (mode == RuntimeMode.vpn) {
      return RuntimeMode.systemProxy;
    }
    return mode;
  }

  @override
  String runtimeModeDescription(RuntimeMode mode) {
    return _message;
  }

  @override
  Future<void> requestVpnPermission() async {
    throw UnsupportedError(_message);
  }

  @override
  Future<void> start(Profile profile, Map<String, dynamic> config) async {
    throw UnsupportedError(_message);
  }

  @override
  Future<void> stop() async {
    throw UnsupportedError(_message);
  }

  @override
  Future<String> runtimeState() async {
    return 'unsupported';
  }

  @override
  Future<void> updateGeoData() async {
    throw UnsupportedError(_message);
  }

  @override
  Stream<String> logs() => const Stream<String>.empty();
}
