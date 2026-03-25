import Foundation

public enum RoutingPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case cnDirect
    case globalProxy
    case gfwLike

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cnDirect:
            return "国内直连"
        case .globalProxy:
            return "全局代理"
        case .gfwLike:
            return "常见被墙域名代理"
        }
    }

    public var description: String {
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
