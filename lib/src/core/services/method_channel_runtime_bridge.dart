import 'package:flutter/services.dart';

import '../models/profile.dart';
import '../models/runtime_traffic_snapshot.dart';
import '../models/runtime_mode.dart';
import 'runtime_bridge.dart';

class MethodChannelRuntimeBridge implements RuntimeBridge {
  static const MethodChannel _methodChannel = MethodChannel('xray_gui/runtime');
  static const EventChannel _logChannel = EventChannel('xray_gui/runtime_logs');

  @override
  List<RuntimeMode> get supportedRuntimeModes => RuntimeMode.values;

  @override
  RuntimeMode normalizeRuntimeMode(RuntimeMode mode) {
    return mode;
  }

  @override
  String runtimeModeDescription(RuntimeMode mode) {
    switch (mode) {
      case RuntimeMode.vpn:
        return '通过 Android VpnService 接管流量，更接近最终客户端形态。';
      case RuntimeMode.localProxy:
        return '仅启动本地代理端口，适合前期联调和排查配置问题。';
    }
  }

  @override
  Future<void> requestVpnPermission() async {
    await _methodChannel.invokeMethod<void>('requestVpnPermission');
  }

  @override
  Future<void> start(Profile profile, Map<String, dynamic> config) async {
    await _methodChannel.invokeMethod<void>('start', <String, dynamic>{
      'profile': profile.toJson(),
      'config': config,
    });
  }

  @override
  Future<void> stop() async {
    await _methodChannel.invokeMethod<void>('stop');
  }

  @override
  Future<String> runtimeState() async {
    final value = await _methodChannel.invokeMethod<String>('runtimeState');
    return value ?? 'unknown';
  }

  @override
  Future<void> updateGeoData() async {
    await _methodChannel.invokeMethod<void>('updateGeoData');
  }

  @override
  Stream<String> logs() {
    return _logChannel
        .receiveBroadcastStream()
        .map((dynamic event) => '$event');
  }

  @override
  Stream<RuntimeTrafficSnapshot> traffic() =>
      const Stream<RuntimeTrafficSnapshot>.empty();
}
