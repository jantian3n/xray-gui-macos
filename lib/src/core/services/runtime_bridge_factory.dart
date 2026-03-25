import 'dart:io';

import 'desktop_runtime_bridge.dart';
import 'method_channel_runtime_bridge.dart';
import 'runtime_bridge.dart';

RuntimeBridge createRuntimeBridge() {
  if (Platform.isAndroid) {
    return MethodChannelRuntimeBridge();
  }

  if (Platform.isMacOS || Platform.isWindows) {
    return DesktopRuntimeBridge();
  }

  return UnsupportedRuntimeBridge();
}
