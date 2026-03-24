import Foundation

enum NativeRuntimeMode: String, Codable, CaseIterable, Identifiable {
  case vpn
  case systemProxy
  case localProxy

  var id: String { rawValue }

  var label: String {
    switch self {
    case .vpn:
      return "VPN 模式"
    case .systemProxy:
      return "系统代理"
    case .localProxy:
      return "本地代理"
    }
  }
}

enum NativeRoutingPreset: String, Codable, CaseIterable, Identifiable {
  case cnDirect
  case globalProxy
  case gfwLike

  var id: String { rawValue }

  var label: String {
    switch self {
    case .cnDirect:
      return "国内直连"
    case .globalProxy:
      return "全局代理"
    case .gfwLike:
      return "常见被墙域名代理"
    }
  }

  var description: String {
    switch self {
    case .cnDirect:
      return "中国大陆和私有地址直连，海外流量走代理。"
    case .globalProxy:
      return "除私有地址外，所有流量都走代理。"
    case .gfwLike:
      return "常见受限域名走代理，其余多数流量保持直连。"
    }
  }
}

struct NativeXhttpDownloadSettings: Codable, Equatable {
  let address: String
  let port: Int
  let network: String
  let security: String
  let serverName: String
  let fingerprint: String
  let publicKey: String
  let shortId: String
  let spiderX: String
  let host: String
  let path: String
  let mode: String
  let alpn: [String]

  init(
    address: String,
    port: Int,
    network: String = "xhttp",
    security: String = "reality",
    serverName: String = "",
    fingerprint: String = "",
    publicKey: String = "",
    shortId: String = "",
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
    self.shortId = shortId
    self.spiderX = spiderX
    self.host = host
    self.path = path
    self.mode = mode
    self.alpn = alpn
  }

  var isReality: Bool { security.lowercased() == "reality" }
  var isTLS: Bool { security.lowercased() == "tls" }
  var isXHTTP: Bool {
    let value = network.lowercased()
    return value == "xhttp" || value == "splithttp"
  }
}

struct NativeVlessNode: Codable, Equatable {
  let name: String
  let address: String
  let port: Int
  let id: String
  let network: String
  let security: String
  let encryption: String
  let flow: String
  let serverName: String
  let fingerprint: String
  let publicKey: String
  let shortId: String
  let spiderX: String
  let host: String
  let path: String
  let mode: String
  let alpn: [String]
  let downloadSettings: NativeXhttpDownloadSettings?
  let extras: [String: String]

  init(
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
    shortId: String = "",
    spiderX: String = "",
    host: String = "",
    path: String = "",
    mode: String = "",
    alpn: [String] = [],
    downloadSettings: NativeXhttpDownloadSettings? = nil,
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
    self.shortId = shortId
    self.spiderX = spiderX
    self.host = host
    self.path = path
    self.mode = mode
    self.alpn = alpn
    self.downloadSettings = downloadSettings
    self.extras = extras
  }

  var isReality: Bool { security.lowercased() == "reality" }
  var isTLS: Bool { security.lowercased() == "tls" }
  var isXHTTP: Bool {
    let value = network.lowercased()
    return value == "xhttp" || value == "splithttp"
  }
}

struct NativeProfile: Codable, Equatable {
  let id: String
  let name: String
  let node: NativeVlessNode
  let routingPreset: NativeRoutingPreset
  let runtimeMode: NativeRuntimeMode
  let socksPort: Int
  let httpPort: Int
  let tunMtu: Int

  static func from(
    node: NativeVlessNode,
    routingPreset: NativeRoutingPreset = .cnDirect,
    runtimeMode: NativeRuntimeMode = .systemProxy
  ) -> NativeProfile {
    let safeName = node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "\(node.address):\(node.port)"
      : node.name.trimmingCharacters(in: .whitespacesAndNewlines)

    return NativeProfile(
      id: safeName
        .lowercased()
        .replacingOccurrences(
          of: "[^a-z0-9]+",
          with: "-",
          options: .regularExpression
        )
        .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression),
      name: safeName,
      node: node,
      routingPreset: routingPreset,
      runtimeMode: runtimeMode,
      socksPort: 10808,
      httpPort: 10809,
      tunMtu: 1500
    )
  }
}

enum NativeImportError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message):
      return message
    }
  }
}

