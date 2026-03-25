import Foundation

public struct StoredNodeDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var node: VLESSNode
    public var routingPreset: RoutingPreset
    public var runtimeMode: RuntimeMode

    public init(
        id: String,
        node: VLESSNode,
        routingPreset: RoutingPreset,
        runtimeMode: RuntimeMode
    ) {
        self.id = id
        self.node = node
        self.routingPreset = routingPreset
        self.runtimeMode = runtimeMode
    }
}

public struct StoredNodeCollection: Codable, Equatable, Sendable {
    public var nodes: [StoredNodeDraft]
    public var selectedNodeID: String?

    public init(nodes: [StoredNodeDraft], selectedNodeID: String?) {
        self.nodes = nodes
        self.selectedNodeID = selectedNodeID
    }

    public var selectedNode: StoredNodeDraft? {
        guard let selectedNodeID else {
            return nil
        }
        return nodes.first(where: { $0.id == selectedNodeID })
    }

    public static let empty = StoredNodeCollection(nodes: [], selectedNodeID: nil)
}
