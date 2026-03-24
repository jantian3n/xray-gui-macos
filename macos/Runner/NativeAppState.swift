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

  private let importer = NativeNodeImporter()
  private let compiler = NativeXrayConfigCompiler()

  private init() {}

  func bootstrap() {
    statusSummary = "原生 macOS 壳已经接管入口，节点导入和 Xray 配置编译也开始转入 Swift。"
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
        detail: "VLESS 解析、JSON 导入和 Xray 配置编译已经有了首版 Swift 实现，接下来继续补存储和订阅。",
        status: .completed
      ),
      Milestone(
        id: "runtime",
        title: "原生运行时与系统代理",
        detail: "接下来会把 xray 子进程管理、日志、系统代理和后续 Packet Tunnel 一并移到 Swift。",
        status: .pending
      ),
    ]
    notes = [
      "现有 Flutter 版本的功能还保留在仓库里，方便逐块对照迁移。",
      "目标不是双端长期共存，而是把 macOS 版逐步完全收口到 Swift。",
      "优先迁移最短可用链路：导入节点、生成配置、启动运行时、系统代理、再到 Packet Tunnel。",
    ]

    loadSample()
  }

  func loadSample() {
    importText = Self.sampleVlessLink
    importCurrentText()
  }

  func importCurrentText() {
    do {
      let node = try importer.parseNode(importText)
      importedNode = node
      lastErrorMessage = nil
      statusSummary = "Swift 版本已经可以直接解析节点并生成 Xray 配置草案。"
      refreshCompiledConfig()
    } catch {
      importedNode = nil
      compiledConfigPreview = ""
      lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      lastUpdated = Date()
    }
  }

  func resetToSample() {
    loadSample()
  }

  private func refreshCompiledConfigIfPossible() {
    guard importedNode != nil else { return }
    refreshCompiledConfig()
  }

  private func refreshCompiledConfig() {
    guard let importedNode else { return }

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
      lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      lastUpdated = Date()
    }
  }

  private func prettyJSONString(from value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  private static let sampleVlessLink =
    "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=xhttp&security=reality&sni=cdn.example.com&fp=chrome&pbk=samplePublicKey&sid=abcd1234&host=cdn.example.com&path=%2Fxray&mode=auto#Sample%20Native%20Node"
}