struct NativeVlessURIParser {
  private let handledKeys: Set<String> = [
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

  func parse(_ raw: String) throws -> NativeVlessNode {
    let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !link.isEmpty else {
      throw NativeImportError.message("没有可导入的内容。")
    }

    guard let components = URLComponents(string: link) else {
      throw NativeImportError.message("无效的 VLESS 链接。")
    }
    guard components.scheme?.lowercased() == "vless" else {
      throw NativeImportError.message("暂不支持该协议。")
    }
    guard let user = components.user, !user.isEmpty else {
      throw NativeImportError.message("缺少 VLESS 用户 ID。")
    }
    guard let host = components.host, !host.isEmpty else {
      throw NativeImportError.message("缺少服务器地址。")
    }
    guard let port = components.port, port > 0 else {
      throw NativeImportError.message("缺少服务器端口。")
    }

    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { item in
        (item.name.lowercased(), item.value ?? "")
      }
    )

    let network = normalizeNetwork(query["type"] ?? "tcp")
    let security = (query["security"] ?? "none").trimmed()
    let serverName = (query["sni"] ?? query["servername"] ?? "").trimmed()
    let name = (components.fragment?.removingPercentEncoding ?? components.fragment ?? "").trimmed().isEmpty
      ? "\(host):\(port)"
      : (components.fragment?.removingPercentEncoding ?? components.fragment ?? "").trimmed()

    var extras: [String: String] = [:]
    for (key, value) in query where !handledKeys.contains(key) {
      extras[key] = value
    }

    return NativeVlessNode(
      name: name,
      address: host.trimmed(),
      port: port,
      id: (user.removingPercentEncoding ?? user).trimmed(),
      network: network,
      security: security,
      encryption: (query["encryption"] ?? "none").trimmed(),
      flow: (query["flow"] ?? "").trimmed(),
      serverName: serverName,
      fingerprint: (query["fp"] ?? "").trimmed(),
      publicKey: (query["pbk"] ?? query["publickey"] ?? "").trimmed(),
      shortId: (query["sid"] ?? query["shortid"] ?? "").trimmed(),
      spiderX: (query["spx"] ?? query["spiderx"] ?? "").trimmed(),
      host: (query["host"] ?? "").trimmed(),
      path: (query["path"] ?? "").trimmed(),
      mode: (query["mode"] ?? "").trimmed(),
      alpn: parseStringList(query["alpn"]),
      extras: extras
    )
  }

  func encode(_ node: NativeVlessNode) -> String {
    var queryItems = node.extras

    func putIfNotBlank(_ key: String, _ value: String) {
      let normalized = value.trimmed()
      if normalized.isEmpty {
        queryItems.removeValue(forKey: key)
      } else {
        queryItems[key] = normalized
      }
    }

    putIfNotBlank("encryption", node.encryption.isEmpty ? "none" : node.encryption)
    putIfNotBlank("flow", node.flow)
    putIfNotBlank("type", node.network)
    putIfNotBlank("security", node.security)
    putIfNotBlank("sni", node.serverName)
    putIfNotBlank("fp", node.fingerprint)
    putIfNotBlank("pbk", node.publicKey)
    putIfNotBlank("sid", node.shortId)
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
    components.fragment = node.name.trimmed().isEmpty ? nil : node.name.trimmed()
    components.queryItems = queryItems.isEmpty
      ? nil
      : queryItems
        .sorted(by: { $0.key < $1.key })
        .map { URLQueryItem(name: $0.key, value: $0.value) }

    return components.string ?? "vless://\(node.id)@\(node.address):\(node.port)"
  }

  private func normalizeNetwork(_ value: String) -> String {
    let lower = value.trimmed().lowercased()
    if lower == "splithttp" {
      return "xhttp"
    }
    return lower.isEmpty ? "tcp" : lower
  }
}

struct NativeNodeImporter {
  private let uriParser = NativeVlessURIParser()

  func parseNode(_ raw: String) throws -> NativeVlessNode {
    let text = raw.trimmed()
    guard !text.isEmpty else {
      throw NativeImportError.message("没有可导入的内容。")
    }

    if text.lowercased().hasPrefix("vless://") {
      return try uriParser.parse(text)
    }

    let json = try parseJSONObject(text)
    if looksLikeOutbound(json) {
      return try parseOutbound(json)
    }
    if looksLikePatch(json) {
      throw NativeImportError.message("这是 split patch JSON，请对已有节点应用补丁。")
    }

    throw NativeImportError.message("暂不支持这类导入内容。请粘贴 vless:// 或 client_outbound.json。")
  }

