import Foundation
@preconcurrency import NetworkExtension

enum NativePacketTunnelStatus: String {
  case notInstalled
  case installing
  case ready
  case connecting
  case connected
  case disconnecting
  case reasserting
  case invalid
  case failed

  var label: String {
    switch self {
    case .notInstalled:
      return "未安装"
    case .installing:
      return "配置中"
    case .ready:
      return "已就绪"
    case .connecting:
      return "连接中"
    case .connected:
      return "已连接"
    case .disconnecting:
      return "断开中"
    case .reasserting:
      return "重连中"
    case .invalid:
      return "配置无效"
    case .failed:
      return "异常"
    }
  }
}

enum NativePacketTunnelError: LocalizedError {
  case managerNotFound
  case invalidTunnelConfiguration

  var errorDescription: String? {
    switch self {
    case .managerNotFound:
      return "还没有创建 Packet Tunnel 配置。"
    case .invalidTunnelConfiguration:
      return "当前 Packet Tunnel 配置无效。"
    }
  }
}

@MainActor
final class NativePacketTunnelService {
  private enum Constants {
    static let localizedDescription = "Xray GUI Packet Tunnel"
    static let providerBundleSuffix = ".PacketTunnel"
    static let providerConfigProfileName = "profileName"
    static let providerConfigProfileIdentifier = "profileIdentifier"
    static let providerConfigRoutingPreset = "routingPreset"
    static let providerConfigRuntimeMode = "runtimeMode"
    static let providerConfigConfigJSON = "configJSON"
    static let providerConfigGeneratedAt = "generatedAt"
    static let providerConfigTunMtu = "tunMtu"
    static let providerConfigProxyHost = "proxyHost"
    static let providerConfigHTTPPort = "httpPort"
    static let providerConfigSOCKSPort = "socksPort"
    static let localhost = "127.0.0.1"
  }

  private let stateDidChange: (NativePacketTunnelStatus) -> Void
  private let logDidEmit: (String) -> Void
  private let iso8601Formatter = ISO8601DateFormatter()

  private var manager: NETunnelProviderManager?
  private var statusObserver: NSObjectProtocol?
  private(set) var status: NativePacketTunnelStatus = .notInstalled

  init(
    stateDidChange: @escaping (NativePacketTunnelStatus) -> Void,
    logDidEmit: @escaping (String) -> Void
  ) {
    self.stateDidChange = stateDidChange
    self.logDidEmit = logDidEmit
  }

  deinit {
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
  }

  var providerBundleIdentifier: String {
    Self.packetTunnelBundleIdentifier(forAppBundleIdentifier: Bundle.main.bundleIdentifier)
  }

  nonisolated static func packetTunnelBundleIdentifier(forAppBundleIdentifier appBundleIdentifier: String?) -> String {
    let trimmedIdentifier = appBundleIdentifier?.trimmed()
    let baseIdentifier = (trimmedIdentifier?.isEmpty == false)
      ? trimmedIdentifier!
      : "com.example.xrayGui"
    return "\(baseIdentifier)\(Constants.providerBundleSuffix)"
  }

  func refresh() async {
    do {
      let manager = try await loadManager(createIfMissing: false)
      self.manager = manager
      attachStatusObserver(to: manager)
      setStatus(status(from: manager.connection.status, installed: true))
      emit("packet tunnel manager refreshed.")
    } catch NativePacketTunnelError.managerNotFound {
      manager = nil
      setStatus(.notInstalled)
    } catch {
      emit("packet tunnel refresh failed: \(localizedMessage(for: error))")
      setStatus(.failed)
    }
  }

