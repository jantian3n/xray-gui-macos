import Foundation

public enum NodeImportError: LocalizedError {
    case emptyContent
    case emptyPatchContent
    case invalidJSONObject
    case unsupportedContent
    case splitPatchExpected
    case patchJSONShouldBeAppliedToExistingNode
    case outboundMissingVNext
    case outboundMissingUsers
    case fieldMustBeObject(String)
    case fieldMustBeArray(String)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "没有可导入的内容。"
        case .emptyPatchContent:
            return "没有可应用的补丁内容。"
        case .invalidJSONObject:
            return "导入内容必须是 JSON 对象。"
        case .unsupportedContent:
            return "暂不支持这类导入内容。请粘贴 vless:// 或 client_outbound.json。"
        case .splitPatchExpected:
            return "补丁内容缺少 downloadSettings。"
        case .patchJSONShouldBeAppliedToExistingNode:
            return "这是 split patch JSON，请对已有节点应用补丁。"
        case .outboundMissingVNext:
            return "VLESS outbound 缺少 vnext。"
        case .outboundMissingUsers:
            return "VLESS outbound 缺少 users。"
        case .fieldMustBeObject(let name):
            return "\(name) 必须是对象。"
        case .fieldMustBeArray(let name):
            return "\(name) 必须是数组。"
        }
    }
}

public struct NodeImporter: Sendable {
    public var uriParser: VLESSURIParser

    public init(uriParser: VLESSURIParser = VLESSURIParser()) {
        self.uriParser = uriParser
    }

    public func parseNode(_ raw: String) throws -> VLESSNode {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NodeImportError.emptyContent
        }
        if text.lowercased().hasPrefix("vless://") {
            return try uriParser.parse(text)
        }

