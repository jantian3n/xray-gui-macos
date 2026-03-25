import Foundation

public enum VLESSURIParserError: LocalizedError {
    case emptyLink
    case unsupportedScheme(String)
    case missingUserID
    case missingHost
    case missingPort
    case malformedURL

    public var errorDescription: String? {
        switch self {
        case .emptyLink:
            return "Empty link."
        case .unsupportedScheme(let scheme):
            return "Unsupported scheme: \(scheme)"
        case .missingUserID:
            return "Missing VLESS user id."
        case .missingHost:
            return "Missing server host."
        case .missingPort:
            return "Missing server port."
        case .malformedURL:
            return "Malformed VLESS link."
        }
    }
}

public struct VLESSURIParser: Sendable {
    private static let handledKeys: Set<String> = [
        "encryption",
        "flow",
        "type",
        "security",
        "sni",
        "servername",
        "fp",
        "pbk",
        "publickey",
        "sid",
        "shortid",
        "spx",
        "spiderx",
        "host",
        "path",
        "mode",
        "alpn",
    ]

    public init() {}

    public func parse(_ raw: String) throws -> VLESSNode {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            throw VLESSURIParserError.emptyLink
        }

        guard let components = URLComponents(string: link) else {
            throw VLESSURIParserError.malformedURL
        }

        guard components.scheme?.lowercased() == "vless" else {
            throw VLESSURIParserError.unsupportedScheme(components.scheme ?? "")
        }

        guard let user = components.percentEncodedUser?.removingPercentEncoding,
              !user.isEmpty else {
            throw VLESSURIParserError.missingUserID
        }

        guard let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            throw VLESSURIParserError.missingHost
        }

        guard let port = components.port, port > 0 else {
            throw VLESSURIParserError.missingPort
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name.lowercased()] = item.value ?? ""
        }

        let network = normalizeNetwork(query["type"] ?? "tcp")
        let security = (query["security"] ?? "none").trimmed()
        let serverName = (query["sni"] ?? query["servername"] ?? "").trimmed()
        let fragment = components.percentEncodedFragment?.removingPercentEncoding ?? ""
        let name = fragment.trimmed().isEmpty ? "\(host):\(port)" : fragment.trimmed()

        var extras: [String: String] = [:]
        for (key, value) in query where !Self.handledKeys.contains(key) {
            extras[key] = value
        }

        return VLESSNode(
            name: name,
            address: host,
            port: port,
            id: user.trimmed(),
            network: network,
            security: security,
            encryption: (query["encryption"] ?? "none").trimmed(),
            flow: (query["flow"] ?? "").trimmed(),
            serverName: serverName,
            fingerprint: (query["fp"] ?? "").trimmed(),
            publicKey: (query["pbk"] ?? query["publickey"] ?? "").trimmed(),
            shortID: (query["sid"] ?? query["shortid"] ?? "").trimmed(),
            spiderX: (query["spx"] ?? query["spiderx"] ?? "").trimmed(),
            host: (query["host"] ?? "").trimmed(),
            path: (query["path"] ?? "").trimmed(),
            mode: (query["mode"] ?? "").trimmed(),
            alpn: parseALPN(query["alpn"] ?? ""),
            extras: extras
        )
    }

    public func encode(_ node: VLESSNode) -> String {
        var query = node.extras

        func putIfNotBlank(_ key: String, _ value: String) {
            let normalized = value.trimmed()
            if normalized.isEmpty {
                query.removeValue(forKey: key)
            } else {
                query[key] = normalized
            }
        }

        putIfNotBlank("encryption", node.encryption.isEmpty ? "none" : node.encryption)
        putIfNotBlank("flow", node.flow)
        putIfNotBlank("type", node.network)
        putIfNotBlank("security", node.security)
        putIfNotBlank("sni", node.serverName)
        putIfNotBlank("fp", node.fingerprint)
        putIfNotBlank("pbk", node.publicKey)
        putIfNotBlank("sid", node.shortID)
        putIfNotBlank("spx", node.spiderX)
        putIfNotBlank("host", node.host)
        putIfNotBlank("path", node.path)
        putIfNotBlank("mode", node.mode)
        putIfNotBlank("alpn", node.alpn.joined(separator: ","))

        var components = URLComponents()
        components.scheme = "vless"
        components.user = node.id.trimmed()
        components.host = node.address.trimmed()
        components.port = node.port
        if !query.isEmpty {
            components.queryItems = query
                .sorted(by: { $0.key < $1.key })
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        if !node.name.trimmed().isEmpty {
            components.fragment = node.name.trimmed()
        }
        return components.string ?? ""
    }

    private func normalizeNetwork(_ value: String) -> String {
        let lowercased = value.trimmed().lowercased()
        if lowercased == "splithttp" {
            return "xhttp"
        }
        return lowercased.isEmpty ? "tcp" : lowercased
    }

    private func parseALPN(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { String($0).trimmed() }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
