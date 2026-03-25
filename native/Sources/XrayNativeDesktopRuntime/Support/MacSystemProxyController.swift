import Foundation

final class MacSystemProxyController {
    private static let backupFileName = "system_proxy_backup.v1.json"
    private var activeBackup: ProxyBackup?

    func recoverIfNeeded(log: (String) -> Void) {
        guard let backup = activeBackup ?? readBackup() else {
            return
        }
        do {
            try restoreBackup(backup)
            try deleteBackup()
            activeBackup = nil
            log("restored macOS system proxy from a previous session.")
        } catch {
            log("failed to recover system proxy: \(error.localizedDescription)")
        }
    }

    func enable(httpPort: Int, socksPort: Int, log: (String) -> Void) throws {
        recoverIfNeeded(log: log)

        let service = try resolvePrimaryService()
        let backup = try captureBackup(serviceName: service.name)
        try ensureBackupIsSafeToOverride(backup)

        let bypassDomains = Array(Set(backup.bypassDomains + ["127.0.0.1", "localhost"])).sorted()

        try applyProxyBypassDomains(serviceName: service.name, domains: bypassDomains)
        try applyProxyState(
            serviceName: service.name,
            commands: ProxyCommandPair(setter: "-setwebproxy", stateSetter: "-setwebproxystate"),
            state: .enabled(server: "127.0.0.1", port: httpPort)
        )
        try applyProxyState(
            serviceName: service.name,
            commands: ProxyCommandPair(setter: "-setsecurewebproxy", stateSetter: "-setsecurewebproxystate"),
            state: .enabled(server: "127.0.0.1", port: httpPort)
        )
        try applyProxyState(
            serviceName: service.name,
            commands: ProxyCommandPair(setter: "-setsocksfirewallproxy", stateSetter: "-setsocksfirewallproxystate"),
            state: .enabled(server: "127.0.0.1", port: socksPort)
        )

        activeBackup = backup
        try writeBackup(backup)
        log("enabled macOS system proxy on \(service.name): http=127.0.0.1:\(httpPort) socks=127.0.0.1:\(socksPort)")
    }

    func disable(log: (String) -> Void) {
        guard let backup = activeBackup ?? readBackup() else {
            return
        }

        do {
            try restoreBackup(backup)
            try deleteBackup()
            activeBackup = nil
            log("restored macOS system proxy on \(backup.serviceName).")
        } catch {
            log("failed to restore system proxy: \(error.localizedDescription)")
        }
    }

    private func ensureBackupIsSafeToOverride(_ backup: ProxyBackup) throws {
        let states = [backup.web, backup.secureWeb, backup.socks]
        if states.contains(where: { $0.authenticated }) {
            throw ProxyControllerError.authenticatedProxyAlreadyEnabled
        }
    }