  func applyPatch(baseNode: NativeVlessNode, raw: String) throws -> NativeVlessNode {
    let text = raw.trimmed()
    guard !text.isEmpty else {
      throw NativeImportError.message("没有可应用的补丁内容。")
    }

    let json = try parseJSONObject(text)
    guard looksLikePatch(json) else {
      throw NativeImportError.message("补丁内容缺少 downloadSettings。")
    }

    let downloadJSON = try asDictionary(json["downloadSettings"], fieldName: "downloadSettings")
    let downloadSettings = try parseDownloadSettings(downloadJSON)

    return NativeVlessNode(
      name: baseNode.name,
      address: baseNode.address,
      port: baseNode.port,
      id: baseNode.id,
      network: baseNode.network,
      security: baseNode.security,
      encryption: baseNode.encryption,
      flow: baseNode.flow,
      serverName: baseNode.serverName,
      fingerprint: baseNode.fingerprint,
      publicKey: baseNode.publicKey,
      shortId: baseNode.shortId,
      spiderX: baseNode.spiderX,
      host: baseNode.host,
      path: baseNode.path,
      mode: baseNode.mode,
      alpn: baseNode.alpn,
      downloadSettings: downloadSettings,
      extras: baseNode.extras
    )
  }

  func looksLikePatch(_ raw: String) -> Bool {
    let text = raw.trimmed()
    guard !text.isEmpty, !text.lowercased().hasPrefix("vless://") else {
      return false
    }

    do {
      let json = try parseJSONObject(text)
      return looksLikePatch(json)
    } catch {
      return false
    }
  }

  private func parseOutbound(_ json: [String: Any]) throws -> NativeVlessNode {
    let settings = try asDictionary(json["settings"], fieldName: "settings")
    let rawVnext = try asArray(settings["vnext"], fieldName: "settings.vnext")
    guard let endpointAny = rawVnext.first else {
      throw NativeImportError.message("VLESS outbound 缺少 vnext。")
    }

    let endpoint = try asDictionary(endpointAny, fieldName: "settings.vnext[0]")
    let rawUsers = try asArray(endpoint["users"], fieldName: "settings.vnext[0].users")
    guard let userAny = rawUsers.first else {
      throw NativeImportError.message("VLESS outbound 缺少 users。")
    }

    let user = try asDictionary(userAny, fieldName: "settings.vnext[0].users[0]")
    let streamSettings = try asDictionary(json["streamSettings"], fieldName: "streamSettings")
    let xhttpSettings = try pickXHTTPSettings(streamSettings)

    let security = asString(streamSettings["security"], fallback: "none")
    let realitySettings = asDictionaryOrEmpty(streamSettings["realitySettings"])
    let tlsSettings = asDictionaryOrEmpty(streamSettings["tlsSettings"])

    return NativeVlessNode(
      name: asString(json["tag"], fallback: "").trimmed().isEmpty
        ? "\(asString(endpoint["address"])):\(asInt(endpoint["port"], fallback: 443))"
        : asString(json["tag"]),
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
      shortId: asString(realitySettings["shortId"], fallback: ""),
      spiderX: asString(realitySettings["spiderX"], fallback: ""),
      host: asString(xhttpSettings["host"], fallback: ""),
      path: asString(xhttpSettings["path"], fallback: ""),
      mode: asString(xhttpSettings["mode"], fallback: ""),
      alpn: parseStringList(tlsSettings["alpn"]),
      downloadSettings: xhttpSettings.keys.contains("downloadSettings")
        ? try parseDownloadSettings(
            try asDictionary(
              xhttpSettings["downloadSettings"],
              fieldName: "xhttpSettings.downloadSettings"
            )
          )
        : nil
    )
  }

  private func parseDownloadSettings(_ json: [String: Any]) throws -> NativeXhttpDownloadSettings {
    let security = asString(json["security"], fallback: "none")
    let realitySettings = asDictionaryOrEmpty(json["realitySettings"])
    let tlsSettings = asDictionaryOrEmpty(json["tlsSettings"])
    let xhttpSettings = try pickXHTTPSettings(json)

    return NativeXhttpDownloadSettings(
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
      shortId: asString(realitySettings["shortId"], fallback: ""),
      spiderX: asString(realitySettings["spiderX"], fallback: ""),
      host: asString(xhttpSettings["host"], fallback: ""),
      path: asString(xhttpSettings["path"], fallback: ""),
      mode: asString(xhttpSettings["mode"], fallback: ""),
      alpn: parseStringList(tlsSettings["alpn"])
    )
  }

