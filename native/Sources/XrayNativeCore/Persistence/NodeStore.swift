import Foundation

public struct NodeStore: Sendable {
    public struct Configuration: Sendable {
        public var directoryURL: URL
        public var fileName: String

        public init(directoryURL: URL, fileName: String = "node_list.snapshot.v1.json") {
            self.directoryURL = directoryURL
            self.fileName = fileName
        }

        public static func `default`() throws -> Configuration {
            let baseDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "XrayNative"
            let directory = baseDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
            return Configuration(directoryURL: directory)
        }
    }

    private let configuration: Configuration
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(configuration: Configuration) {
        self.configuration = configuration
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public init() throws {
        self.init(configuration: try .default())
    }

    public func load() throws -> StoredNodeCollection {
        let fileURL = configuration.directoryURL.appendingPathComponent(configuration.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try decoder.decode(StoredNodeCollection.self, from: data)
        let validNodes = decoded.nodes.filter {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.node.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.node.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let selectedNodeID = validNodes.contains(where: { $0.id == decoded.selectedNodeID })
            ? decoded.selectedNodeID
            : validNodes.first?.id
        return StoredNodeCollection(nodes: validNodes, selectedNodeID: selectedNodeID)
    }

    public func save(_ collection: StoredNodeCollection) throws {
        try FileManager.default.createDirectory(
            at: configuration.directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = configuration.directoryURL.appendingPathComponent(configuration.fileName)
        let data = try encoder.encode(collection)
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        let fileURL = configuration.directoryURL.appendingPathComponent(configuration.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}
