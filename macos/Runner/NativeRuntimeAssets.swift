import CFNetwork
import CryptoKit
import Foundation

struct NativeRuntimeAssetStatus {
  let currentXrayVersion: String?
  let currentXraySourceLabel: String
  let currentXrayPath: String?
  let latestXrayVersion: String?
  let latestXrayReleaseTag: String?
  let installedGeodataSourceLabel: String
  let installedGeodataReleaseTag: String?
  let installedGeodataUpdatedAt: Date?
  let latestGeodataReleaseTag: String?

  var currentXrayVersionLabel: String {
    currentXrayVersion ?? "未检测到"
  }

  var latestXrayVersionLabel: String {
    latestXrayVersion ?? "未获取"
  }

  var installedGeodataReleaseLabel: String {
    installedGeodataReleaseTag ?? "内置基线"
  }

  var latestGeodataReleaseLabel: String {
    latestGeodataReleaseTag ?? "未获取"
  }
}

enum NativeBundledAssetLocator {
  static func locate(relativePath: String, fileManager: FileManager = .default) -> URL? {
    let explicitRoot = ProcessInfo.processInfo.environment["XRAY_GUI_ASSET_ROOT"]?.trimmed()
    var baseCandidates: [URL] = []

    if let explicitRoot, !explicitRoot.isEmpty {
      baseCandidates.append(URL(fileURLWithPath: explicitRoot, isDirectory: true))
    }

    if let resourceURL = Bundle.main.resourceURL {
      baseCandidates.append(resourceURL)
    }
    baseCandidates.append(Bundle.main.bundleURL)
    if let executablePath = Bundle.main.executableURL?.deletingLastPathComponent() {
      baseCandidates.append(executablePath)
    }
    if let firstArgument = CommandLine.arguments.first {
      baseCandidates.append(URL(fileURLWithPath: firstArgument).deletingLastPathComponent())
    }
    baseCandidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))

    var visited = Set<String>()
    for baseCandidate in baseCandidates {
      for candidate in ancestorDirectories(startingAt: baseCandidate, maxDepth: 10) {
        if visited.contains(candidate.path) {
          continue
        }

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

  private static func ancestorDirectories(startingAt url: URL, maxDepth: Int) -> [URL] {
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
}

final class NativeRuntimeAssetService {
  private enum Constants {
    static let xrayBinaryEnv = "XRAY_GUI_XRAY_BINARY"
    static let geodataFiles = ["geoip.dat", "geosite.dat"]
    static let metadataFileName = "managed_runtime_assets.v1.json"
    static let xrayReleaseAPI = URL(string: "https://api.github.com/repos/XTLS/Xray-core/releases/latest")!
    static let xrayZipAssetName = "Xray-macos-arm64-v8a.zip"
    static let xrayDigestAssetName = "Xray-macos-arm64-v8a.zip.dgst"
    static let geodataReleaseAPI = URL(string: "https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases/latest")!
    static let httpUserAgent = "xray-gui-macos/1.0"
  }

  private enum XrayBinarySource {
    case environment(URL)
    case managed(URL)
    case bundled(URL)
    case missing

    var url: URL? {
      switch self {
      case .environment(let url), .managed(let url), .bundled(let url):
        return url
      case .missing:
        return nil
      }
    }

    var label: String {
      switch self {
      case .environment:
        return "环境变量覆盖"
      case .managed:
        return "应用支持目录(受管更新)"
      case .bundled:
        return "App 内置资源"
      case .missing:
        return "未找到"
      }
    }
  }

  private let baseDirectoryURL: URL
  private let fileManager = FileManager.default
  private let emit: (String) -> Void
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  init(baseDirectoryURL: URL, emit: @escaping (String) -> Void) {
    self.baseDirectoryURL = baseDirectoryURL
    self.emit = emit
  }

  func refreshStatus(checkRemote: Bool, proxyPort: Int?) async throws -> NativeRuntimeAssetStatus {
    var latestXrayRelease: GitHubRelease?
    var latestGeodataRelease: GitHubRelease?

    if checkRemote {
      do {
        latestXrayRelease = try await fetchLatestRelease(
          from: Constants.xrayReleaseAPI,
          proxyPort: proxyPort
        )
      } catch {
        emit("runtime-assets: failed to fetch latest Xray release: \(localizedMessage(for: error))")
      }

      do {
        latestGeodataRelease = try await fetchLatestRelease(
          from: Constants.geodataReleaseAPI,
          proxyPort: proxyPort
        )
      } catch {
        emit("runtime-assets: failed to fetch latest geodata release: \(localizedMessage(for: error))")
      }
    }

    return try buildStatus(
      latestXrayRelease: latestXrayRelease,
      latestGeodataRelease: latestGeodataRelease
    )
  }

  func updateXrayCore(proxyPort: Int?) async throws -> NativeRuntimeAssetStatus {
    let latestRelease = try await fetchLatestRelease(
      from: Constants.xrayReleaseAPI,
      proxyPort: proxyPort
    )
    let zipAsset = try latestRelease.requiredAsset(named: Constants.xrayZipAssetName)
    let digestAsset = try latestRelease.requiredAsset(named: Constants.xrayDigestAssetName)

    let targetVersion = Self.normalizeVersionString(latestRelease.tagName)
    let currentVersion = try currentXrayVersion()
    if let currentVersion,
       let current = NativeVersion(currentVersion),
       let latest = NativeVersion(targetVersion),
       current >= latest {
      emit("runtime-assets: skip Xray update because current version \(currentVersion) is not older than stable \(targetVersion)")
      return try buildStatus(latestXrayRelease: latestRelease, latestGeodataRelease: nil)
    }

    let tempDirectoryURL = try createTemporaryDirectory(prefix: "xray-update")
    defer { try? fileManager.removeItem(at: tempDirectoryURL) }

    let zipURL = tempDirectoryURL.appendingPathComponent(zipAsset.name)
    let digestURL = URL(string: digestAsset.downloadURL)!
    let zipAssetURL = URL(string: zipAsset.downloadURL)!

    emit("runtime-assets: downloading \(zipAsset.name)")
    try await downloadFile(from: zipAssetURL, to: zipURL, proxyPort: proxyPort)

    let digestText = try await downloadText(from: digestURL, proxyPort: proxyPort)
    let expectedDigest = try Self.parseSHA256Digest(from: digestText)
    let actualDigest = try sha256(for: zipURL)
    guard actualDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
      throw NativeImportError.message(
        "Xray 内核压缩包校验失败。expected=\(expectedDigest) actual=\(actualDigest)"
      )
    }

    let unzipDirectoryURL = tempDirectoryURL.appendingPathComponent("unzipped", isDirectory: true)
    try fileManager.createDirectory(at: unzipDirectoryURL, withIntermediateDirectories: true)
    _ = try runProcess(
      executablePath: "/usr/bin/ditto",
      arguments: ["-x", "-k", zipURL.path, unzipDirectoryURL.path]
    )

    let extractedBinaryURL = try findFile(named: "xray", under: unzipDirectoryURL)
    let managedBinaryURL = self.managedBinaryURL
    try installExecutable(sourceURL: extractedBinaryURL, targetURL: managedBinaryURL)

    let installedVersion = try versionString(for: managedBinaryURL) ?? targetVersion
    var metadata = try loadMetadata()
    metadata.xray = ManagedXrayMetadata(
      version: installedVersion,
      releaseTag: latestRelease.tagName,
      assetName: zipAsset.name,
      updatedAt: Date()
    )
    try saveMetadata(metadata)

    emit("runtime-assets: installed Xray \(installedVersion) from \(latestRelease.tagName)")
    return try buildStatus(latestXrayRelease: latestRelease, latestGeodataRelease: nil)
  }

  func updateGeodata(proxyPort: Int?) async throws -> NativeRuntimeAssetStatus {
    let latestRelease = try await fetchLatestRelease(
      from: Constants.geodataReleaseAPI,
      proxyPort: proxyPort
    )
    let existingMetadata = try loadMetadata()
    if existingMetadata.geodata?.releaseTag == latestRelease.tagName, hasManagedGeodata {
      emit("runtime-assets: skip geodata update because managed release \(latestRelease.tagName) is already installed")
      return try buildStatus(latestXrayRelease: nil, latestGeodataRelease: latestRelease)
    }

    try fileManager.createDirectory(at: managedGeodataDirectoryURL, withIntermediateDirectories: true)

    for fileName in Constants.geodataFiles {
      let asset = try latestRelease.requiredAsset(named: fileName)
      let checksumAsset = try latestRelease.requiredAsset(named: "\(fileName).sha256sum")
      let targetURL = managedGeodataDirectoryURL.appendingPathComponent(fileName)
      let tempURL = managedGeodataDirectoryURL.appendingPathComponent("\(fileName).download")
      let checksumURL = URL(string: checksumAsset.downloadURL)!
      let assetURL = URL(string: asset.downloadURL)!

      emit("runtime-assets: downloading \(fileName)")
      try await downloadFile(from: assetURL, to: tempURL, proxyPort: proxyPort)
      let checksumText = try await downloadText(from: checksumURL, proxyPort: proxyPort)
      let expectedDigest = try Self.parseChecksumFile(checksumText, expectedFileName: fileName)
      let actualDigest = try sha256(for: tempURL)
      guard actualDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
        try? fileManager.removeItem(at: tempURL)
        throw NativeImportError.message(
          "\(fileName) 校验失败。expected=\(expectedDigest) actual=\(actualDigest)"
        )
      }

      if fileManager.fileExists(atPath: targetURL.path) {
        try fileManager.removeItem(at: targetURL)
      }
      try fileManager.moveItem(at: tempURL, to: targetURL)
      emit("runtime-assets: installed \(fileName)")
    }

    var metadata = existingMetadata
    metadata.geodata = ManagedGeodataMetadata(
      releaseTag: latestRelease.tagName,
      updatedAt: Date()
    )
    try saveMetadata(metadata)

    emit("runtime-assets: geodata updated to \(latestRelease.tagName)")
    return try buildStatus(latestXrayRelease: nil, latestGeodataRelease: latestRelease)
  }

  func currentXrayVersion() throws -> String? {
    let source = try resolveXrayBinarySource()
    guard let binaryURL = source.url else {
      return nil
    }
    return try versionString(for: binaryURL)
  }

  private func buildStatus(
    latestXrayRelease: GitHubRelease?,
    latestGeodataRelease: GitHubRelease?
  ) throws -> NativeRuntimeAssetStatus {
    let metadata = try loadMetadata()
    let xraySource = try resolveXrayBinarySource()
    let xrayVersion = try xraySource.url.flatMap { try versionString(for: $0) }
    let geodataSourceLabel = hasManagedGeodata ? "应用支持目录(受管更新)" : "App 内置资源"

    return NativeRuntimeAssetStatus(
      currentXrayVersion: xrayVersion,
      currentXraySourceLabel: xraySource.label,
      currentXrayPath: xraySource.url?.path,
      latestXrayVersion: latestXrayRelease.map { Self.normalizeVersionString($0.tagName) },
      latestXrayReleaseTag: latestXrayRelease?.tagName,
      installedGeodataSourceLabel: geodataSourceLabel,
      installedGeodataReleaseTag: metadata.geodata?.releaseTag,
      installedGeodataUpdatedAt: metadata.geodata?.updatedAt,
      latestGeodataReleaseTag: latestGeodataRelease?.tagName
    )
  }

  private func resolveXrayBinarySource() throws -> XrayBinarySource {
    if let envPath = ProcessInfo.processInfo.environment[Constants.xrayBinaryEnv]?.trimmed(),
       !envPath.isEmpty {
      let envURL = URL(fileURLWithPath: envPath)
      if fileManager.fileExists(atPath: envURL.path) {
        return .environment(envURL)
      }
    }

    if fileManager.fileExists(atPath: managedBinaryURL.path) {
      return .managed(managedBinaryURL)
    }

    if let bundledURL = NativeBundledAssetLocator.locate(relativePath: "assets/bin/macos/xray") {
      return .bundled(bundledURL)
    }

    return .missing
  }

  private func versionString(for binaryURL: URL) throws -> String? {
    let tempDirectoryURL = try createTemporaryDirectory(prefix: "xray-version")
    defer { try? fileManager.removeItem(at: tempDirectoryURL) }

    let tempBinaryURL = tempDirectoryURL.appendingPathComponent("xray")
    try installExecutable(sourceURL: binaryURL, targetURL: tempBinaryURL)
    let output = try runProcess(
      executablePath: tempBinaryURL.path,
      arguments: ["version"]
    )
    return Self.parseXrayVersion(from: output)
  }

  private func fetchLatestRelease(from url: URL, proxyPort: Int?) async throws -> GitHubRelease {
    let data = try await downloadData(from: url, proxyPort: proxyPort)
    return try JSONDecoder().decode(GitHubRelease.self, from: data)
  }

  private func downloadText(from url: URL, proxyPort: Int?) async throws -> String {
    let data = try await downloadData(from: url, proxyPort: proxyPort)
    guard let text = String(data: data, encoding: .utf8) else {
      throw NativeImportError.message("无法读取文本响应: \(url.absoluteString)")
    }
    return text
  }

  private func downloadFile(from url: URL, to destinationURL: URL, proxyPort: Int?) async throws {
    let session = makeURLSession(proxyPort: proxyPort)
    defer { session.invalidateAndCancel() }

    let request = makeRequest(for: url)
    let (temporaryURL, response) = try await session.download(for: request)
    try ensureOK(response: response, url: url)
    try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
  }

  private func downloadData(from url: URL, proxyPort: Int?) async throws -> Data {
    let session = makeURLSession(proxyPort: proxyPort)
    defer { session.invalidateAndCancel() }

    let request = makeRequest(for: url)
    let (data, response) = try await session.data(for: request)
    try ensureOK(response: response, url: url)
    return data
  }

  private func makeURLSession(proxyPort: Int?) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 600
    if let proxyPort {
      configuration.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: 1,
        kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPPort as String: proxyPort,
        kCFNetworkProxiesHTTPSEnable as String: 1,
        kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPSPort as String: proxyPort,
      ]
    }
    return URLSession(configuration: configuration)
  }

  private func makeRequest(for url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(Constants.httpUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return request
  }

  private func ensureOK(response: URLResponse, url: URL) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
      return
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw NativeImportError.message(
        "请求失败: \(url.absoluteString) 返回 HTTP \(httpResponse.statusCode)"
      )
    }
  }

  private func sha256(for fileURL: URL) throws -> String {
    let data = try Data(contentsOf: fileURL)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func runProcess(executablePath: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
      throw NativeImportError.message(
        "执行失败: \(executablePath) \(arguments.joined(separator: " ")) \(errorOutput.trimmed().isEmpty ? output.trimmed() : errorOutput.trimmed())"
      )
    }
    return output
  }

  private func installExecutable(sourceURL: URL, targetURL: URL) throws {
    try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: targetURL.path) {
      try fileManager.removeItem(at: targetURL)
    }
    try fileManager.copyItem(at: sourceURL, to: targetURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetURL.path)
  }

  private func findFile(named fileName: String, under rootURL: URL) throws -> URL {
    guard let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      throw NativeImportError.message("无法读取更新压缩包内容。")
    }

    for case let fileURL as URL in enumerator where fileURL.lastPathComponent == fileName {
      return fileURL
    }

    throw NativeImportError.message("更新压缩包里没有找到 \(fileName)。")
  }

  private func createTemporaryDirectory(prefix: String) throws -> URL {
    let directoryURL = fileManager.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
  }

  private func loadMetadata() throws -> ManagedRuntimeMetadata {
    guard fileManager.fileExists(atPath: metadataURL.path) else {
      return .empty
    }

    let data = try Data(contentsOf: metadataURL)
    return try decoder.decode(ManagedRuntimeMetadata.self, from: data)
  }

  private func saveMetadata(_ metadata: ManagedRuntimeMetadata) throws {
    try fileManager.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try encoder.encode(metadata)
    try data.write(to: metadataURL, options: .atomic)
  }

  private var managedDirectoryURL: URL {
    baseDirectoryURL.appendingPathComponent("managed", isDirectory: true)
  }

  private var managedBinaryURL: URL {
    managedDirectoryURL.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("xray")
  }

  private var managedGeodataDirectoryURL: URL {
    managedDirectoryURL.appendingPathComponent("geodata", isDirectory: true)
  }

  private var metadataURL: URL {
    managedDirectoryURL.appendingPathComponent(Constants.metadataFileName)
  }

  private var hasManagedGeodata: Bool {
    Constants.geodataFiles.allSatisfy { fileName in
      let fileURL = managedGeodataDirectoryURL.appendingPathComponent(fileName)
      guard fileManager.fileExists(atPath: fileURL.path) else {
        return false
      }
      let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber) ?? 0
      return size.intValue > 0
    }
  }

  private func localizedMessage(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  static func parseXrayVersion(from output: String) -> String? {
    let firstLine = output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmed() }
      .first(where: { !$0.isEmpty })

    guard let firstLine, firstLine.hasPrefix("Xray ") else {
      return nil
    }

    let tokens = firstLine.split(separator: " ")
    guard tokens.count >= 2 else {
      return nil
    }
    return String(tokens[1]).trimmed()
  }

  static func normalizeVersionString(_ raw: String) -> String {
    raw.trimmed().replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
  }

  static func parseSHA256Digest(from digestText: String) throws -> String {
    let lines = digestText
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmed() }
      .filter { !$0.isEmpty }

    guard let line = lines.first(where: { $0.uppercased().starts(with: "SHA2-256=") }),
          let equalSign = line.firstIndex(of: "=") else {
      throw NativeImportError.message("无法解析 Xray 发布摘要文件。")
    }
    return String(line[line.index(after: equalSign)...]).trimmed()
  }

  static func parseChecksumFile(_ checksumText: String, expectedFileName: String) throws -> String {
    let lines = checksumText
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmed() }
      .filter { !$0.isEmpty }

    for line in lines {
      let parts = line
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
      guard let digest = parts.first else {
        continue
      }
      let fileName = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "*", with: "").trimmed()
      if fileName == expectedFileName || fileName.isEmpty {
        return digest
      }
    }

    throw NativeImportError.message("无法解析 \(expectedFileName) 的 checksum 文件。")
  }
}