  private func pickXHTTPSettings(_ json: [String: Any]) throws -> [String: Any] {
    if let xhttp = json["xhttpSettings"] {
      return try asDictionary(xhttp, fieldName: "xhttpSettings")
    }
    if let splitHTTP = json["splithttpSettings"] {
      return try asDictionary(splitHTTP, fieldName: "splithttpSettings")
    }
    return [:]
  }

  private func looksLikeOutbound(_ json: [String: Any]) -> Bool {
    asString(json["protocol"], fallback: "").lowercased() == "vless" &&
      json["settings"] is [String: Any]
  }

  private func looksLikePatch(_ json: [String: Any]) -> Bool {
    json["downloadSettings"] is [String: Any]
  }

  private func parseJSONObject(_ raw: String) throws -> [String: Any] {
    guard let data = raw.data(using: .utf8) else {
      throw NativeImportError.message("导入内容必须是 UTF-8 文本。")
    }

    let decoded = try JSONSerialization.jsonObject(with: data)
    guard let json = decoded as? [String: Any] else {
      throw NativeImportError.message("导入内容必须是 JSON 对象。")
    }
    return json
  }

  private func asDictionary(_ value: Any?, fieldName: String) throws -> [String: Any] {
    if let dictionary = value as? [String: Any] {
      return dictionary
    }
    throw NativeImportError.message("\(fieldName) 必须是对象。")
  }

  private func asDictionaryOrEmpty(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
  }

  private func asArray(_ value: Any?, fieldName: String) throws -> [Any] {
    if let array = value as? [Any] {
      return array
    }
    throw NativeImportError.message("\(fieldName) 必须是数组。")
  }

  private func asString(_ value: Any?, fallback: String = "") -> String {
    let normalized = String(describing: value ?? fallback).trimmed()
    return normalized.isEmpty ? fallback : normalized
  }

  private func asInt(_ value: Any?, fallback: Int) -> Int {
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = value as? String, let parsed = Int(string.trimmed()) {
      return parsed
    }
    return fallback
  }

  private func resolveServerName(
    security: String,
    realitySettings: [String: Any],
    tlsSettings: [String: Any]
  ) -> String {
    switch security.lowercased() {
    case "reality":
      return asString(realitySettings["serverName"], fallback: "")
    case "tls":
      return asString(tlsSettings["serverName"], fallback: "")
    default:
      return ""
    }
  }

  private func resolveFingerprint(
    security: String,
    realitySettings: [String: Any],
    tlsSettings: [String: Any]
  ) -> String {
    switch security.lowercased() {
    case "reality":
      return asString(realitySettings["fingerprint"], fallback: "")
    case "tls":
      return asString(tlsSettings["fingerprint"], fallback: "")
    default:
      return ""
    }
  }
}

