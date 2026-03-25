import CryptoKit
import Darwin
import Foundation
import XrayNativeCore

public final class XrayDesktopRuntime: @unchecked Sendable {
    public typealias LogHandler = (String) -> Void
    public typealias TrafficHandler = (RuntimeTrafficSnapshot) -> Void
    public typealias StateHandler = (String) -> Void

    private static let geodataFiles = ["geoip.dat", "geosite.dat"]
    private static let assetLocationEnv = "XRAY_LOCATION_ASSET"
    private static let xrayBinaryEnv = "XRAY_GUI_XRAY_BINARY"
    private static let geodataBaseURL = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download")!
    private static let statsServerHost = "127.0.0.1"
    private static let statsAPIInboundTag = "gui-api-in"
    private static let statsAPIOutboundTag = "gui-api"
    private static let trafficStatsPattern = "outbound>>>proxy>>>traffic>>>"
    private static let uplinkSuffix = ">>>uplink"
    private static let downlinkSuffix = ">>>downlink"

    public var onLog: LogHandler?
    public var onTrafficSnapshot: TrafficHandler?
    public var onStateChange: StateHandler?

    private let proxyController = MacSystemProxyController()

    private var process: Process?
    private var stdoutReader: OutputLineReader?
    private var stderrReader: OutputLineReader?
    private var activeProfile: Profile?
    private var trafficTimer: Timer?
    private var stopRequested = false
    private var xrayBinaryURL: URL?
    private var statsAPIPort: Int?
    private var lastTrafficPollAt: Date?
    private var trafficPollInFlight = false
    private var state = "idle"

    public init() {
        proxyController.recoverIfNeeded(log: emit)
    }

    public var supportedRuntimeModes: [RuntimeMode] {
        [.localProxy]
    }

    public func normalizeRuntimeMode(_ mode: RuntimeMode) -> RuntimeMode {
        .localProxy
    }

    public func runtimeModeDescription(_ mode: RuntimeMode) -> String {
        switch mode {
        case .vpn:
            return "桌面端当前还没有接入系统级 VPN/TUN，先统一使用本地代理模式。"
        case .localProxy:
            return "启动本地 SOCKS/HTTP 代理端口，并在 macOS 上自动切换系统代理。"
        }
    }

    public func requestVPNPermission() throws {
        throw RuntimeError.unsupportedVPNMode
    }

    public func start(profile: Profile, config: [String: Any]) throws {
        guard profile.runtimeMode == .localProxy else {
            throw RuntimeError.onlyLocalProxySupported
        }

        stop()

        let layout = try prepareLayout()
        let xrayBinaryURL = try resolveXrayBinary(layout: layout)
        let statsAPIPort = try allocateLoopbackPort()
        let runtimeConfig = try withDesktopStatsAPI(config: config, statsAPIPort: statsAPIPort)

        let configURL = layout.runtimeDirectory.appendingPathComponent("config.json")
        let profileURL = layout.runtimeDirectory.appendingPathComponent("profile.json")

        try JSONCoding.prettyPrintedString(from: runtimeConfig).write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let profileData = try JSONEncoder().encode(profile)
        try profileData.write(to: profileURL, options: .atomic)

        emit("wrote config to \(configURL.path)")
        emit("using geodata at \(layout.geodataDirectory.path)")
        emit("using xray binary at \(xrayBinaryURL.path)")

        activeProfile = profile
        self.xrayBinaryURL = xrayBinaryURL
        self.statsAPIPort = statsAPIPort
        stopRequested = false
        setState("starting")
        resetTrafficStats()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = xrayBinaryURL
        process.arguments = ["run", "-c", configURL.path]
        process.currentDirectoryURL = layout.runtimeDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment[Self.assetLocationEnv] = layout.geodataDirectory.path
        process.environment = environment
        process.terminationHandler = { [weak self] process in
            self?.handleTermination(process)
        }

        do {
            try process.run()
            self.process = process
            stdoutReader = OutputLineReader(fileHandle: stdoutPipe.fileHandleForReading) { [weak self] line in
                self?.emit(line)
            }
            stderrReader = OutputLineReader(fileHandle: stderrPipe.fileHandleForReading) { [weak self] line in
                self?.emit("stderr: \(line)")
            }

            try proxyController.enable(
                httpPort: profile.httpPort,
                socksPort: profile.socksPort,
                log: emit
            )
            startTrafficPolling()
            setState("running")
        } catch {
            process.terminate()
            proxyController.disable(log: emit)
            stopTrafficPolling()
            self.process = nil
            self.xrayBinaryURL = nil
            self.statsAPIPort = nil
            setState("error")
            throw error
        }
    }

