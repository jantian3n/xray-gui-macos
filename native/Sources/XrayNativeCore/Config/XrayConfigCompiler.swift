import Foundation

public enum XrayConfigCompilerError: LocalizedError {
    case xhttpRequiresPath
    case splitRequiresXHTTP
    case streamOneNotSupportedWithDownloadSettings
    case splitRequiresAddress
    case splitRequiresValidPort
    case splitRequiresPath
    case splitRequiresXHTTPDownload
    case realityRequiresPublicKey(String)
    case realityRequiresServerName(String)
    case realityRequiresFingerprint(String)
    case tlsRequiresServerName(String)
    case tlsRequiresFingerprint(String)

    public var errorDescription: String? {
        switch self {
        case .xhttpRequiresPath:
            return "XHTTP requires a path."
        case .splitRequiresXHTTP:
            return "Split download settings require XHTTP on the upload side."
        case .streamOneNotSupportedWithDownloadSettings:
            return "stream-one cannot be used together with XHTTP downloadSettings."
        case .splitRequiresAddress:
            return "Split download requires an address."
        case .splitRequiresValidPort:
            return "Split download requires a valid port."
        case .splitRequiresPath:
            return "Split download XHTTP requires a path."
        case .splitRequiresXHTTPDownload:
            return "Split download currently expects network=xhttp."
        case .realityRequiresPublicKey(let label):
            return "\(label) REALITY requires a public key."
        case .realityRequiresServerName(let label):
            return "\(label) REALITY requires serverName or sni."
        case .realityRequiresFingerprint(let label):
            return "\(label) REALITY requires fingerprint."
        case .tlsRequiresServerName(let label):
            return "\(label) TLS requires serverName or sni."
        case .tlsRequiresFingerprint(let label):
            return "\(label) TLS requires fingerprint."
        }
    }
}

public struct XrayConfigCompiler: Sendable {
    public init() {}

    public func compile(_ profile: Profile) throws -> [String: Any] {
        try validate(node: profile.node)

        return [
            "log": [
                "loglevel": "info",
            ],
            "dns": buildDNS(profile.routingPreset),
            "inbounds": buildInbounds(profile),
            "outbounds": buildOutbounds(profile.node),
            "routing": [
                "domainStrategy": "IPIfNonMatch",
                "domainMatcher": "mph",
                "rules": buildRoutingRules(profile.routingPreset),
            ],
        ]
    }

    private func validate(node: VLESSNode) throws {
        try validateSecurity(
            label: "Upload",
            security: node.security,
            serverName: node.serverName,
            fingerprint: node.fingerprint,
            publicKey: node.publicKey
        )

        let network = node.network.lowercased()
        if (network == "xhttp" || network == "splithttp") && node.path.isEmpty {
            throw XrayConfigCompilerError.xhttpRequiresPath
        }

        if let download = node.downloadSettings {
            guard node.isXHTTP else {
                throw XrayConfigCompilerError.splitRequiresXHTTP
            }
            if node.mode.lowercased() == "stream-one" {
                throw XrayConfigCompilerError.streamOneNotSupportedWithDownloadSettings
            }
            try validate(downloadSettings: download)
        }
    }

