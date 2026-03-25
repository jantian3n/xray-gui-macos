import Foundation

public enum RuntimeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case vpn
    case localProxy

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .vpn:
            return "VPN 模式"
        case .localProxy:
            return "本地代理"
        }
    }
}