    public func stop() {
        guard let process else {
            activeProfile = nil
            setState("stopped")
            return
        }

        stopRequested = true
        setState("stopping")

        if process.isRunning {
            process.terminate()

            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    public func runtimeState() -> String {
        state
    }

    public func updateGeodata() async throws {
        let layout = try prepareLayout()
        let proxyPort = state == "running" ? activeProfile?.httpPort : nil
        let routeLabel = proxyPort.map { "local HTTP proxy 127.0.0.1:\($0)" } ?? "direct network"

        emit("Updating geodata into \(layout.geodataDirectory.path) via \(routeLabel)")

        for fileName in Self.geodataFiles {
            try await downloadAndVerifyGeodataFile(
                to: layout.geodataDirectory,
                fileName: fileName,
                proxyPort: proxyPort
            )
        }

        let stampURL = layout.geodataDirectory.appendingPathComponent("LAST_UPDATE.txt")
        try "\(Date().timeIntervalSince1970)".write(to: stampURL, atomically: true, encoding: .utf8)
        emit("Geodata update finished.")
    }

    private func handleTermination(_ process: Process) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.process === process else {
                return
            }

            self.proxyController.disable(log: self.emit)
            self.stopTrafficPolling()
            self.stdoutReader = nil
            self.stderrReader = nil
            self.process = nil

            let stopRequested = self.stopRequested
            self.stopRequested = false
            self.activeProfile = nil
            self.xrayBinaryURL = nil
            self.statsAPIPort = nil

            if process.terminationStatus == 0 {
                self.emit(stopRequested ? "xray stopped." : "xray exited normally.")
                self.setState("stopped")
            } else {
                self.emit("xray exited with code \(process.terminationStatus).")
                self.setState(stopRequested ? "stopped" : "error")
            }
        }
    }

    private func prepareLayout() throws -> DesktopRuntimeLayout {
        let supportDirectory = try DesktopPaths.applicationSupportDirectory()
        let runtimeDirectory = supportDirectory.appendingPathComponent("xray_gui", isDirectory: true)
        let geodataDirectory = runtimeDirectory.appendingPathComponent("geodata", isDirectory: true)
        let extractedBinaryDirectory = runtimeDirectory.appendingPathComponent("bin", isDirectory: true)

        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geodataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extractedBinaryDirectory, withIntermediateDirectories: true)

        try installBundledGeodataIfMissing(in: geodataDirectory)

