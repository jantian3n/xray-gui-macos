enum RoutingPreset {
  cnDirect,
  globalProxy,
  gfwLike,
}

extension RoutingPresetLabel on RoutingPreset {
  String get label {
    switch (this) {
      case RoutingPreset.cnDirect:
        return '国内直连';
      case RoutingPreset.globalProxy:
        return '全局代理';
      case RoutingPreset.gfwLike:
        return '常见被墙域名代理';
    }
  }

  String get description {
    switch (this) {
      case RoutingPreset.cnDirect:
        return '中国大陆和私有地址直连，海外流量走代理。';
      case RoutingPreset.globalProxy:
        return '除私有地址外，所有流量都走代理。';
      case RoutingPreset.gfwLike:
        return '常见受限域名走代理，其余多数流量保持直连。';
    }
  }
}