    private func validate(downloadSettings: XHTTPDownloadSettings) throws {
        if downloadSettings.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw XrayConfigCompilerError.splitRequiresAddress
        }
        if downloadSettings.port <= 0 || downloadSettings.port > 65_535 {
            throw XrayConfigCompilerError.splitRequiresValidPort
        }
        guard downloadSettings.isXHTTP else {
            throw XrayConfigCompilerError.splitRequiresXHTTPDownload
        }
        if downloadSettings.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw XrayConfigCompilerError.splitRequiresPath
        }

        try validateSecurity(
            label: "Download",
            security: downloadSettings.security,
            serverName: downloadSettings.serverName,
            fingerprint: downloadSettings.fingerprint,
            publicKey: downloadSettings.publicKey
        )
    }

    private func validateSecurity(
        label: String,
        security: String,
        serverName: String,
        fingerprint: String,
        publicKey: String
    ) throws {
        switch security.lowercased() {
        case "reality":
            if publicKey.isEmpty {
                throw XrayConfigCompilerError.realityRequiresPublicKey(label)
            }
            if serverName.isEmpty {
                throw XrayConfigCompilerError.realityRequiresServerName(label)
            }
            if fingerprint.isEmpty {
                throw XrayConfigCompilerError.realityRequiresFingerprint(label)
            }
        case "tls":
            if serverName.isEmpty {
                throw XrayConfigCompilerError.tlsRequiresServerName(label)
            }
            if fingerprint.isEmpty {
                throw XrayConfigCompilerError.tlsRequiresFingerprint(label)
            }
        default:
            break
        }
    }

    private func buildDNS(_ preset: RoutingPreset) -> [String: Any] {
        switch preset {
        case .cnDirect:
            return [
                "hosts": [
                    "geosite:category-ads-all": "127.0.0.1",
                ],
                "servers": [
                    [
                        "address": "https://1.1.1.1/dns-query",
                        "domains": ["geosite:geolocation-!cn"],
                        "expectIPs": ["geoip:!cn"],
                    ],
                    [
                        "address": "223.5.5.5",
                        "port": 53,
                        "domains": ["geosite:cn", "geosite:private"],
                        "expectIPs": ["geoip:cn"],
                        "skipFallback": true,
                    ],
                    [
                        "address": "localhost",
                        "skipFallback": true,
                    ],
                ],
            ]
        case .globalProxy:
            return [
                "hosts": [
                    "geosite:category-ads-all": "127.0.0.1",
                ],
                "servers": [
                    "https://1.1.1.1/dns-query",
                    "8.8.8.8",
                    [
                        "address": "localhost",
                        "skipFallback": true,
                    ],
                ],
            ]
        case .gfwLike:
            return [
                "hosts": [
                    "geosite:category-ads-all": "127.0.0.1",
                ],
                "servers": [
                    "https://1.1.1.1/dns-query",
                    "223.5.5.5",
                    [
                        "address": "localhost",
                        "skipFallback": true,
                    ],
                ],
            ]
        }
    }

    private func buildInbounds(_ profile: Profile) -> [[String: Any]] {
        let localProxyInbounds: [[String: Any]] = [
            [
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": profile.socksPort,
                "protocol": "socks",
                "settings": [
                    "udp": true,
                    "auth": "noauth",
                ],
            ],
            [
                "tag": "http-in",
                "listen": "127.0.0.1",
                "port": profile.httpPort,
                "protocol": "http",
                "settings": [:] as [String: Any],
            ],
        ]

        if profile.runtimeMode == .vpn {
            return [
                [
                    "tag": "tun-in",
                    "port": 0,
                    "protocol": "tun",
                    "settings": [
                        "name": "xray0",
                        "MTU": profile.tunMTU,
                    ],
                ],
            ] + localProxyInbounds
        }

        return localProxyInbounds
    }

    private func buildOutbounds(_ node: VLESSNode) -> [[String: Any]] {
        [
            [
                "tag": "proxy",
                "protocol": "vless",
                "settings": [
                    "vnext": [
                        [
                            "address": node.address,
                            "port": node.port,
                            "users": [
                                clean([
                                    "id": node.id,
                                    "encryption": node.encryption,
                                    "flow": node.flow,
                                ]),
                            ],
                        ],
                    ],
                ],
                "streamSettings": buildStreamSettings(node),
            ],
            [
                "tag": "direct",
                "protocol": "freedom",
                "settings": [:] as [String: Any],
            ],
            [
                "tag": "block",
                "protocol": "blackhole",
                "settings": [:] as [String: Any],
            ],
        ]
    }

    private func buildStreamSettings(_ node: VLESSNode) -> [String: Any] {
        clean([
            "network": node.network,
            "security": node.security,
            "tlsSettings": node.isTLS ? clean([
                "serverName": node.serverName,
                "fingerprint": node.fingerprint,
                "alpn": node.alpn,
            ]) : nil,
            "realitySettings": node.isReality ? clean([
                "serverName": node.serverName,
                "fingerprint": node.fingerprint,
                "publicKey": node.publicKey,
                "shortId": node.shortID,
                "spiderX": node.spiderX,
            ]) : nil,
            "xhttpSettings": node.isXHTTP ? clean([
                "host": node.host,
                "path": node.path,
                "mode": node.mode,
                "downloadSettings": node.downloadSettings.map(buildDownloadSettings),
            ]) : nil,
        ])
    }

    private func buildDownloadSettings(_ downloadSettings: XHTTPDownloadSettings) -> [String: Any] {
        clean([
            "address": downloadSettings.address,
            "port": downloadSettings.port,
            "network": downloadSettings.network,
            "security": downloadSettings.security,
            "tlsSettings": downloadSettings.isTLS ? clean([
                "serverName": downloadSettings.serverName,
                "fingerprint": downloadSettings.fingerprint,
                "alpn": downloadSettings.alpn,
            ]) : nil,
            "realitySettings": downloadSettings.isReality ? clean([
                "serverName": downloadSettings.serverName,
                "fingerprint": downloadSettings.fingerprint,
                "publicKey": downloadSettings.publicKey,
                "shortId": downloadSettings.shortID,
                "spiderX": downloadSettings.spiderX,
            ]) : nil,
            "xhttpSettings": downloadSettings.isXHTTP ? clean([
                "host": downloadSettings.host,
                "path": downloadSettings.path,
                "mode": downloadSettings.mode,
            ]) : nil,
        ])
    }

    private func buildRoutingRules(_ preset: RoutingPreset) -> [[String: Any]] {
        switch preset {
        case .cnDirect:
            return [
                [
                    "type": "field",
                    "outboundTag": "block",
                    "domain": ["geosite:category-ads-all"],
                ],
                [
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": [
                        "geosite:private",
                        "geosite:apple-cn",
                        "geosite:google-cn",
                        "geosite:tld-cn",
                    ],
                ],
                [
                    "type": "field",
                    "outboundTag": "proxy",
                    "domain": ["geosite:geolocation-!cn"],
                ],
                [
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": ["geosite:cn"],
                ],
                [
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:cn", "geoip:private"],
                ],
                [
                    "type": "field",
                    "outboundTag": "proxy",
                    "network": "tcp,udp",
                ],
            ]
        case .globalProxy:
            return [
                [
                    "type": "field",
                    "outboundTag": "block",
                    "domain": ["geosite:category-ads-all"],
                ],
                [
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": ["geosite:private"],
                ],
                [
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:private"],
                ],
                [
                    "type": "field",
                    "outboundTag": "proxy",
                    "network": "tcp,udp",
                ],
            ]
        case .gfwLike:
            return [
                [
                    "type": "field",
                    "outboundTag": "block",
                    "domain": ["geosite:category-ads-all"],
                ],
                [
                    "type": "field",
                    "outboundTag": "proxy",
                    "domain": ["geosite:gfw"],
                ],
                [
                    "type": "field",
                    "outboundTag": "proxy",
                    "ip": ["geoip:telegram"],
                ],
                [
                    "type": "field",
                    "outboundTag": "direct",
                    "network": "tcp,udp",
                ],
            ]
        }
    }

    private func clean(_ source: [String: Any?]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in source {
            guard let value else {
                continue
            }
            if let string = value as? String, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if let list = value as? [Any], list.isEmpty {
                continue
            }
            if let map = value as? [String: Any], map.isEmpty {
                continue
            }
            result[key] = value
        }
        return result
    }
}