        return DesktopRuntimeLayout(
            runtimeDirectory: runtimeDirectory,
            geodataDirectory: geodataDirectory,
            extractedBinaryDirectory: extractedBinaryDirectory
        )
    }

    private func installBundledGeodataIfMissing(in geodataDirectory: URL) throws {
        let candidateDirectories = [
            Bundle.main.resourceURL?.appendingPathComponent("geodata", isDirectory: true),
            DesktopPaths.repositoryRoot.appendingPathComponent("assets/bootstrap-geodata", isDirectory: true),
        ].compactMap { $0 }

        for fileName in Self.geodataFiles {
            let targetURL = geodataDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: targetURL.path),
               (try? Data(contentsOf: targetURL).isEmpty) == false {
                continue
            }

            guard let sourceURL = candidateDirectories
                .map({ $0.appendingPathComponent(fileName) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                let searched = candidateDirectories.map(\.path).joined(separator: ", ")
                emit("Bundled \(fileName) not found. searched=\(searched)")
                continue
            }

            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            emit("Installed bundled \(fileName) from repository assets.")
        }
    }

    private func resolveXrayBinary(layout: DesktopRuntimeLayout) throws -> URL {
        if let envValue = ProcessInfo.processInfo.environment[Self.xrayBinaryEnv],
           !envValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fileURL = URL(fileURLWithPath: envValue)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw RuntimeError.binaryMissing("XRAY_GUI_XRAY_BINARY 指向的文件不存在: \(fileURL.path)")
            }
            return fileURL
        }

        let candidateURLs = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/xray"),
            DesktopPaths.repositoryRoot.appendingPathComponent("assets/bin/macos/xray"),
        ].compactMap { $0 }

        if let sourceURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return try installRuntimeBinary(from: sourceURL, layout: layout)
        }

        if let pathBinary = findBinaryOnPATH(named: "xray") {
            return pathBinary
        }

        throw RuntimeError.binaryMissing(
            "未找到 xray 可执行文件。请确认仓库里存在 assets/bin/macos/xray，或手动设置 XRAY_GUI_XRAY_BINARY=/absolute/path/to/xray。"
        )
    }

    private func installRuntimeBinary(from sourceURL: URL, layout: DesktopRuntimeLayout) throws -> URL {
        let extractedURL = layout.extractedBinaryDirectory.appendingPathComponent("xray")
        if FileManager.default.fileExists(atPath: extractedURL.path) {
            try FileManager.default.removeItem(at: extractedURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: extractedURL)
        try prepareBinaryIfNeeded(at: extractedURL)
        return extractedURL
    }

    private func prepareBinaryIfNeeded(at fileURL: URL) throws {
        let chmodResult = Process()
        chmodResult.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodResult.arguments = ["755", fileURL.path]
        try chmodResult.run()
        chmodResult.waitUntilExit()

        for attribute in ["com.apple.quarantine", "com.apple.provenance"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-d", attribute, fileURL.path]
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func findBinaryOnPATH(named binaryName: String) -> URL? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binaryName]
        process.standardOutput = outputPipe
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: output)
    }

    private func allocateLoopbackPort() throws -> Int {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
        defer {
            close(fileDescriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.bind(fileDescriptor, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(fileDescriptor, pointer, &length)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(.ENOTSOCK)
        }

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func withDesktopStatsAPI(config: [String: Any], statsAPIPort: Int) throws -> [String: Any] {
        var runtimeConfig = try JSONCoding.deepCopy(config)
        runtimeConfig["stats"] = [String: Any]()

        var policy = runtimeConfig["policy"] as? [String: Any] ?? [:]
        var systemPolicy = policy["system"] as? [String: Any] ?? [:]
        systemPolicy["statsInboundUplink"] = true
        systemPolicy["statsInboundDownlink"] = true
        systemPolicy["statsOutboundUplink"] = true
        systemPolicy["statsOutboundDownlink"] = true
        policy["system"] = systemPolicy
        runtimeConfig["policy"] = policy

        runtimeConfig["api"] = [
            "tag": Self.statsAPIOutboundTag,
            "services": ["StatsService"],
        ]

        var inbounds = runtimeConfig["inbounds"] as? [[String: Any]] ?? []
        let hasAPIInbound = inbounds.contains { $0["tag"] as? String == Self.statsAPIInboundTag }
        if !hasAPIInbound {
            inbounds.append([
                "tag": Self.statsAPIInboundTag,
                "listen": Self.statsServerHost,
                "port": statsAPIPort,
                "protocol": "dokodemo-door",
                "settings": [
                    "address": Self.statsServerHost,
                ],
            ])
        }
        runtimeConfig["inbounds"] = inbounds

        var outbounds = runtimeConfig["outbounds"] as? [[String: Any]] ?? []
        let hasAPIOutbound = outbounds.contains { $0["tag"] as? String == Self.statsAPIOutboundTag }
        if !hasAPIOutbound {
            outbounds.append([
                "tag": Self.statsAPIOutboundTag,
                "protocol": "freedom",
                "settings": [String: Any](),
            ])
        }
        runtimeConfig["outbounds"] = outbounds

        var routing = runtimeConfig["routing"] as? [String: Any] ?? [:]
        var rules = routing["rules"] as? [[String: Any]] ?? []
        let hasAPIRule = rules.contains { rule in
            let inboundTags = rule["inboundTag"] as? [String] ?? []
            return rule["outboundTag"] as? String == Self.statsAPIOutboundTag &&
                inboundTags.contains(Self.statsAPIInboundTag)
        }
        if !hasAPIRule {
            rules.insert([
                "type": "field",
                "inboundTag": [Self.statsAPIInboundTag],
                "outboundTag": Self.statsAPIOutboundTag,
            ], at: 0)
        }
        routing["rules"] = rules
        runtimeConfig["routing"] = routing

        return runtimeConfig
    }

    private func startTrafficPolling() {
        stopTrafficPolling()
        guard xrayBinaryURL != nil, statsAPIPort != nil else {
            return
        }

        lastTrafficPollAt = Date()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollTrafficStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        trafficTimer = timer
    }

    private func stopTrafficPolling() {
        trafficTimer?.invalidate()
        trafficTimer = nil
        trafficPollInFlight = false
        lastTrafficPollAt = nil
        resetTrafficStats()
    }

    private func resetTrafficStats() {
        onTrafficSnapshot?(.zero)
    }

    private func pollTrafficStats() {
        guard !trafficPollInFlight,
              let xrayBinaryURL,
              let statsAPIPort,
              let lastTrafficPollAt else {
            return
        }

        trafficPollInFlight = true
        defer {
            trafficPollInFlight = false
        }

        guard let rawStats = queryTrafficStats(
            xrayBinaryURL: xrayBinaryURL,
            statsAPIPort: statsAPIPort
        ) else {
            return
        }

        let now = Date()
        let interval = now.timeIntervalSince(lastTrafficPollAt)
        guard interval > 0 else {
            self.lastTrafficPollAt = now
            return
        }
        self.lastTrafficPollAt = now

        onTrafficSnapshot?(RuntimeTrafficSnapshot(
            uploadBytesPerSecond: Int(Double(rawStats.uploadBytes) / interval),
            downloadBytesPerSecond: Int(Double(rawStats.downloadBytes) / interval)
        ))
    }

    private func queryTrafficStats(xrayBinaryURL: URL, statsAPIPort: Int) -> RawTrafficStats? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = xrayBinaryURL
        process.arguments = [
            "api",
            "statsquery",
            "--server=\(Self.statsServerHost):\(statsAPIPort)",
            "-pattern",
            Self.trafficStatsPattern,
            "-reset",
        ]
        process.standardOutput = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }

            let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                return .zero
            }
            let response = try JSONCoding.decodeObject(from: output)
            let stats = response["stat"] as? [[String: Any]] ?? []
            var uploadBytes = 0
            var downloadBytes = 0

            for stat in stats {
                let name = stat["name"] as? String ?? ""
                let value = (stat["value"] as? NSNumber)?.intValue ?? 0
                if name.hasSuffix(Self.uplinkSuffix) {
                    uploadBytes = value
                } else if name.hasSuffix(Self.downlinkSuffix) {
                    downloadBytes = value
                }
            }

            return RawTrafficStats(uploadBytes: uploadBytes, downloadBytes: downloadBytes)
        } catch {
            return nil
        }
    }

    private func downloadAndVerifyGeodataFile(to geodataDirectory: URL, fileName: String, proxyPort: Int?) async throws {
        let tempURL = geodataDirectory.appendingPathComponent("\(fileName).download")
        let targetURL = geodataDirectory.appendingPathComponent(fileName)

        emit("Downloading \(fileName)")

        let fileURL = Self.geodataBaseURL.appendingPathComponent(fileName)
        let checksumURL = Self.geodataBaseURL.appendingPathComponent("\(fileName).sha256sum")

        let fileData = try await downloadData(from: fileURL, proxyPort: proxyPort)
        try fileData.write(to: tempURL, options: .atomic)

        let checksumText = String(decoding: try await downloadData(from: checksumURL, proxyPort: proxyPort), as: UTF8.self)
        let checksumLine = checksumText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        let expectedHash = checksumLine
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""

        guard !expectedHash.isEmpty else {
            try? FileManager.default.removeItem(at: tempURL)
            throw RuntimeError.checksumFileEmpty(fileName)
        }

        let actualHash = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        guard actualHash.lowercased() == expectedHash.lowercased() else {
            try? FileManager.default.removeItem(at: tempURL)
            throw RuntimeError.checksumMismatch(fileName, expected: expectedHash, actual: actualHash)
        }

        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: targetURL)
        emit("Verified and installed \(fileName)")
    }

    private func downloadData(from url: URL, proxyPort: Int?) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        if let proxyPort {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: proxyPort,
            ]
        }
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              200 ..< 300 ~= httpResponse.statusCode else {
            throw RuntimeError.httpError(url.absoluteString)
        }
        return data
    }

    private func setState(_ value: String) {
        state = value
        emit("state=\(value)")
        onStateChange?(value)
    }

    private func emit(_ message: String) {
        onLog?(message)
    }
}

