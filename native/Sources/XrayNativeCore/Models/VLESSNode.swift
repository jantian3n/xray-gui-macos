import Foundation

public struct VLESSNode: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var address: String
    public var port: Int
    public var id: String
    public var network: String
    public var security: String
    public var encryption: String
    public var flow: String
    public var serverName: String
    public var fingerprint: String
    public var publicKey: String
    public var shortID: String
    public var spiderX: String
    public var host: String
    public var path: String
    public var mode: String
    public var alpn: [String]
    public var downloadSettings: XHTTPDownloadSettings?
    public var extras: [String: String]

    public init(
        name: String,
        address: String,
        port: Int,
        id: String,
        network: String,
        security: String,
        encryption: String = "none",
        flow: String = "",
        serverName: String = "",
        fingerprint: String = "",
        publicKey: String = "",
        shortID: String = "",
        spiderX: String = "",
        host: String = "",
        path: String = "",
        mode: String = "",
        alpn: [String] = [],
        downloadSettings: XHTTPDownloadSettings? = nil,
        extras: [String: String] = [:]
    ) {
        self.name = name
        self.address = address
        self.port = port
        self.id = id
        self.network = network
        self.security = security
        self.encryption = encryption
        self.flow = flow
        self.serverName = serverName
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.shortID = shortID
        self.spiderX = spiderX
        self.host = host
        self.path = path
        self.mode = mode
        self.alpn = alpn
        self.downloadSettings = downloadSettings
        self.extras = extras
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
