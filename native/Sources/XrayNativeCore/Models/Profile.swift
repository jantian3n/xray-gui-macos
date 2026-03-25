import Foundation

public struct Profile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var node: VLESSNode
    public var routingPreset: RoutingPreset
    public var runtimeMode: RuntimeMode
    public var socksPort: Int
    public var httpPort: Int
    public var tunMTU: Int

    public init(
        id: String,
        name: String,
        node: VLESSNode,
        routingPreset: RoutingPreset = .cnDirect,
        runtimeMode: RuntimeMode = .vpn,
        socksPort: Int = 10808,
        httpPort: Int = 10809,
        tunMTU: Int = 1500
    ) {
        self.id = id
        self.name = name
        self.node = node
        self.routingPreset = routingPreset
        self.runtimeMode = runtimeMode
        self.socksPort = socksPort
        self.httpPort = httpPort
        self.tunMTU = tunMTU
    }

    public static func fromNode(
        _ node: VLESSNode,
        routingPreset: RoutingPreset = .cnDirect,
        runtimeMode: RuntimeMode = .vpn
    ) -> Profile {
        let trimmedName = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty ? "\(node.address):\(node.port)" : trimmedName
        return Profile(
            id: safeName.slugified(),
            name: safeName,
            node: node,
            routingPreset: routingPreset,
            runtimeMode: runtimeMode
        )
    }
}