private struct DesktopRuntimeLayout {
    let runtimeDirectory: URL
    let geodataDirectory: URL
    let extractedBinaryDirectory: URL
}

private struct RawTrafficStats {
    let uploadBytes: Int
    let downloadBytes: Int

    static let zero = RawTrafficStats(uploadBytes: 0, downloadBytes: 0)
}

private final class OutputLineReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let onLine: (String) -> Void
    private var buffer = ""

    init(fileHandle: FileHandle, onLine: @escaping (String) -> Void) {
        self.fileHandle = fileHandle
        self.onLine = onLine
        start()
    }

    deinit {
        fileHandle.readabilityHandler = nil
    }

    private func start() {
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else {
                return
            }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self.flush()
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            self.buffer.append(chunk)
            let lines = self.buffer.components(separatedBy: .newlines)
            self.buffer = lines.last ?? ""
            for line in lines.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self.onLine(trimmed)
                }
            }
        }
    }

    private func flush() {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onLine(trimmed)
        }
        buffer.removeAll(keepingCapacity: false)
    }
}

private enum RuntimeError: LocalizedError {
    case unsupportedVPNMode
    case onlyLocalProxySupported
    case binaryMissing(String)
    case checksumFileEmpty(String)
    case checksumMismatch(String, expected: String, actual: String)
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVPNMode:
            return "桌面版当前不支持 VPN 模式，请切换到本地代理模式。"
        case .onlyLocalProxySupported:
            return "桌面版当前仅支持本地代理模式。"
        case .binaryMissing(let message):
            return message
        case .checksumFileEmpty(let fileName):
            return "\(fileName) 的 checksum 文件为空。"
        case .checksumMismatch(let fileName, let expected, let actual):
            return "\(fileName) 的 checksum 校验失败。expected=\(expected) actual=\(actual)"
        case .httpError(let url):
            return "Unexpected HTTP response for \(url)"
        }
    }
}
