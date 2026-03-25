import '../models/runtime_traffic_snapshot.dart';
import '../models/runtime_mode.dart';
import '../models/profile.dart';

abstract class RuntimeBridge {
  List<RuntimeMode> get supportedRuntimeModes;

  RuntimeMode normalizeRuntimeMode(RuntimeMode mode);

  String runtimeModeDescription(RuntimeMode mode);

  Future<void> requestVpnPermission();

  Future<void> start(Profile profile, Map<String, dynamic> config);

  Future<void> stop();

  Future<String> runtimeState();

  Future<void> updateGeoData();

  Stream<String> logs();

  Stream<RuntimeTrafficSnapshot> traffic();
}

class UnsupportedRuntimeBridge implements RuntimeBridge {
  UnsupportedRuntimeBridge();

  static const String _message = '当前平台还没有接入 Xray runtime bridge。';

  @override
  List<RuntimeMode> get supportedRuntimeModes =>
      const <RuntimeMode>[RuntimeMode.localProxy];

  @override
  RuntimeMode normalizeRuntimeMode(RuntimeMode mode) {
    return RuntimeMode.localProxy;
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

  @override
  Stream<RuntimeTrafficSnapshot> traffic() =>
      const Stream<RuntimeTrafficSnapshot>.empty();
}
