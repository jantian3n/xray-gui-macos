import Darwin
import Foundation

enum NativeRuntimeState: String {
  case idle
  case starting
  case running
  case stopping
  case stopped
  case error

  var label: String {
    switch self {
    case .idle:
      return "空闲"
    case .starting:
      return "启动中"
    case .running:
      return "运行中"
    case .stopping:
      return "停止中"
    case .stopped:
      return "已停止"
    case .error:
      return "异常"
    }
  }
}

struct NativeRuntimeLaunchInfo {
  let xrayBinaryPath: String
  let geodataDirectoryPath: String
}

enum NativeAppDirectories {
  static func baseDirectoryURL() throws -> URL {
    let supportURL = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let baseURL = supportURL.appendingPathComponent("xray_gui", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    return baseURL
  }
}

@MainActor
final class NativeRuntimeService {
  private enum Constants {
    static let geodataFiles = ["geoip.dat", "geosite.dat"]
    static let xrayLocationAssetEnv = "XRAY_LOCATION_ASSET"
    static let xrayBinaryEnv = "XRAY_GUI_XRAY_BINARY"
    static let assetRootEnv = "XRAY_GUI_ASSET_ROOT"
  }

  private let baseDirectoryURL: URL
  private let fileManager = FileManager.default
  private let stateDidChange: (NativeRuntimeState) -> Void
  private let logDidEmit: (String) -> Void
  private let profileEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private var process: Process?
  private var stdoutTask: Task<Void, Never>?
  private var stderrTask: Task<Void, Never>?
  private var activeProfile: NativeProfile?
  private var stopRequested = false
  private var systemProxyManager: NativeMacosSystemProxyManager?
  private(set) var state: NativeRuntimeState = .idle

  init(
    baseDirectoryURL: URL,
    stateDidChange: @escaping (NativeRuntimeState) -> Void,
    logDidEmit: @escaping (String) -> Void
  ) {
    self.baseDirectoryURL = baseDirectoryURL
    self.stateDidChange = stateDidChange
    self.logDidEmit = logDidEmit
  }

  func initialize() throws {
    let layout = try prepareLayout()
    let systemProxyManager = NativeMacosSystemProxyManager(
      runtimeDirectoryURL: layout.runtimeDirectoryURL,
      emit: emit
    )
    self.systemProxyManager = systemProxyManager
    try systemProxyManager.restoreStaleSnapshotIfNeeded()
  }

  func start(profile: NativeProfile, config: [String: Any]) async throws -> NativeRuntimeLaunchInfo {
    try initialize()
    await stop()

    let layout = try prepareLayout()
    let xrayBinaryURL = try resolveXrayBinary(layout: layout)
    let configURL = layout.runtimeDirectoryURL.appendingPathComponent("config.json")
    let profileURL = layout.runtimeDirectoryURL.appendingPathComponent("profile.json")

    let configData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    try configData.write(to: configURL, options: .atomic)
    try profileEncoder.encode(profile).write(to: profileURL, options: .atomic)

    emit("wrote config to \(configURL.path)")
    emit("using geodata at \(layout.geodataDirectoryURL.path)")
    emit("using xray binary at \(xrayBinaryURL.path)")

    let stdout = Pipe()
    let stderr = Pipe()
    let process = Process()
    process.executableURL = xrayBinaryURL
    process.arguments = ["run", "-c", configURL.path]
    process.currentDirectoryURL = layout.runtimeDirectoryURL
    process.environment = ProcessInfo.processInfo.environment.merging([
      Constants.xrayLocationAssetEnv: layout.geodataDirectoryURL.path,
    ]) { _, new in new }
    process.standardOutput = stdout
    process.standardError = stderr

    activeProfile = profile
    stopRequested = false
    setState(.starting)

    process.terminationHandler = { [weak self] process in
      Task { @MainActor in
        await self?.handleTermination(of: process)
      }
    }

    do {
      try process.run()
      self.process = process
      stdoutTask = startLogRelay(handle: stdout.fileHandleForReading, prefix: "")
      stderrTask = startLogRelay(handle: stderr.fileHandleForReading, prefix: "stderr: ")

      if profile.runtimeMode == .systemProxy {
        try systemProxyManager?.enable(profile: profile)
      }

      setState(.running)
      return NativeRuntimeLaunchInfo(
        xrayBinaryPath: xrayBinaryURL.path,
        geodataDirectoryPath: layout.geodataDirectoryURL.path
      )
    } catch {
      if process.isRunning {
        process.terminate()
      }
      self.process = nil
      activeProfile = nil
      cancelLogTasks()
      setState(.error)
      throw error
    }
  }

