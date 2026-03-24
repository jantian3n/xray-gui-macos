import 'dart:io';

import 'desktop_runtime_bridge.dart';
import 'runtime_bridge.dart';

RuntimeBridge createRuntimeBridge() {
  if (Platform.isMacOS) {
    return DesktopRuntimeBridge();
  }

  return UnsupportedRuntimeBridge();
}
