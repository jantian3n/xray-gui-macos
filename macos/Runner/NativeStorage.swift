import Foundation

struct NativeStoredNodeDraft: Codable, Equatable, Identifiable {
  let id: String
  let node: NativeVlessNode
  let routingPreset: NativeRoutingPreset
  let runtimeMode: NativeRuntimeMode

  init(
    id: String,
    node: NativeVlessNode,
    routingPreset: NativeRoutingPreset,
    runtimeMode: NativeRuntimeMode
  ) {
    self.id = id
    self.node = node
    self.routingPreset = routingPreset
    self.runtimeMode = runtimeMode
  }

  var title: String {
    let trimmed = node.name.trimmed()
    return trimmed.isEmpty ? "\(node.address):\(node.port)" : trimmed
  }
}

struct NativeStoredNodeCollection: Codable, Equatable {
  var nodes: [NativeStoredNodeDraft]
  var selectedNodeID: String?

  static let empty = NativeStoredNodeCollection(nodes: [], selectedNodeID: nil)

  var selectedNode: NativeStoredNodeDraft? {
    guard let selectedNodeID else { return nil }
    return nodes.first(where: { $0.id == selectedNodeID })
  }
}

final class NativeNodeStore {
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private let decoder = JSONDecoder()
  private let snapshotURL: URL
  private let fileManager = FileManager.default

  init(baseDirectoryURL: URL) {
    snapshotURL = baseDirectoryURL.appendingPathComponent("node_list.snapshot.v1.json")
  }

  func load() throws -> NativeStoredNodeCollection {
    guard fileManager.fileExists(atPath: snapshotURL.path) else {
      return .empty
    }

    let data = try Data(contentsOf: snapshotURL)
    var collection = try decoder.decode(NativeStoredNodeCollection.self, from: data)
    collection.nodes = collection.nodes.filter { !$0.id.trimmed().isEmpty && !$0.node.address.trimmed().isEmpty }
    if let selectedNodeID = collection.selectedNodeID,
       collection.nodes.contains(where: { $0.id == selectedNodeID }) {
      return collection
    }
    collection.selectedNodeID = collection.nodes.first?.id
    return collection
  }

  func save(_ collection: NativeStoredNodeCollection) throws {
    try fileManager.createDirectory(
      at: snapshotURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if collection.nodes.isEmpty {
      if fileManager.fileExists(atPath: snapshotURL.path) {
        try fileManager.removeItem(at: snapshotURL)
      }
      return
    }

    let data = try encoder.encode(collection)
    try data.write(to: snapshotURL, options: .atomic)
  }
}
