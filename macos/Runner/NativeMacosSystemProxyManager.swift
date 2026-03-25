import Foundation

final class NativeMacosSystemProxyManager {
  typealias NetworksetupRunner = ([String]) throws -> String

  private let decoder = JSONDecoder()
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private let emit: (String) -> Void
  private let snapshotURL: URL
  private let fileManager = FileManager.default
  private let networksetupRunner: NetworksetupRunner

  init(
    runtimeDirectoryURL: URL,
    emit: @escaping (String) -> Void,
    networksetupRunner: NetworksetupRunner? = nil
  ) {
    self.emit = emit
    snapshotURL = runtimeDirectoryURL.appendingPathComponent("system_proxy_snapshot.json")
    self.networksetupRunner = networksetupRunner ?? Self.defaultNetworksetupRunner
  }

  func restoreStaleSnapshotIfNeeded() throws {
    guard fileManager.fileExists(atPath: snapshotURL.path) else {
      return
    }

    emit("found stale macOS system proxy snapshot, restoring previous settings")
    try restoreSnapshot(loadSnapshot())
    try deleteSnapshotIfNeeded()
  }

  func enable(profile: NativeProfile) throws {
    let services = try listManagedServices()
    guard !services.isEmpty else {
      throw NativeImportError.message("没有找到可写入系统代理的 macOS 网络服务。")
    }

    let snapshot = try captureSnapshot(services: services)
    try assertRestorable(snapshot: snapshot)
    try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)

    for serviceState in snapshot.services {
      emit("enabling macOS system proxy on \(serviceState.name) (\(serviceState.device))")
      try runNetworksetup(arguments: [
        "-setwebproxy",
        serviceState.name,
        "127.0.0.1",
        String(profile.httpPort),
        "off",
      ])
      try runNetworksetup(arguments: ["-setwebproxystate", serviceState.name, "on"])
      try runNetworksetup(arguments: [
        "-setsecurewebproxy",
        serviceState.name,
        "127.0.0.1",
        String(profile.httpPort),
        "off",
      ])
      try runNetworksetup(arguments: ["-setsecurewebproxystate", serviceState.name, "on"])
      try runNetworksetup(arguments: [
        "-setsocksfirewallproxy",
        serviceState.name,
        "127.0.0.1",
        String(profile.socksPort),
        "off",
      ])
      try runNetworksetup(arguments: ["-setsocksfirewallproxystate", serviceState.name, "on"])
      try runNetworksetup(arguments: [
        "-setproxybypassdomains",
        serviceState.name,
      ] + managedBypassDomains(current: serviceState.bypassDomains))
    }

