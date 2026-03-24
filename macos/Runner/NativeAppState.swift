import Foundation
import SwiftUI

@MainActor
final class NativeAppState: ObservableObject {
  static let shared = NativeAppState()

  struct Milestone: Identifiable {
    let id: String
    let title: String
    let detail: String
    let status: Status

    enum Status {
      case completed
      case inProgress
      case pending

      var label: String {
        switch self {
        case .completed:
          return "已完成"
        case .inProgress:
          return "进行中"
        case .pending:
          return "待迁移"
        }
      }
    }
  }

  @Published private(set) var statusSummary = "正在把 Flutter 版迁移到原生 SwiftUI。"
  @Published private(set) var lastUpdated = Date()
  @Published private(set) var milestones: [Milestone] = []
  @Published private(set) var notes: [String] = []
  @Published private(set) var savedNodes: [NativeStoredNodeDraft] = []
  @Published private(set) var selectedSavedNodeID: String?
  @Published var importText = ""
  @Published var selectedRoutingPreset: NativeRoutingPreset = .cnDirect {
    didSet { refreshCompiledConfigIfPossible() }
  }
  @Published var selectedRuntimeMode: NativeRuntimeMode = .systemProxy {
    didSet { refreshCompiledConfigIfPossible() }
  }
  @Published private(set) var importedNode: NativeVlessNode?
  @Published private(set) var compiledConfigPreview = ""
  @Published private(set) var lastErrorMessage: String?
  @Published private(set) var runtimeState: NativeRuntimeState = .idle
  @Published private(set) var runtimeLogText = ""
  @Published private(set) var runtimeBinaryPath = ""
  @Published private(set) var runtimeGeodataPath = ""
  @Published private(set) var isRuntimeActionInFlight = false

  private let importer = NativeNodeImporter()
  private let compiler = NativeXrayConfigCompiler()
  private let uriParser = NativeVlessURIParser()
  private var nodeStore: NativeNodeStore?
  private var runtimeService: NativeRuntimeService?
  private var runtimeLogLines: [String] = []

  private init() {}

  var canStartRuntime: Bool {
    importedNode != nil && !isRuntimeActionInFlight && runtimeState != .running
  }

  var canStopRuntime: Bool {
    !isRuntimeActionInFlight && (runtimeState == .running || runtimeState == .starting)
  }

  func bootstrap() {
    configureStaticContent()

    Task {
      await initializeNativeServices()
    }
  }

  func loadSample() {
    importText = Self.sampleVlessLink
    importCurrentText()
  }

  func importCurrentText() {
    do {
      let node = try importer.parseNode(importText)
      selectedSavedNodeID = nil
      importedNode = node
      lastErrorMessage = nil
      statusSummary = "Swift 版本已经可以直接解析节点并生成 Xray 配置，也可以继续保存和启动运行时。"
      refreshCompiledConfig()
    } catch {
      importedNode = nil
      compiledConfigPreview = ""
      lastErrorMessage = localizedMessage(for: error)
      lastUpdated = Date()
    }
  }

  func resetToSample() {
    loadSample()
  }

  func saveCurrentNode() {
    guard let importedNode else {
      lastErrorMessage = "当前没有可保存的节点。"
      return
    }

    let draftID = selectedSavedNodeID ?? "node-\(UUID().uuidString.lowercased())"
    let draft = NativeStoredNodeDraft(
      id: draftID,
      node: importedNode,
      routingPreset: selectedRoutingPreset,
      runtimeMode: selectedRuntimeMode
    )

    if let existingIndex = savedNodes.firstIndex(where: { $0.id == draftID }) {
      savedNodes[existingIndex] = draft
    } else {
      savedNodes.insert(draft, at: 0)
    }

    selectedSavedNodeID = draftID
    persistSavedNodes()
    statusSummary = "当前节点已经保存到原生本地存储。"
    lastErrorMessage = nil
    lastUpdated = Date()
  }

  func loadSavedNode(_ draft: NativeStoredNodeDraft) {
    selectedSavedNodeID = draft.id
    selectedRoutingPreset = draft.routingPreset
    selectedRuntimeMode = draft.runtimeMode
    importedNode = draft.node
    importText = uriParser.encode(draft.node)
    compiledConfigPreview = ""
    lastErrorMessage = nil
    statusSummary = "已载入保存节点，可以直接启动原生运行时。"
    refreshCompiledConfig()
  }

  func deleteSavedNode(_ draft: NativeStoredNodeDraft) {
    savedNodes.removeAll { $0.id == draft.id }
    if selectedSavedNodeID == draft.id {
      selectedSavedNodeID = nil
    }
    persistSavedNodes()
    statusSummary = "已删除保存节点。"
    lastUpdated = Date()
  }

  func startRuntime() {
    guard !isRuntimeActionInFlight else {
      return
    }

    Task {
      await performStartRuntime()
    }
  }

  func stopRuntime() {
    guard !isRuntimeActionInFlight else {
      return
    }

    Task {
      await performStopRuntime()
    }
  }