        let json = try JSONCoding.decodeObject(from: text)
        if looksLikeOutbound(json) {
            return try parseOutbound(json)
        }
        if looksLikePatch(json) {
            throw NodeImportError.patchJSONShouldBeAppliedToExistingNode
        }
        throw NodeImportError.unsupportedContent
    }

    public func applyPatch(baseNode: VLESSNode, raw: String) throws -> VLESSNode {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NodeImportError.emptyPatchContent
        }

        let json = try JSONCoding.decodeObject(from: text)
        guard looksLikePatch(json) else {
            throw NodeImportError.splitPatchExpected
        }

        let downloadJSON = try asMap(json["downloadSettings"], fieldName: "downloadSettings")
        var merged = baseNode
        merged.downloadSettings = try parseDownloadSettings(downloadJSON)
        return merged
    }

    public func looksLikePatch(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.lowercased().hasPrefix("vless://") else {
            return false
        }
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let json = value as? [String: Any] else {
            return false
        }
        return looksLikePatch(json)
    }

    private func parseOutbound(_ json: [String: Any]) throws -> VLESSNode {
        let settings = try asMap(json["settings"], fieldName: "settings")
        let rawVNext = try asArray(settings["vnext"], fieldName: "settings.vnext")
        guard let endpointValue = rawVNext.first else {
            throw NodeImportError.outboundMissingVNext
        }
        let endpoint = try asMap(endpointValue, fieldName: "settings.vnext[0]")

        let rawUsers = try asArray(endpoint["users"], fieldName: "settings.vnext[0].users")
        guard let userValue = rawUsers.first else {
            throw NodeImportError.outboundMissingUsers
        }
        let user = try asMap(userValue, fieldName: "settings.vnext[0].users[0]")
        let streamSettings = try asMap(json["streamSettings"], fieldName: "streamSettings")
        let xhttpSettings = try pickXHTTPSettings(streamSettings)

        let security = asString(streamSettings["security"], fallback: "none")
        let realitySettings = asOptionalMap(streamSettings["realitySettings"])
        let tlsSettings = asOptionalMap(streamSettings["tlsSettings"])

        let defaultName = "\(asString(endpoint["address"])):\(asInt(endpoint["port"], fallback: 443))"
        let outboundTag = asString(json["tag"], fallback: "").trimmed()

        return VLESSNode(
            name: outboundTag.isEmpty ? defaultName : outboundTag,
            address: asString(endpoint["address"]),
            port: asInt(endpoint["port"], fallback: 443),
            id: asString(user["id"]),
            network: asString(streamSettings["network"], fallback: "tcp"),
            security: security,
            encryption: asString(user["encryption"], fallback: "none"),
            flow: asString(user["flow"], fallback: ""),
            serverName: resolveServerName(
                security: security,
                realitySettings: realitySettings,
                tlsSettings: tlsSettings
            ),
            fingerprint: resolveFingerprint(
                security: security,
                realitySettings: realitySettings,
                tlsSettings: tlsSettings
            ),
            publicKey: asString(realitySettings["publicKey"], fallback: ""),
            shortID: asString(realitySettings["shortId"], fallback: ""),
            spiderX: asString(realitySettings["spiderX"], fallback: ""),
            host: asString(xhttpSettings["host"], fallback: ""),
            path: asString(xhttpSettings["path"], fallback: ""),
            mode: asString(xhttpSettings["mode"], fallback: ""),
            alpn: parseStringList(tlsSettings["alpn"]),
            downloadSettings: xhttpSettings["downloadSettings"] == nil
                ? nil
                : try parseDownloadSettings(
                    asMap(
                        xhttpSettings["downloadSettings"],
                        fieldName: "xhttpSettings.downloadSettings"
                    )
                )
        )
    }

    private func parseDownloadSettings(_ json: [String: Any]) throws -> XHTTPDownloadSettings {
        let security = asString(json["security"], fallback: "none")
        let realitySettings = asOptionalMap(json["realitySettings"])
        let tlsSettings = asOptionalMap(json["tlsSettings"])
        let xhttpSettings = try pickXHTTPSettings(json)

        return XHTTPDownloadSettings(
            address: asString(json["address"]),
            port: asInt(json["port"], fallback: 443),
            network: asString(json["network"], fallback: "xhttp"),
            security: security,
            serverName: resolveServerName(
                security: security,
                realitySettings: realitySettings,
                tlsSettings: tlsSettings
            ),
            fingerprint: resolveFingerprint(
                security: security,
                realitySettings: realitySettings,
                tlsSettings: tlsSettings
            ),
            publicKey: asString(realitySettings["publicKey"], fallback: ""),
            shortID: asString(realitySettings["shortId"], fallback: ""),
            spiderX: asString(realitySettings["spiderX"], fallback: ""),
            host: asString(xhttpSettings["host"], fallback: ""),
            path: asString(xhttpSettings["path"], fallback: ""),
            mode: asString(xhttpSettings["mode"], fallback: ""),
            alpn: parseStringList(tlsSettings["alpn"])
        )
    }

    private func pickXHTTPSettings(_ json: [String: Any]) throws -> [String: Any] {
        if json["xhttpSettings"] != nil {
            return try asMap(json["xhttpSettings"], fieldName: "xhttpSettings")
        }
        if json["splithttpSettings"] != nil {
            return try asMap(json["splithttpSettings"], fieldName: "splithttpSettings")
        }
        return [:]
    }

    private func looksLikeOutbound(_ json: [String: Any]) -> Bool {
        asString(json["protocol"], fallback: "").lowercased() == "vless" && json["settings"] is [String: Any]
    }

    private func looksLikePatch(_ json: [String: Any]) -> Bool {
        json["downloadSettings"] is [String: Any]
    }

    private func asMap(_ value: Any?, fieldName: String) throws -> [String: Any] {
        guard let value else {
            throw NodeImportError.fieldMustBeObject(fieldName)
        }
        guard let map = value as? [String: Any] else {
            throw NodeImportError.fieldMustBeObject(fieldName)
        }
        return map
    }

    private func asOptionalMap(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func asArray(_ value: Any?, fieldName: String) throws -> [Any] {
        guard let array = value as? [Any] else {
            throw NodeImportError.fieldMustBeArray(fieldName)
        }
        return array
    }

    private func asString(_ value: Any?, fallback: String = "") -> String {
        let normalized = String(describing: value ?? fallback).trimmed()
        return normalized.isEmpty ? fallback : normalized
    }

    private func asInt(_ value: Any?, fallback: Int) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return fallback
    }

    private func resolveServerName(
        security: String,
        realitySettings: [String: Any],
        tlsSettings: [String: Any]
    ) -> String {
        if security.lowercased() == "reality" {
            return asString(realitySettings["serverName"], fallback: "")
        }
        if security.lowercased() == "tls" {
            return asString(tlsSettings["serverName"], fallback: "")
        }
        return ""
    }

    private func resolveFingerprint(
        security: String,
        realitySettings: [String: Any],
        tlsSettings: [String: Any]
    ) -> String {
        if security.lowercased() == "reality" {
            return asString(realitySettings["fingerprint"], fallback: "")
        }
        if security.lowercased() == "tls" {
            return asString(tlsSettings["fingerprint"], fallback: "")
        }
        return ""
    }

    private func parseStringList(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list
                .map { String(describing: $0).trimmed() }
                .filter { !$0.isEmpty }
        }
        if let string = value as? String, !string.trimmed().isEmpty {
            return string
                .split(separator: ",")
                .map { String($0).trimmed() }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