    private func resolvePrimaryService() throws -> NetworkService {
        let output = try runNetworkSetup(["-listnetworkserviceorder"])
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var services: [NetworkService] = []
        let servicePattern = try NSRegularExpression(pattern: #"^\((\d+|\*)\)\s+(.+)$"#)
        let devicePattern = try NSRegularExpression(pattern: #"^\(Hardware Port:\s*(.*), Device:\s*(.*)\)$"#)

        var index = 0
        while index < lines.count {
            let serviceLine = lines[index]
            let serviceMatch = servicePattern.firstMatch(
                in: serviceLine,
                range: NSRange(serviceLine.startIndex..., in: serviceLine)
            )
            guard let serviceMatch, index + 1 < lines.count else {
                index += 1
                continue
            }

            let deviceLine = lines[index + 1]
            guard let deviceMatch = devicePattern.firstMatch(
                in: deviceLine,
                range: NSRange(deviceLine.startIndex..., in: deviceLine)
            ) else {
                index += 1
                continue
            }

            let disabledMarker = serviceLine.substring(with: serviceMatch.range(at: 1))
            let name = serviceLine.substring(with: serviceMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let device = deviceLine.substring(with: deviceMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            services.append(NetworkService(name: name, device: device, disabled: disabledMarker == "*"))
            index += 2
        }

        let candidates = services.filter { !$0.disabled && !$0.device.isEmpty }
        for service in candidates {
            let info = try runNetworkSetup(["-getinfo", service.name])
            let ipAddress = info
                .components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix("IP address:") })?
                .components(separatedBy: ":")
                .dropFirst()
                .joined(separator: ":")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !ipAddress.isEmpty, ipAddress.lowercased() != "none" {
                return service
            }
        }

        if let fallback = candidates.first {
            return fallback
        }
        throw ProxyControllerError.noAvailableNetworkService
    }

    private func captureBackup(serviceName: String) throws -> ProxyBackup {
        ProxyBackup(
            serviceName: serviceName,
            web: try readProxyState(serviceName: serviceName, getter: "-getwebproxy"),
            secureWeb: try readProxyState(serviceName: serviceName, getter: "-getsecurewebproxy"),
            socks: try readProxyState(serviceName: serviceName, getter: "-getsocksfirewallproxy"),
            bypassDomains: try readBypassDomains(serviceName: serviceName)
        )
    }

    private func readProxyState(serviceName: String, getter: String) throws -> ProxyState {
        let output = try runNetworkSetup([getter, serviceName])
        var values: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            guard let separatorIndex = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }

        return ProxyState(
            enabled: (values["Enabled"] ?? "").lowercased() == "yes",
            server: values["Server"] ?? "",
            port: Int(values["Port"] ?? "") ?? 0,
            authenticated: (values["Authenticated Proxy Enabled"] ?? "") == "1"
        )
    }

    private func readBypassDomains(serviceName: String) throws -> [String] {
        try runNetworkSetup(["-getproxybypassdomains", serviceName])
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func restoreBackup(_ backup: ProxyBackup) throws {
        try applyProxyBypassDomains(serviceName: backup.serviceName, domains: backup.bypassDomains)
        try applyProxyState(
            serviceName: backup.serviceName,
            commands: ProxyCommandPair(setter: "-setwebproxy", stateSetter: "-setwebproxystate"),
            state: backup.web
        )
        try applyProxyState(
            serviceName: backup.serviceName,
            commands: ProxyCommandPair(setter: "-setsecurewebproxy", stateSetter: "-setsecurewebproxystate"),
            state: backup.secureWeb
        )
        try applyProxyState(
            serviceName: backup.serviceName,
            commands: ProxyCommandPair(setter: "-setsocksfirewallproxy", stateSetter: "-setsocksfirewallproxystate"),
            state: backup.socks
        )
    }

    private func applyProxyBypassDomains(serviceName: String, domains: [String]) throws {
        let args = ["-setproxybypassdomains", serviceName] + (domains.isEmpty ? ["Empty"] : domains)
        _ = try runNetworkSetup(args)
    }

    private func applyProxyState(serviceName: String, commands: ProxyCommandPair, state: ProxyState) throws {
        if state.enabled {
            _ = try runNetworkSetup([
                commands.setter,
                serviceName,
                state.server,
                "\(state.port)",
                "off",
            ])
            _ = try runNetworkSetup([commands.stateSetter, serviceName, "on"])
        } else {
            _ = try runNetworkSetup([commands.stateSetter, serviceName, "off"])
        }
    }

    private func runNetworkSetup(_ arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw ProcessExecutionError(
                executable: "/usr/sbin/networksetup",
                arguments: arguments,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: Int(process.terminationStatus)
            )
        }
        return stdout
    }

    private func backupFileURL() throws -> URL {
        try DesktopPaths.applicationSupportDirectory()
            .appendingPathComponent(Self.backupFileName)
    }

    private func writeBackup(_ backup: ProxyBackup) throws {
        let data = try JSONEncoder().encode(backup)
        try data.write(to: try backupFileURL(), options: .atomic)
    }

    private func readBackup() -> ProxyBackup? {
        guard let fileURL = try? backupFileURL(),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(ProxyBackup.self, from: data)
        } catch {
            try? deleteBackup()
            return nil
        }
    }

    private func deleteBackup() throws {
        let fileURL = try backupFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

private enum ProxyControllerError: LocalizedError {
    case authenticatedProxyAlreadyEnabled
    case noAvailableNetworkService

    var errorDescription: String? {
        switch self {
        case .authenticatedProxyAlreadyEnabled:
            return "当前网络服务已经启用了需要认证的系统代理，自动切换暂不支持覆盖这种配置。"
        case .noAvailableNetworkService:
            return "未找到可用的 macOS 网络服务，无法自动设置系统代理。"
        }
    }
}

private struct NetworkService {
    let name: String
    let device: String
    let disabled: Bool
}

private struct ProxyCommandPair {
    let setter: String
    let stateSetter: String
}

private struct ProxyState: Codable {
    let enabled: Bool
    let server: String
    let port: Int
    let authenticated: Bool

    static func enabled(server: String, port: Int) -> ProxyState {
        ProxyState(enabled: true, server: server, port: port, authenticated: false)
    }
}

private struct ProxyBackup: Codable {
    let serviceName: String
    let web: ProxyState
    let secureWeb: ProxyState
    let socks: ProxyState
    let bypassDomains: [String]
}

private extension String {
    func substring(with range: NSRange) -> String {
        guard let swiftRange = Range(range, in: self) else {
            return ""
        }
        return String(self[swiftRange])
    }
}

struct ProcessExecutionError: LocalizedError {
    let executable: String
    let arguments: [String]
    let stderr: String
    let exitCode: Int

    var errorDescription: String? {
        if stderr.isEmpty {
            return "\(executable) exited with code \(exitCode)."
        }
        return "\(executable) exited with code \(exitCode): \(stderr)"
    }
}
