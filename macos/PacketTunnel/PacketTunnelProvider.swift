import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let logger = Logger(
    subsystem: "com.example.xrayGui.PacketTunnel",
    category: "PacketTunnel"
  )

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol
    let providerConfiguration = tunnelProtocol?.providerConfiguration ?? [:]
    let profileName = providerConfiguration["profileName"] as? String ?? "Unknown Profile"

    logger.log("received startTunnel request for \(profileName, privacy: .public)")

    let error = NSError(
      domain: "XrayGui.PacketTunnel",
      code: 1001,
      userInfo: [
        NSLocalizedDescriptionKey: "Packet Tunnel 数据面还没有迁移完成。这一版先把宿主和扩展的控制面打通，避免启动后直接黑洞你的系统流量。"
      ]
    )

    logger.error("rejecting tunnel start: \(error.localizedDescription, privacy: .public)")
    completionHandler(error)
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    logger.log("stopTunnel called with reason \(String(describing: reason), privacy: .public)")
    completionHandler()
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    let response = """
    {"ok":true,"message":"packet tunnel extension scaffold is alive"}
    """
    completionHandler?(response.data(using: .utf8))
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    logger.log("provider entering sleep state")
    completionHandler()
  }

  override func wake() {
    logger.log("provider woke up")
  }
}
