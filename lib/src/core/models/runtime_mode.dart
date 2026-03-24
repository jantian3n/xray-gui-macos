enum RuntimeMode {
  vpn,
  systemProxy,
  localProxy,
}

extension RuntimeModeLabel on RuntimeMode {
  String get label {
    switch (this) {
      case RuntimeMode.vpn:
        return 'VPN 模式';
      case RuntimeMode.systemProxy:
        return '系统代理';
      case RuntimeMode.localProxy:
        return '本地代理';
    }
  }
}