struct NativeXrayConfigCompiler {
  func compile(profile: NativeProfile) throws -> [String: Any] {
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

  private func validate(node: NativeVlessNode) throws {
    try validateSecurity(
      label: "Upload",
      security: node.security,
      serverName: node.serverName,
      fingerprint: node.fingerprint,
      publicKey: node.publicKey
    )

    let network = node.network.lowercased()
    if (network == "xhttp" || network == "splithttp") && node.path.isEmpty {
      throw NativeImportError.message("XHTTP requires a path.")
    }

    if let download = node.downloadSettings {
      if !node.isXHTTP {
        throw NativeImportError.message("Split download settings require XHTTP on the upload side.")
      }
      if node.mode.lowercased() == "stream-one" {
        throw NativeImportError.message(
          "stream-one cannot be used together with XHTTP downloadSettings."
        )
      }
      try validateDownloadSettings(download)
    }
  }

  private func validateDownloadSettings(_ download: NativeXhttpDownloadSettings) throws {
    if download.address.trimmed().isEmpty {
      throw NativeImportError.message("Split download requires an address.")
    }
    if download.port <= 0 || download.port > 65535 {
      throw NativeImportError.message("Split download requires a valid port.")
    }
    if !download.isXHTTP {
      throw NativeImportError.message("Split download currently expects network=xhttp.")
    }
    if download.path.trimmed().isEmpty {
      throw NativeImportError.message("Split download XHTTP requires a path.")
    }

    try validateSecurity(
      label: "Download",
      security: download.security,
      serverName: download.serverName,
      fingerprint: download.fingerprint,
      publicKey: download.publicKey
    )
  }

  private func validateSecurity(
    label: String,
    security: String,
    serverName: String,
    fingerprint: String,
    publicKey: String
  ) throws {
    let normalized = security.lowercased()
    if normalized == "reality" {
      if publicKey.isEmpty {
        throw NativeImportError.message("\(label) REALITY requires a public key.")
      }
      if serverName.isEmpty {
        throw NativeImportError.message("\(label) REALITY requires serverName or sni.")
      }
      if fingerprint.isEmpty {
        throw NativeImportError.message("\(label) REALITY requires fingerprint.")
      }
      return
    }

    if normalized == "tls" {
      if serverName.isEmpty {
        throw NativeImportError.message("\(label) TLS requires serverName or sni.")
      }
      if fingerprint.isEmpty {
        throw NativeImportError.message("\(label) TLS requires fingerprint.")
      }
    }
  }

  private func buildDNS(_ preset: NativeRoutingPreset) -> [String: Any] {
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

  private func buildInbounds(_ profile: NativeProfile) -> [[String: Any]] {
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
            "MTU": profile.tunMtu,
          ],
        ],
      ] + localProxyInbounds
    }

    return localProxyInbounds
  }

  private func buildOutbounds(_ node: NativeVlessNode) -> [[String: Any]] {
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
                removeEmpty([
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

  private func buildStreamSettings(_ node: NativeVlessNode) -> [String: Any] {
    removeEmpty([
      "network": node.network,
      "security": node.security,
      "tlsSettings": node.isTLS
        ? removeEmpty([
            "serverName": node.serverName,
            "fingerprint": node.fingerprint,
            "alpn": node.alpn,
          ])
        : nil,
      "realitySettings": node.isReality
        ? removeEmpty([
            "serverName": node.serverName,
            "fingerprint": node.fingerprint,
            "publicKey": node.publicKey,
            "shortId": node.shortId,
            "spiderX": node.spiderX,
          ])
        : nil,
      "xhttpSettings": node.isXHTTP
        ? removeEmpty([
            "host": node.host,
            "path": node.path,
            "mode": node.mode,
            "downloadSettings": node.downloadSettings == nil
              ? nil
              : buildDownloadSettings(node.downloadSettings!),
          ])
        : nil,
    ])
  }

  private func buildDownloadSettings(_ download: NativeXhttpDownloadSettings) -> [String: Any] {
    removeEmpty([
      "address": download.address,
      "port": download.port,
      "network": download.network,
      "security": download.security,
      "tlsSettings": download.isTLS
        ? removeEmpty([
            "serverName": download.serverName,
            "fingerprint": download.fingerprint,
            "alpn": download.alpn,
          ])
        : nil,
      "realitySettings": download.isReality
        ? removeEmpty([
            "serverName": download.serverName,
            "fingerprint": download.fingerprint,
            "publicKey": download.publicKey,
            "shortId": download.shortId,
            "spiderX": download.spiderX,
          ])
        : nil,
      "xhttpSettings": download.isXHTTP
        ? removeEmpty([
            "host": download.host,
            "path": download.path,
            "mode": download.mode,
          ])
        : nil,
    ])
  }

  private func buildRoutingRules(_ preset: NativeRoutingPreset) -> [[String: Any]] {
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
          "domain": ["geosite:private", "geosite:apple-cn", "geosite:google-cn", "geosite:tld-cn"],
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

  private func removeEmpty(_ source: [String: Any?]) -> [String: Any] {
    var output: [String: Any] = [:]

    for (key, value) in source {
      guard let value else { continue }
      if let string = value as? String, string.trimmed().isEmpty {
        continue
      }
      if let list = value as? [Any], list.isEmpty {
        continue
      }
      if let dictionary = value as? [String: Any], dictionary.isEmpty {
        continue
      }
      output[key] = value
    }

    return output
  }
}

private func parseStringList(_ value: Any?) -> [String] {
  if let list = value as? [Any] {
    return list
      .map { String(describing: $0).trimmed() }
      .filter { !$0.isEmpty }
  }
  if let string = value as? String {
    return string
      .split(separator: ",")
      .map { String($0).trimmed() }
      .filter { !$0.isEmpty }
  }
  return []
}

extension String {
  func trimmed() -> String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
