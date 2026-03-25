import XCTest
@testable import xray_gui

final class RunnerTests: XCTestCase {
  func testSystemProxyEnableTurnsProxyStatesOn() throws {
    let runtimeDirectoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: runtimeDirectoryURL,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: runtimeDirectoryURL) }

    let serviceOutput = """
    An asterisk (*) denotes that a network service is disabled.
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)
    """
    let disabledProxyOutput = """
    Enabled: No
    Server:
    Port: 0
    Authenticated Proxy Enabled: 0
    """
    let emptyBypassOutput = "There aren't any bypass domains set on Wi-Fi.\n"

    var recordedCommands: [[String]] = []
    let runner: NativeMacosSystemProxyManager.NetworksetupRunner = { arguments in
      recordedCommands.append(arguments)
      switch arguments.first {
      case "-listnetworkserviceorder":
        return serviceOutput
      case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
        return disabledProxyOutput
      case "-getproxybypassdomains":
        return emptyBypassOutput
      default:
        return ""
      }
    }

    let manager = NativeMacosSystemProxyManager(
      runtimeDirectoryURL: runtimeDirectoryURL,
      emit: { _ in },
      networksetupRunner: runner
    )
    let profile = NativeProfile.from(
      node: NativeVlessNode(
        name: "Sample",
        address: "example.com",
        port: 443,
        id: "11111111-2222-3333-4444-555555555555",
        network: "tcp",
        security: "tls",
        serverName: "example.com",
        fingerprint: "chrome"
      )
    )

    try manager.enable(profile: profile)

    XCTAssertTrue(recordedCommands.contains(["-setwebproxystate", "Wi-Fi", "on"]))
    XCTAssertTrue(recordedCommands.contains(["-setsecurewebproxystate", "Wi-Fi", "on"]))
    XCTAssertTrue(recordedCommands.contains(["-setsocksfirewallproxystate", "Wi-Fi", "on"]))
  }

  func testPacketTunnelBundleIdentifierFollowsAppBundleIdentifier() {
    XCTAssertEqual(
      NativePacketTunnelService.packetTunnelBundleIdentifier(
        forAppBundleIdentifier: "dev.example.xray"
      ),
      "dev.example.xray.PacketTunnel"
    )
    XCTAssertEqual(
      NativePacketTunnelService.packetTunnelBundleIdentifier(forAppBundleIdentifier: nil),
      "com.example.xrayGui.PacketTunnel"
    )
  }

  func testParseXrayVersionAndCompareSemanticVersions() {
    XCTAssertEqual(
      NativeRuntimeAssetService.parseXrayVersion(
        from: "Xray 26.3.23 (Xray, Penetrates Everything.) Custom (go1.24.0 darwin/arm64)\n"
      ),
      "26.3.23"
    )
    XCTAssertEqual(NativeRuntimeAssetService.normalizeVersionString("v26.2.6"), "26.2.6")
    XCTAssertTrue(NativeVersion("26.3.23")! > NativeVersion("26.2.6")!)
    XCTAssertTrue(NativeVersion("26.2.6")! == NativeVersion("v26.2.6")!)
  }

  func testParseReleaseChecksumFormats() throws {
    let digestText = """
    SHA2-256= 0123456789abcdef
    SHA2-512= deadbeef
    """
    XCTAssertEqual(
      try NativeRuntimeAssetService.parseSHA256Digest(from: digestText),
      "0123456789abcdef"
    )

    let checksumText = """
    abcdef0123456789 *geoip.dat
    1234567890abcdef *geosite.dat
    """
    XCTAssertEqual(
      try NativeRuntimeAssetService.parseChecksumFile(checksumText, expectedFileName: "geoip.dat"),
      "abcdef0123456789"
    )
    XCTAssertEqual(
      try NativeRuntimeAssetService.parseChecksumFile(checksumText, expectedFileName: "geosite.dat"),
      "1234567890abcdef"
    )
  }
}