  func installOrUpdate(profile: NativeProfile, config: [String: Any]) async throws {
    setStatus(.installing)
    let manager = try await loadManager(createIfMissing: true)
    let configData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    let configJSONString = String(decoding: configData, as: UTF8.self)

    let tunnelProtocol = NETunnelProviderProtocol()
    tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
    tunnelProtocol.serverAddress = profile.node.address
    tunnelProtocol.providerConfiguration = [
      Constants.providerConfigProfileName: profile.name,
      Constants.providerConfigProfileIdentifier: profile.id,
      Constants.providerConfigRoutingPreset: profile.routingPreset.rawValue,
      Constants.providerConfigRuntimeMode: profile.runtimeMode.rawValue,
      Constants.providerConfigConfigJSON: configJSONString,
      Constants.providerConfigGeneratedAt: iso8601Formatter.string(from: Date()),
      Constants.providerConfigTunMtu: profile.tunMtu,
      Constants.providerConfigProxyHost: Constants.localhost,
      Constants.providerConfigHTTPPort: profile.httpPort,
      Constants.providerConfigSOCKSPort: profile.socksPort,
    ]

    manager.localizedDescription = Constants.localizedDescription
    manager.protocolConfiguration = tunnelProtocol
    manager.isEnabled = true

    try await saveToPreferences(manager)
    try await loadFromPreferences(manager)

    self.manager = manager
    attachStatusObserver(to: manager)
    emit("packet tunnel configuration saved for \(profile.name).")
    setStatus(status(from: manager.connection.status, installed: true))
  }

  func start(profile: NativeProfile, config: [String: Any]) async throws {
    try await installOrUpdate(profile: profile, config: config)

    guard let manager else {
      throw NativePacketTunnelError.invalidTunnelConfiguration
    }

    do {
      try manager.connection.startVPNTunnel()
      emit("packet tunnel start requested.")
      setStatus(.connecting)
    } catch {
      emit("packet tunnel start failed: \(localizedMessage(for: error))")
      setStatus(.failed)
      throw error
    }
  }

  func stop() async {
    guard let manager else {
      setStatus(.notInstalled)
      return
    }

    emit("packet tunnel stop requested.")
    manager.connection.stopVPNTunnel()
    setStatus(.disconnecting)
  }

  private func loadManager(createIfMissing: Bool) async throws -> NETunnelProviderManager {
    let managers = try await loadAllFromPreferences()
    if let existingManager = managers.first(where: { manager in
      if manager.localizedDescription == Constants.localizedDescription {
        return true
      }

      let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol
      return tunnelProtocol?.providerBundleIdentifier == providerBundleIdentifier
    }) {
      return existingManager
    }

    if createIfMissing {
      return NETunnelProviderManager()
    }

    throw NativePacketTunnelError.managerNotFound
  }

  private func attachStatusObserver(to manager: NETunnelProviderManager) {
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }

    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: manager.connection,
      queue: .main
    ) { [weak self] notification in
      let vpnStatus = (notification.object as? NEVPNConnection)?.status ?? .invalid
      Task { @MainActor in
        guard let self else {
          return
        }

        let nextStatus = self.status(from: vpnStatus, installed: true)
        self.emit("packet tunnel status changed: \(nextStatus.label)")
        self.setStatus(nextStatus)
      }
    }
  }

  private func status(from vpnStatus: NEVPNStatus, installed: Bool) -> NativePacketTunnelStatus {
    switch vpnStatus {
    case .invalid:
      return installed ? .invalid : .notInstalled
    case .disconnected:
      return installed ? .ready : .notInstalled
    case .connecting:
      return .connecting
    case .connected:
      return .connected
    case .reasserting:
      return .reasserting
    case .disconnecting:
      return .disconnecting
    @unknown default:
      return .failed
    }
  }

  private func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
    try await withCheckedThrowingContinuation { continuation in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        continuation.resume(returning: managers ?? [])
      }
    }
  }

  private func loadFromPreferences(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.loadFromPreferences { error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        continuation.resume()
      }
    }
  }

  private func saveToPreferences(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.saveToPreferences { error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        continuation.resume()
      }
    }
  }

  private func setStatus(_ nextStatus: NativePacketTunnelStatus) {
    status = nextStatus
    stateDidChange(nextStatus)
  }

  private func emit(_ message: String) {
    logDidEmit(message)
  }

  private func localizedMessage(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