private struct ManagedRuntimeMetadata: Codable {
  var xray: ManagedXrayMetadata?
  var geodata: ManagedGeodataMetadata?

  static let empty = ManagedRuntimeMetadata(xray: nil, geodata: nil)
}

private struct ManagedXrayMetadata: Codable {
  let version: String
  let releaseTag: String
  let assetName: String
  let updatedAt: Date
}

private struct ManagedGeodataMetadata: Codable {
  let releaseTag: String
  let updatedAt: Date
}

private struct GitHubRelease: Decodable {
  let tagName: String
  let assets: [GitHubReleaseAsset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case assets
  }

  func requiredAsset(named assetName: String) throws -> GitHubReleaseAsset {
    guard let asset = assets.first(where: { $0.name == assetName }) else {
      throw NativeImportError.message("发布资产缺失: \(assetName)")
    }
    return asset
  }
}

private struct GitHubReleaseAsset: Decodable {
  let name: String
  let downloadURL: String

  enum CodingKeys: String, CodingKey {
    case name
    case downloadURL = "browser_download_url"
  }
}

struct NativeVersion: Comparable {
  let components: [Int]

  init?(_ raw: String) {
    let normalized = NativeRuntimeAssetService.normalizeVersionString(raw)
    let numericPrefix = normalized.prefix { $0.isNumber || $0 == "." }
    let values = numericPrefix
      .split(separator: ".")
      .compactMap { Int($0) }
    guard !values.isEmpty else {
      return nil
    }
    components = values
  }

  static func < (lhs: NativeVersion, rhs: NativeVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right {
        return left < right
      }
    }
    return false
  }
}