  private func configureStaticContent() {
    statusSummary = "原生 macOS 壳已经接管入口，接下来把保存、运行时和系统代理也一起迁到 Swift。"
    lastUpdated = Date()
    milestones = [
      Milestone(
        id: "shell",
        title: "原生 SwiftUI 入口",
        detail: "Runner 目标已改为原生 SwiftUI/AppKit 窗口，应用菜单和主窗口由 Swift 托管。",
        status: .completed
      ),
      Milestone(
        id: "logic",
        title: "节点与配置逻辑迁移",
        detail: "VLESS 解析、JSON 导入和 Xray 配置编译已经切到 Swift。",
        status: .completed
      ),
      Milestone(
        id: "runtime",
        title: "原生运行时与系统代理",
        detail: "Swift 版开始接管节点存储、xray 子进程、日志和 macOS 系统代理。",
        status: .inProgress
      ),
    ]
    notes = [
      "现有 Flutter 版本的功能还保留在仓库里，方便逐块对照迁移。",
      "目标不是双端长期共存，而是把 macOS 版逐步完全收口到 Swift。",
      "优先迁移最短可用链路：导入节点、保存节点、生成配置、启动运行时、系统代理、再到 Packet Tunnel。",
    ]
  }

  private func initializeNativeServices() async {
    do {
      let baseDirectoryURL = try NativeAppDirectories.baseDirectoryURL()
      let nodeStore = NativeNodeStore(baseDirectoryURL: baseDirectoryURL)
      self.nodeStore = nodeStore

      let runtimeService = NativeRuntimeService(
        baseDirectoryURL: baseDirectoryURL,
        stateDidChange: { [weak self] state in
          Task { @MainActor in
            self?.runtimeState = state
            self?.lastUpdated = Date()
          }
        },
        logDidEmit: { [weak self] message in
          Task { @MainActor in
            self?.appendRuntimeLog(message)
          }
        }
      )
      self.runtimeService = runtimeService

      try runtimeService.initialize()
      appendRuntimeLog("native runtime base directory: \(baseDirectoryURL.path)")

      let collection = try nodeStore.load()
      savedNodes = collection.nodes
      selectedSavedNodeID = collection.selectedNodeID

      if let selectedDraft = collection.selectedNode ?? collection.nodes.first {
        loadSavedNode(selectedDraft)
      } else {
        loadSample()
      }
    } catch {
      appendRuntimeLog("native initialization failed: \(localizedMessage(for: error))")
      lastErrorMessage = localizedMessage(for: error)
      loadSample()
    }
  }

  private func performStartRuntime() async {
    guard let importedNode else {
      lastErrorMessage = "当前没有可启动的节点。"
      return
    }
    guard let runtimeService else {
      lastErrorMessage = "原生运行时服务还没有初始化完成。"
      return
    }

    isRuntimeActionInFlight = true
    defer { isRuntimeActionInFlight = false }

    do {
      let profile = NativeProfile.from(
        node: importedNode,
        routingPreset: selectedRoutingPreset,
        runtimeMode: selectedRuntimeMode
      )
      let config = try compiler.compile(profile: profile)
      runtimeLogLines.removeAll()
      runtimeLogText = ""
      appendRuntimeLog("starting native xray runtime for \(profile.name)")
      let launchInfo = try await runtimeService.start(profile: profile, config: config)
      runtimeBinaryPath = launchInfo.xrayBinaryPath
      runtimeGeodataPath = launchInfo.geodataDirectoryPath
      lastErrorMessage = nil
      statusSummary = selectedRuntimeMode == .systemProxy
        ? "原生运行时已经启动，并尝试接管 macOS 系统代理。"
        : "原生运行时已经启动，本地代理端口已经就绪。"
      lastUpdated = Date()
    } catch {
      lastErrorMessage = localizedMessage(for: error)
      appendRuntimeLog("runtime start failed: \(localizedMessage(for: error))")
      lastUpdated = Date()
    }
  }

  private func performStopRuntime() async {
    guard let runtimeService else {
      return
    }

    isRuntimeActionInFlight = true
    defer { isRuntimeActionInFlight = false }

    appendRuntimeLog("stopping native xray runtime")
    await runtimeService.stop()
    statusSummary = "原生运行时已经停止。"
    lastUpdated = Date()
  }

  private func persistSavedNodes() {
    guard let nodeStore else {
      return
    }

    do {
      try nodeStore.save(
        NativeStoredNodeCollection(
          nodes: savedNodes,
          selectedNodeID: selectedSavedNodeID
        )
      )
    } catch {
      lastErrorMessage = localizedMessage(for: error)
      appendRuntimeLog("save node snapshot failed: \(localizedMessage(for: error))")
    }
  }

  private func refreshCompiledConfigIfPossible() {
    guard importedNode != nil else {
      return
    }
    refreshCompiledConfig()
  }

  private func refreshCompiledConfig() {
    guard let importedNode else {
      return
    }

    do {
      let profile = NativeProfile.from(
        node: importedNode,
        routingPreset: selectedRoutingPreset,
        runtimeMode: selectedRuntimeMode
      )
      let config = try compiler.compile(profile: profile)
      compiledConfigPreview = try prettyJSONString(from: config)
      lastErrorMessage = nil
      lastUpdated = Date()
    } catch {
      compiledConfigPreview = ""
      lastErrorMessage = localizedMessage(for: error)
      lastUpdated = Date()
    }
  }

  private func prettyJSONString(from value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  private func localizedMessage(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  private func appendRuntimeLog(_ line: String) {
    let timestamp = Self.logDateFormatter.string(from: Date())
    runtimeLogLines.append("[\(timestamp)] \(line)")
    if runtimeLogLines.count > 300 {
      runtimeLogLines.removeFirst(runtimeLogLines.count - 300)
    }
    runtimeLogText = runtimeLogLines.joined(separator: "\n")
  }

  private static let logDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static let sampleVlessLink =
    "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=xhttp&security=reality&sni=cdn.example.com&fp=chrome&pbk=samplePublicKey&sid=abcd1234&host=cdn.example.com&path=%2Fxray&mode=auto#Sample%20Native%20Node"
}