  func stop() async {
    guard let process else {
      activeProfile = nil
      setState(.stopped)
      return
    }

    stopRequested = true
    setState(.stopping)
    process.terminate()

    for _ in 0..<50 {
      if self.process == nil {
        return
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    kill(process.processIdentifier, SIGKILL)

    for _ in 0..<20 {
      if self.process == nil {
        return
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func handleTermination(of process: Process) async {
    guard self.process === process else {
      return
    }

    self.process = nil
    cancelLogTasks()

    var proxyRestoreError: Error?
    do {
      try systemProxyManager?.restoreIfNeeded()
    } catch {
      proxyRestoreError = error
      emit("system-proxy-restore-error: \(error.localizedDescription)")
    }

    let wasStopRequested = stopRequested
    stopRequested = false
    activeProfile = nil

    if proxyRestoreError != nil {
      setState(.error)
    } else if process.terminationStatus == 0 {
      emit(wasStopRequested ? "xray stopped." : "xray exited normally.")
      setState(.stopped)
    } else {
      emit("xray exited with code \(process.terminationStatus).")
      setState(wasStopRequested ? .stopped : .error)
    }
  }

  private func cancelLogTasks() {
    stdoutTask?.cancel()
    stderrTask?.cancel()
    stdoutTask = nil
    stderrTask = nil
  }

  private func startLogRelay(handle: FileHandle, prefix: String) -> Task<Void, Never> {
    return Task.detached(priority: .utility) {
      do {
        for try await line in handle.bytes.lines {
          let trimmed = line.trimmed()
          if !trimmed.isEmpty {
            await MainActor.run {
              self.emit("\(prefix)\(trimmed)")
            }
          }
        }
      } catch is CancellationError {
      } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if !message.trimmed().isEmpty {
          await MainActor.run {
            self.emit("log-stream-error: \(message)")
          }
        }
      }
    }
  }

  private func prepareLayout() throws -> NativeRuntimeLayout {
    let runtimeDirectoryURL = baseDirectoryURL.appendingPathComponent("runtime", isDirectory: true)
    let geodataDirectoryURL = runtimeDirectoryURL.appendingPathComponent("geodata", isDirectory: true)
    let binaryDirectoryURL = runtimeDirectoryURL.appendingPathComponent("bin", isDirectory: true)

    try fileManager.createDirectory(at: runtimeDirectoryURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: geodataDirectoryURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: binaryDirectoryURL, withIntermediateDirectories: true)

    try installBundledGeodataIfNeeded(into: geodataDirectoryURL)

    return NativeRuntimeLayout(
      runtimeDirectoryURL: runtimeDirectoryURL,
      geodataDirectoryURL: geodataDirectoryURL,
      binaryDirectoryURL: binaryDirectoryURL
    )
  }

  private func installBundledGeodataIfNeeded(into geodataDirectoryURL: URL) throws {
    for fileName in Constants.geodataFiles {
      let targetURL = geodataDirectoryURL.appendingPathComponent(fileName)
      if fileManager.fileExists(atPath: targetURL.path),
         let attributes = try? fileManager.attributesOfItem(atPath: targetURL.path),
         (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 {
        continue
      }

      guard let sourceURL = locateAsset(relativePath: "assets/bootstrap-geodata/\(fileName)") else {
        emit("Bundled \(fileName) not found in native asset candidates.")
        continue
      }

      try copyIfNeeded(sourceURL: sourceURL, targetURL: targetURL, executable: false)
      emit("Installed bundled \(fileName) from \(sourceURL.path).")
    }
  }

  private func resolveXrayBinary(layout: NativeRuntimeLayout) throws -> URL {
    if let envPath = ProcessInfo.processInfo.environment[Constants.xrayBinaryEnv]?.trimmed(),
       !envPath.isEmpty {
      let envURL = URL(fileURLWithPath: envPath)
      guard fileManager.fileExists(atPath: envURL.path) else {
        throw NativeImportError.message("XRAY_GUI_XRAY_BINARY 指向的文件不存在: \(envURL.path)")
      }
      return envURL
    }

    guard let sourceURL = locateAsset(relativePath: "assets/bin/macos/xray") else {
      throw NativeImportError.message(
        "未找到 xray 可执行文件。请设置 XRAY_GUI_XRAY_BINARY，或确保仓库里的 assets/bin/macos/xray 可用。"
      )
    }

    let targetURL = layout.binaryDirectoryURL.appendingPathComponent("xray")
    try copyIfNeeded(sourceURL: sourceURL, targetURL: targetURL, executable: true)
    return targetURL
  }

  private func locateAsset(relativePath: String) -> URL? {
    let explicitRoot = ProcessInfo.processInfo.environment[Constants.assetRootEnv]?.trimmed()
    var baseCandidates: [URL] = []

    if let explicitRoot, !explicitRoot.isEmpty {
      baseCandidates.append(URL(fileURLWithPath: explicitRoot, isDirectory: true))
    }

    baseCandidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
    baseCandidates.append(Bundle.main.bundleURL)
    if let resourceURL = Bundle.main.resourceURL {
      baseCandidates.append(resourceURL)
    }
    if let executablePath = Bundle.main.executableURL?.deletingLastPathComponent() {
      baseCandidates.append(executablePath)
    }
    if let firstArgument = CommandLine.arguments.first {
      baseCandidates.append(URL(fileURLWithPath: firstArgument).deletingLastPathComponent())
    }

    var visited = Set<String>()
    for baseCandidate in baseCandidates {
      for candidate in ancestorDirectories(startingAt: baseCandidate, maxDepth: 10) {
        let candidateAssetURL = candidate.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: candidateAssetURL.path) {
          return candidateAssetURL
        }

        if !relativePath.hasPrefix("assets/") {
          let nestedAssetURL = candidate.appendingPathComponent("assets").appendingPathComponent(relativePath)
          if fileManager.fileExists(atPath: nestedAssetURL.path) {
            return nestedAssetURL
          }
        }

        visited.insert(candidate.path)
      }
    }

    return nil
  }

  private func ancestorDirectories(startingAt url: URL, maxDepth: Int) -> [URL] {
    var directories: [URL] = []
    var currentURL = url.standardizedFileURL
    for _ in 0..<maxDepth {
      directories.append(currentURL)
      let nextURL = currentURL.deletingLastPathComponent()
      if nextURL.path == currentURL.path {
        break
      }
      currentURL = nextURL
    }
    return directories
  }

  private func copyIfNeeded(sourceURL: URL, targetURL: URL, executable: Bool) throws {
    try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let sourceAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
    let sourceSize = (sourceAttributes[.size] as? NSNumber)?.intValue ?? 0
    let sourceDate = sourceAttributes[.modificationDate] as? Date ?? .distantPast

    if fileManager.fileExists(atPath: targetURL.path) {
      let targetAttributes = try fileManager.attributesOfItem(atPath: targetURL.path)
      let targetSize = (targetAttributes[.size] as? NSNumber)?.intValue ?? 0
      let targetDate = targetAttributes[.modificationDate] as? Date ?? .distantPast

      if sourceSize == targetSize && abs(sourceDate.timeIntervalSince1970 - targetDate.timeIntervalSince1970) < 1 {
        if executable {
          try setExecutablePermission(url: targetURL)
        }
        return
      }

      try fileManager.removeItem(at: targetURL)
    }

    try fileManager.copyItem(at: sourceURL, to: targetURL)
    if executable {
      try setExecutablePermission(url: targetURL)
    }
  }

  private func setExecutablePermission(url: URL) throws {
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func setState(_ newState: NativeRuntimeState) {
    state = newState
    stateDidChange(newState)
    emit("state=\(newState.rawValue)")
  }

  private func emit(_ message: String) {
    logDidEmit(message)
  }
}

private struct NativeRuntimeLayout {
  let runtimeDirectoryURL: URL
  let geodataDirectoryURL: URL
  let binaryDirectoryURL: URL
}
