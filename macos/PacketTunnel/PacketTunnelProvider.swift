import Darwin
import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private enum Constants {
    static let profileNameKey = "profileName"
    static let proxyHostKey = "proxyHost"
    static let httpPortKey = "httpPort"
    static let tunMtuKey = "tunMtu"
    static let defaultProfileName = "Unknown Profile"
    static let defaultProxyHost = "127.0.0.1"
    static let tunnelRemoteAddress = "127.0.0.1"
    static let tunnelIPv4Address = "198.18.0.1"
    static let tunnelIPv4Mask = "255.255.255.255"
    static let tunnelIPv6Address = "fd7d:1f4d:5f6b::1"
    static let tunnelIPv6Prefix = 128
    static let defaultMTU = 1500
    static let proxyReadyTimeoutSeconds: TimeInterval = 12
    static let healthcheckIntervalNanoseconds: UInt64 = 5_000_000_000
  }

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.example.xrayGui.PacketTunnel",
    category: "PacketTunnel"
  )

  private var activeProfileName = Constants.defaultProfileName
  private var activeProxyHost = Constants.defaultProxyHost
  private var activeHTTPPort = 0
  private var healthMonitorTask: Task<Void, Never>?

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol
    let providerConfiguration = tunnelProtocol?.providerConfiguration ?? [:]
    let profileName = stringValue(
      providerConfiguration[Constants.profileNameKey],
      fallback: Constants.defaultProfileName
    )
    let proxyHost = stringValue(
      providerConfiguration[Constants.proxyHostKey],
      fallback: Constants.defaultProxyHost
    )
    let httpPort = intValue(providerConfiguration[Constants.httpPortKey])
    let mtu = intValue(providerConfiguration[Constants.tunMtuKey], fallback: Constants.defaultMTU)

    guard (1...65535).contains(httpPort) else {
      let error = packetTunnelError(
        code: 1001,
        description: "VPN 代理端口无效，无法启动隧道。"
      )
      logger.error("rejecting tunnel start because HTTP proxy port is invalid.")
      completionHandler(error)
      return
    }

    logger.log(
      "received startTunnel request for \(profileName, privacy: .public); proxy=\(proxyHost, privacy: .public):\(httpPort)"
    )

    Task {
      do {
        try await waitForProxyReady(host: proxyHost, port: httpPort)

        let networkSettings = buildTunnelNetworkSettings(
          proxyHost: proxyHost,
          httpPort: httpPort,
          mtu: mtu
        )
        try await applyNetworkSettings(networkSettings)

        activeProfileName = profileName
        activeProxyHost = proxyHost
        activeHTTPPort = httpPort
        startHealthMonitor()

        logger.log("packet tunnel started for \(profileName, privacy: .public)")
        completionHandler(nil)
      } catch {
        logger.error("packet tunnel start failed: \(error.localizedDescription, privacy: .public)")
        completionHandler(error)
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    healthMonitorTask?.cancel()
    healthMonitorTask = nil
    logger.log("stopTunnel called with reason \(String(describing: reason), privacy: .public)")
    completionHandler()
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    let payload: [String: Any] = [
      "ok": true,
      "profileName": activeProfileName,
      "proxyHost": activeProxyHost,
      "httpPort": activeHTTPPort,
    ]

    let response = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    completionHandler?(response)
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    logger.log("provider entering sleep state")
    completionHandler()
  }

  override func wake() {
    logger.log("provider woke up")
  }

  private func buildTunnelNetworkSettings(
    proxyHost: String,
    httpPort: Int,
    mtu: Int
  ) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(
      tunnelRemoteAddress: Constants.tunnelRemoteAddress
    )
    settings.mtu = NSNumber(value: mtu)

    let ipv4Settings = NEIPv4Settings(
      addresses: [Constants.tunnelIPv4Address],
      subnetMasks: [Constants.tunnelIPv4Mask]
    )
    ipv4Settings.includedRoutes = []
    settings.ipv4Settings = ipv4Settings

    let ipv6Settings = NEIPv6Settings(
      addresses: [Constants.tunnelIPv6Address],
      networkPrefixLengths: [NSNumber(value: Constants.tunnelIPv6Prefix)]
    )
    ipv6Settings.includedRoutes = []
    settings.ipv6Settings = ipv6Settings

    let proxyServer = NEProxyServer(address: proxyHost, port: httpPort)
    let proxySettings = NEProxySettings()
    proxySettings.autoProxyConfigurationEnabled = false
    proxySettings.excludeSimpleHostnames = true
    proxySettings.matchDomains = [""]
    proxySettings.exceptionList = ["localhost", "127.0.0.1", "::1", "*.local"]
    proxySettings.httpEnabled = true
    proxySettings.httpsEnabled = true
    proxySettings.httpServer = proxyServer
    proxySettings.httpsServer = proxyServer
    settings.proxySettings = proxySettings

    return settings
  }

  private func applyNetworkSettings(_ settings: NEPacketTunnelNetworkSettings) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      setTunnelNetworkSettings(settings) { error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        continuation.resume()
      }
    }
  }

  private func waitForProxyReady(host: String, port: Int) async throws {
    let deadline = Date().addingTimeInterval(Constants.proxyReadyTimeoutSeconds)

    while Date() < deadline {
      if isLocalTCPPortReachable(host: host, port: port) {
        return
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }

    throw packetTunnelError(
      code: 1002,
      description: "本地 Xray HTTP 代理还没有就绪，VPN 未启动。"
    )
  }

  private func startHealthMonitor() {
    healthMonitorTask?.cancel()
    let host = activeProxyHost
    let port = activeHTTPPort

    healthMonitorTask = Task.detached(priority: .utility) { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: Constants.healthcheckIntervalNanoseconds)
        if Task.isCancelled {
          return
        }

        if !self.isLocalTCPPortReachable(host: host, port: port) {
          let error = self.packetTunnelError(
            code: 1003,
            description: "本地 Xray 代理已停止响应，VPN 隧道将断开。"
          )
          self.logger.error("local proxy became unavailable; cancelling tunnel.")
          self.cancelTunnelWithError(error)
          return
        }
      }
    }
  }

  private func isLocalTCPPortReachable(host: String, port: Int) -> Bool {
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else {
      return false
    }
    defer {
      close(socketDescriptor)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)

    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
      return false
    }

    var socketAddress = address
    let result = withUnsafePointer(to: &socketAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(
          socketDescriptor,
          sockaddrPointer,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        )
      }
    }

    return result == 0
  }

  private func stringValue(_ value: Any?, fallback: String) -> String {
    let normalized = String(describing: value ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? fallback : normalized
  }

  private func intValue(_ value: Any?, fallback: Int = 0) -> Int {
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = value as? String, let parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return parsed
    }
    return fallback
  }

  private func packetTunnelError(code: Int, description: String) -> NSError {
    NSError(
      domain: "XrayGui.PacketTunnel",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: description]
    )
  }
}
