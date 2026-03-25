import Foundation

public struct XHTTPDownloadSettings: Codable, Equatable, Sendable {
    public var address: String
    public var port: Int
    public var network: String
    public var security: String
    public var serverName: String
    public var fingerprint: String
    public var publicKey: String
    public var shortID: String
    public var spiderX: String
    public var host: String
    public var path: String
    public var mode: String
    public var alpn: [String]

    public init(
        address: String,
        port: Int,
        network: String = "xhttp",
        security: String = "reality",
        serverName: String = "",
        fingerprint: String = "",
        publicKey: String = "",
        shortID: String = "",
        spiderX: String = "",
        host: String = "",
        path: String = "",
        mode: String = "",
        alpn: [String] = []
    ) {
        self.address = address
        self.port = port
        self.network = network
        self.security = security
        self.serverName = serverName
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.shortID = shortID
        self.spiderX = spiderX
        self.host = host
        self.path = path
        self.mode = mode
        self.alpn = alpn
    }

    public var isReality: Bool {
        security.caseInsensitiveCompare("reality") == .orderedSame
    }

    public var isTLS: Bool {
        security.caseInsensitiveCompare("tls") == .orderedSame
    }

    public var isXHTTP: Bool {
        let normalized = network.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "xhttp" || normalized == "splithttp"
    }
}