    emit("macOS system proxy enabled on \(snapshot.services.count) network services.")
  }

  func restoreIfNeeded() throws {
    guard fileManager.fileExists(atPath: snapshotURL.path) else {
      return
    }

    try restoreSnapshot(loadSnapshot())
    try deleteSnapshotIfNeeded()
  }

  private func loadSnapshot() throws -> MacosProxySnapshot {
    let data = try Data(contentsOf: snapshotURL)
    return try decoder.decode(MacosProxySnapshot.self, from: data)
  }

  private func restoreSnapshot(_ snapshot: MacosProxySnapshot) throws {
    for serviceState in snapshot.services {
      emit("restoring macOS proxy settings on \(serviceState.name) (\(serviceState.device))")
      try restoreProxy(serviceName: serviceState.name, kind: .web, setting: serviceState.web)
      try restoreProxy(serviceName: serviceState.name, kind: .secureWeb, setting: serviceState.secureWeb)
      try restoreProxy(serviceName: serviceState.name, kind: .socks, setting: serviceState.socks)
      try runNetworksetup(arguments: [
        "-setproxybypassdomains",
        serviceState.name,
      ] + restoreBypassDomains(serviceState.bypassDomains))
    }

    emit("macOS system proxy restored.")
  }

  private func restoreProxy(serviceName: String, kind: ProxyKind, setting: MacosProxySetting) throws {
    if setting.authenticated {
      throw NativeImportError.message(
        "检测到已开启认证代理的系统设置，当前版本不会覆盖它，请先手动恢复原始代理设置。"
      )
    }

    if !setting.enabled {
      try runNetworksetup(arguments: [stateFlag(kind), serviceName, "off"])
      return
    }

    try runNetworksetup(arguments: [
      setFlag(kind),
      serviceName,
      setting.server,
      String(setting.port),
      "off",
    ])
    try runNetworksetup(arguments: [stateFlag(kind), serviceName, "on"])
  }

  private func captureSnapshot(services: [MacosNetworkService]) throws -> MacosProxySnapshot {
    let states = try services.map { service in
      let webOutput = try runNetworksetup(arguments: ["-getwebproxy", service.name])
      let secureWebOutput = try runNetworksetup(arguments: ["-getsecurewebproxy", service.name])
      let socksOutput = try runNetworksetup(arguments: ["-getsocksfirewallproxy", service.name])
      let bypassOutput = try runNetworksetup(arguments: ["-getproxybypassdomains", service.name])

      return MacosNetworkServiceState(
        name: service.name,
        device: service.device,
        web: parseProxySetting(webOutput),
        secureWeb: parseProxySetting(secureWebOutput),
        socks: parseProxySetting(socksOutput),
        bypassDomains: parseBypassDomains(bypassOutput)
      )
    }

    return MacosProxySnapshot(services: states)
  }

  private func assertRestorable(snapshot: MacosProxySnapshot) throws {
    for serviceState in snapshot.services {
      for setting in [serviceState.web, serviceState.secureWeb, serviceState.socks] where setting.authenticated {
        throw NativeImportError.message(
          "检测到 \(serviceState.name) 已启用认证代理。当前版本不会覆盖这种系统代理，请先切换到“本地代理”模式或手动关闭原代理。"
        )
      }
    }
  }

  private func listManagedServices() throws -> [MacosNetworkService] {
    try parseNetworkServices(runNetworksetup(arguments: ["-listnetworkserviceorder"]))
  }

  private func parseNetworkServices(_ output: String) throws -> [MacosNetworkService] {
    let lines = output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmed() }
      .filter { !$0.isEmpty }

    let servicePattern = try NSRegularExpression(pattern: #"^\((\*|\d+)\)\s+(.+)$"#)
    let hardwarePattern = try NSRegularExpression(pattern: #"^\(Hardware Port: .*?, Device: (.*?)\)$"#)
    var services: [MacosNetworkService] = []

    for index in lines.indices {
      let currentLine = lines[index]
      guard let serviceMatch = currentLine.wholeMatch(regex: servicePattern) else {
        continue
      }

      let disabled = serviceMatch[1] == "*"
      let name = serviceMatch[2].trimmed()
      let nextLine = index + 1 < lines.count ? lines[index + 1] : ""
      let device = nextLine.wholeMatch(regex: hardwarePattern)?[1].trimmed() ?? ""

      if !disabled && !name.isEmpty && !device.isEmpty {
        services.append(MacosNetworkService(name: name, device: device))
      }
    }

    return services
  }

  private func parseProxySetting(_ output: String) -> MacosProxySetting {
    var values: [String: String] = [:]
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      guard let separator = line.firstIndex(of: ":") else {
        continue
      }
      let key = String(line[..<separator]).trimmed()
      let value = String(line[line.index(after: separator)...]).trimmed()
      values[key] = value
    }

    return MacosProxySetting(
      enabled: parseEnabled(values["Enabled"]),
      server: values["Server"] ?? "",
      port: Int(values["Port"] ?? "") ?? 0,
      authenticated: parseEnabled(values["Authenticated Proxy Enabled"])
    )
  }

  private func parseBypassDomains(_ output: String) -> [String] {
    let lines = output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmed() }
      .filter { !$0.isEmpty }

    if lines.isEmpty || lines.first?.starts(with: "There aren't any") == true {
      return []
    }

    return lines
  }

  private func parseEnabled(_ raw: String?) -> Bool {
    switch raw?.trimmed().lowercased() {
    case "yes", "on", "1", "true":
      return true
    default:
      return false
    }
  }

  private func managedBypassDomains(current: [String]) -> [String] {
    var merged = current
    for domain in ["127.0.0.1", "localhost", "::1", "*.local"] where !merged.contains(domain) {
      merged.append(domain)
    }
    return merged.isEmpty ? ["Empty"] : merged
  }

  private func restoreBypassDomains(_ domains: [String]) -> [String] {
    domains.isEmpty ? ["Empty"] : domains
  }

  private func setFlag(_ kind: ProxyKind) -> String {
    switch kind {
    case .web:
      return "-setwebproxy"
    case .secureWeb:
      return "-setsecurewebproxy"
    case .socks:
      return "-setsocksfirewallproxy"
    }
  }

  private func stateFlag(_ kind: ProxyKind) -> String {
    switch kind {
    case .web:
      return "-setwebproxystate"
    case .secureWeb:
      return "-setsecurewebproxystate"
    case .socks:
      return "-setsocksfirewallproxystate"
    }
  }

  @discardableResult
  private func runNetworksetup(arguments: [String]) throws -> String {
    try networksetupRunner(arguments)
  }

  private static func defaultNetworksetupRunner(arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if process.terminationStatus != 0 {
      throw ProcessExecutionError(
        command: "/usr/sbin/networksetup",
        arguments: arguments,
        message: errorOutput.trimmed().isEmpty ? output.trimmed() : errorOutput.trimmed(),
        code: Int(process.terminationStatus)
      )
    }
    return output
  }

  private func deleteSnapshotIfNeeded() throws {
    guard fileManager.fileExists(atPath: snapshotURL.path) else {
      return
    }
    try fileManager.removeItem(at: snapshotURL)
  }
}

private enum ProxyKind {
  case web
  case secureWeb
  case socks
}

private struct MacosNetworkService {
  let name: String
  let device: String
}

private struct MacosProxySnapshot: Codable {
  let services: [MacosNetworkServiceState]
}

private struct MacosNetworkServiceState: Codable {
  let name: String
  let device: String
  let web: MacosProxySetting
  let secureWeb: MacosProxySetting
  let socks: MacosProxySetting
  let bypassDomains: [String]
}

private struct MacosProxySetting: Codable {
  let enabled: Bool
  let server: String
  let port: Int
  let authenticated: Bool
}

private struct ProcessExecutionError: LocalizedError {
  let command: String
  let arguments: [String]
  let message: String
  let code: Int

  var errorDescription: String? {
    let summary = message.trimmed().isEmpty ? "exit \(code)" : message.trimmed()
    return "\(command) \(arguments.joined(separator: " ")) failed: \(summary)"
  }
}

private extension String {
  func wholeMatch(regex: NSRegularExpression) -> [String]? {
    let range = NSRange(startIndex..<endIndex, in: self)
    guard let match = regex.firstMatch(in: self, options: [], range: range),
          match.range.location != NSNotFound,
          match.range.length == range.length else {
      return nil
    }

    return (0..<match.numberOfRanges).compactMap { index in
      let captureRange = match.range(at: index)
      guard let swiftRange = Range(captureRange, in: self) else {
        return nil
      }
      return String(self[swiftRange])
    }
  }
}
