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
          return "待处理"
        }
      }
    }
  }

  @Published private(set) var statusSummary = "准备就绪，可以直接导入节点并建立连接。"
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
  @Published private(set) var runtimeAssetStatus: NativeRuntimeAssetStatus?
  @Published private(set) var isRuntimeAssetActionInFlight = false
  @Published private(set) var runtimeAssetActivityLabel = ""
  @Published private(set) var packetTunnelStatus: NativePacketTunnelStatus = .notInstalled
  @Published private(set) var packetTunnelProviderBundleIdentifier = ""
  @Published private(set) var isPacketTunnelActionInFlight = false

  private let importer = NativeNodeImporter()
  private let compiler = NativeXrayConfigCompiler()
  private let uriParser = NativeVlessURIParser()
  private var nodeStore: NativeNodeStore?
  private var runtimeService: NativeRuntimeService?
  private var runtimeAssetService: NativeRuntimeAssetService?
  private var packetTunnelService: NativePacketTunnelService?
  private var runtimeLogLines: [String] = []

  private init() {}

  private struct PacketTunnelLaunchContext {
    let tunnelProfile: NativeProfile
    let runtimeProfile: NativeProfile
    let runtimeConfig: [String: Any]
  }

  var canStartRuntime: Bool {
    importedNode != nil
      && selectedRuntimeMode != .vpn
      && !isRuntimeActionInFlight
      && runtimeState != .running
  }

  var canStopRuntime: Bool {
    selectedRuntimeMode != .vpn
      && !isRuntimeActionInFlight
      && (runtimeState == .running || runtimeState == .starting)
  }

  var canInstallPacketTunnel: Bool {
    importedNode != nil && !isPacketTunnelActionInFlight
  }

  var canManageRuntimeAssets: Bool {
    runtimeAssetService != nil && !isRuntimeAssetActionInFlight
  }

  var canStartPacketTunnel: Bool {
    importedNode != nil
      && !isPacketTunnelActionInFlight
      && packetTunnelStatus != .installing
      && packetTunnelStatus != .connecting
      && packetTunnelStatus != .connected
  }

  var canStopPacketTunnel: Bool {
    !isPacketTunnelActionInFlight
      && (packetTunnelStatus == .connecting
        || packetTunnelStatus == .connected
        || packetTunnelStatus == .reasserting)
  }

  var canStartSelectedConnection: Bool {
    selectedRuntimeMode == .vpn ? canStartPacketTunnel : canStartRuntime
  }

  var canStopSelectedConnection: Bool {
    selectedRuntimeMode == .vpn ? canStopPacketTunnel : canStopRuntime
  }

  var primaryConnectionStatusLabel: String {
    selectedRuntimeMode == .vpn ? packetTunnelStatus.label : runtimeState.label
  }

  var primaryConnectionDetail: String {
    switch selectedRuntimeMode {
    case .vpn:
      return "通过 NetworkExtension 托管系统代理设置，不直接改写网络服务。"
    case .systemProxy:
      return "启动本地 Xray 后写入 macOS 系统代理。"
    case .localProxy:
      return "仅启动本地 HTTP / SOCKS 代理端口，不改动系统设置。"
    }
  }

  func startSelectedConnection() {
    if selectedRuntimeMode == .vpn {
      startPacketTunnel()
      return
    }

    startRuntime()
  }

  func stopSelectedConnection() {
    if selectedRuntimeMode == .vpn {
      stopPacketTunnel()
      return
    }

    stopRuntime()
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
      statusSummary = "节点已解析，可以直接连接、保存或查看生成配置。"
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
    statusSummary = "已载入节点，可以直接发起连接。"
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

  func refreshRuntimeAssets() {
    guard !isRuntimeAssetActionInFlight else {
      return
    }

    Task {
      await performRefreshRuntimeAssets(checkRemote: true, announce: true)
    }
  }

  func updateXrayCore() {
    guard !isRuntimeAssetActionInFlight else {
      return
    }

    Task {
      await performUpdateXrayCore()
    }
  }

  func updateGeodata() {
    guard !isRuntimeAssetActionInFlight else {
      return
    }

    Task {
      await performUpdateGeodata()
    }
  }

  func installPacketTunnelConfiguration() {
    guard !isPacketTunnelActionInFlight else {
      return
    }

    Task {
      await performInstallPacketTunnelConfiguration()
    }
  }

  func startPacketTunnel() {
    guard !isPacketTunnelActionInFlight else {
      return
    }

    Task {
      await performStartPacketTunnel()
    }
  }

  func stopPacketTunnel() {
    guard !isPacketTunnelActionInFlight else {
      return
    }

    Task {
      await performStopPacketTunnel()
    }
  }

  private func configureStaticContent() {
    statusSummary = "准备就绪，可以直接导入节点并建立连接。"
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
        title: "节点与配置",
        detail: "VLESS 解析、JSON 导入和 Xray 配置编译已经切到 Swift。",
        status: .completed
      ),
      Milestone(
        id: "runtime",
        title: "原生运行时与系统代理",
        detail: "Swift 版已经接管节点存储、xray 子进程、日志和 macOS 系统代理。",
        status: .completed
      ),
      Milestone(
        id: "tunnel",
        title: "VPN 连接",
        detail: "通过 Packet Tunnel 与 NetworkExtension 托管系统代理设置。",
        status: .completed
      ),
    ]
    notes = [
      "节点、配置生成、运行时、系统代理和 VPN 连接都由原生 Swift 逻辑驱动。",
      "更新后的内核和 GeoData 会优先写入应用支持目录，避免修改已签名的 App bundle。",
      "系统代理模式适合快速接入；VPN 模式适合通过 NetworkExtension 托管连接。",
      "当前 VPN 模式走的是托管代理链路，仍然比传统系统代理更适合正式分发。",
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

      let runtimeAssetService = NativeRuntimeAssetService(
        baseDirectoryURL: baseDirectoryURL,
        emit: { [weak self] message in
          Task { @MainActor in
            self?.appendRuntimeLog(message)
          }
        }
      )
      self.runtimeAssetService = runtimeAssetService
      await performRefreshRuntimeAssets(checkRemote: false, announce: false)

      let packetTunnelService = NativePacketTunnelService(
        stateDidChange: { [weak self] status in
          Task { @MainActor in
            self?.packetTunnelStatus = status
            self?.lastUpdated = Date()
            guard let self, self.selectedRuntimeMode == .vpn else {
              return
            }

            switch status {
            case .connected:
              self.statusSummary = "VPN 模式已连接，系统正通过 NetworkExtension 使用本地 Xray 代理。"
            case .ready:
              self.statusSummary = "VPN 配置已就绪，可以直接发起连接。"
            case .disconnecting:
              self.statusSummary = "VPN 正在断开。"
            case .failed, .invalid:
              self.statusSummary = "VPN 连接异常，请查看运行日志。"
            default:
              break
            }
          }
        },
        logDidEmit: { [weak self] message in
          Task { @MainActor in
            self?.appendRuntimeLog("packet tunnel: \(message)")
          }
        }
      )
      self.packetTunnelService = packetTunnelService
      packetTunnelProviderBundleIdentifier = packetTunnelService.providerBundleIdentifier
      await packetTunnelService.refresh()

      let collection = try nodeStore.load()
      savedNodes = collection.nodes
      selectedSavedNodeID = collection.selectedNodeID

      if let selectedDraft = collection.selectedNode ?? collection.nodes.first {
        loadSavedNode(selectedDraft)
      } else {
        loadSample()
      }

      await performRefreshRuntimeAssets(checkRemote: true, announce: false)
    } catch {
      appendRuntimeLog("native initialization failed: \(localizedMessage(for: error))")
      lastErrorMessage = localizedMessage(for: error)
      loadSample()
    }
  }

  private func performStartRuntime() async {
    if selectedRuntimeMode == .vpn {
      lastErrorMessage = "VPN 模式请使用连接页里的“连接 VPN”按钮。"
      return
    }

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
        ? "系统代理模式已连接，macOS 已切到本地 Xray 代理。"
        : "本地代理模式已连接，HTTP / SOCKS 端口已经就绪。"
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
    statusSummary = "连接已断开，本地 Xray 运行时已停止。"
    lastUpdated = Date()
  }

  private func performRefreshRuntimeAssets(checkRemote: Bool, announce: Bool) async {
    guard let runtimeAssetService else {
      if announce {
        lastErrorMessage = "运行时资源服务还没有初始化完成。"
      }
      return
    }

    isRuntimeAssetActionInFlight = true
    runtimeAssetActivityLabel = checkRemote ? "检查最新发布" : "读取本地资源"
    defer {
      isRuntimeAssetActionInFlight = false
      runtimeAssetActivityLabel = ""
    }

    do {
      let status = try await runtimeAssetService.refreshStatus(
        checkRemote: checkRemote,
        proxyPort: runtimeAssetProxyPort()
      )
      applyRuntimeAssetStatus(status)
      lastErrorMessage = nil
      if announce {
        statusSummary = "已刷新内核与 GeoData 状态。"
      }
    } catch {
      if announce {
        lastErrorMessage = localizedMessage(for: error)
      }
      appendRuntimeLog("runtime asset refresh failed: \(localizedMessage(for: error))")
      lastUpdated = Date()
    }
  }

  private func performUpdateXrayCore() async {
    guard let runtimeAssetService else {
      lastErrorMessage = "运行时资源服务还没有初始化完成。"
      return
    }

    isRuntimeAssetActionInFlight = true
    runtimeAssetActivityLabel = "更新 Xray 内核"
    defer {
      isRuntimeAssetActionInFlight = false
      runtimeAssetActivityLabel = ""
    }

    do {
      let previousStatus = runtimeAssetStatus
      let status = try await runtimeAssetService.updateXrayCore(proxyPort: runtimeAssetProxyPort())
      applyRuntimeAssetStatus(status)
      lastErrorMessage = nil
      let versionLabel = status.currentXrayVersionLabel
      let currentVersion = status.currentXrayVersion.flatMap(NativeVersion.init)
      let latestVersion = status.latestXrayVersion.flatMap(NativeVersion.init)
      let sourceUnchanged = previousStatus?.currentXrayPath == status.currentXrayPath
        && previousStatus?.currentXraySourceLabel == status.currentXraySourceLabel

      if let currentVersion, let latestVersion, currentVersion >= latestVersion, sourceUnchanged {
        statusSummary = "当前 Xray 内核 \(versionLabel) 已不旧于最新稳定版 \(status.latestXrayVersionLabel)。"
      } else {
        statusSummary = runtimeRestartHint(
          base: "Xray 内核已准备为 \(versionLabel)。更新写入应用支持目录，不会改动已签名的 App bundle。"
        )
      }
    } catch {
      lastErrorMessage = localizedMessage(for: error)
      appendRuntimeLog("xray core update failed: \(localizedMessage(for: error))")
      lastUpdated = Date()
    }
  }

  private func performUpdateGeodata() async {
    guard let runtimeAssetService else {
      lastErrorMessage = "运行时资源服务还没有初始化完成。"
      return
    }

    isRuntimeAssetActionInFlight = true
    runtimeAssetActivityLabel = "更新 GeoData"
    defer {
      isRuntimeAssetActionInFlight = false
      runtimeAssetActivityLabel = ""
    }

    do {
      let previousStatus = runtimeAssetStatus
      let status = try await runtimeAssetService.updateGeodata(proxyPort: runtimeAssetProxyPort())
      applyRuntimeAssetStatus(status)
      lastErrorMessage = nil
      let alreadyLatest = previousStatus?.installedGeodataReleaseTag == status.installedGeodataReleaseTag
        && previousStatus?.installedGeodataUpdatedAt == status.installedGeodataUpdatedAt
        && status.installedGeodataReleaseTag == status.latestGeodataReleaseTag

      if alreadyLatest {
        statusSummary = "GeoData 已经是最新发布 \(status.installedGeodataReleaseLabel)。"
      } else {
        statusSummary = runtimeRestartHint(
          base: "GeoData 已更新到 \(status.installedGeodataReleaseLabel)。更新写入应用支持目录，不会改动已签名的 App bundle。"
        )
      }
    } catch {
      lastErrorMessage = localizedMessage(for: error)
      appendRuntimeLog("geodata update failed: \(localizedMessage(for: error))")
      lastUpdated = Date()
    }
  }

  private func performInstallPacketTunnelConfiguration() async {
    guard let packetTunnelService else {
      lastErrorMessage = "Packet Tunnel 服务还没有初始化完成。"
      return
    }

    isPacketTunnelActionInFlight = true
    defer { isPacketTunnelActionInFlight = false }

    do {
      let context = try packetTunnelLaunchContext()
      try await packetTunnelService.installOrUpdate(
        profile: context.tunnelProfile,
        config: context.runtimeConfig
      )
      packetTunnelProviderBundleIdentifier = packetTunnelService.providerBundleIdentifier
      lastErrorMessage = nil
      statusSummary = "VPN 配置已写入系统，可以直接发起连接。"
      lastUpdated = Date()
    } catch {
      lastErrorMessage = localizedMessage(for: error)
      appendRuntimeLog("packet tunnel install failed: \(localizedMessage(for: error))")
      lastUpdated = Date()
    }
  }

  private func performStartPacketTunnel() async {
    guard let packetTunnelService else {
      lastErrorMessage = "Packet Tunnel 服务还没有初始化完成。"
      return
    }
    guard let runtimeService else {
      lastErrorMessage = "原生运行时服务还没有初始化完成。"
      return
    }

    isPacketTunnelActionInFlight = true
    defer { isPacketTunnelActionInFlight = false }

    do {
      let context = try packetTunnelLaunchContext()
      runtimeLogLines.removeAll()
      runtimeLogText = ""
      appendRuntimeLog("starting local xray runtime for vpn mode")
      let launchInfo = try await runtimeService.start(
        profile: context.runtimeProfile,
        config: context.runtimeConfig
      )
      runtimeBinaryPath = launchInfo.xrayBinaryPath
      runtimeGeodataPath = launchInfo.geodataDirectoryPath

      do {
        try await packetTunnelService.start(
          profile: context.tunnelProfile,
          config: context.runtimeConfig
        )
      } catch {
        appendRuntimeLog("packet tunnel failed after local proxy launch; stopping runtime")
        await runtimeService.stop()
        throw error
      }

      packetTunnelProviderBundleIdentifier = packetTunnelService.providerBundleIdentifier
      lastErrorMessage = nil
      statusSummary = "VPN 连接已发起，系统将切换到由 NetworkExtension 托管的本地 Xray 代理。"
      lastUpdated = Date()
    } catch {
      lastErrorMessage = localizedMessage(for: error)
      appendRuntimeLog("packet tunnel start failed: \(localizedMessage(for: error))")
      lastUpdated = Date()
    }
  }

  private func performStopPacketTunnel() async {
    guard let packetTunnelService else {
      lastErrorMessage = "Packet Tunnel 服务还没有初始化完成。"
      return
    }

    isPacketTunnelActionInFlight = true
    defer { isPacketTunnelActionInFlight = false }

    await packetTunnelService.stop()
    appendRuntimeLog("stopping local xray runtime for vpn mode")
    await runtimeService?.stop()
    statusSummary = "VPN 模式已断开。"
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
    guard let profile = previewProfile() else {
      return
    }

    do {
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

  private func applyRuntimeAssetStatus(_ status: NativeRuntimeAssetStatus) {
    runtimeAssetStatus = status
    lastUpdated = Date()
  }

  private func runtimeAssetProxyPort() -> Int? {
    runtimeService?.currentHTTPProxyPort
  }

  private func runtimeRestartHint(base: String) -> String {
    if runtimeState == .running || runtimeState == .starting {
      return "\(base) 重启运行时后生效。"
    }
    return "\(base) 下次启动运行时会自动使用新资源。"
  }

  private func packetTunnelLaunchContext() throws -> PacketTunnelLaunchContext {
    guard let importedNode else {
      throw NativeImportError.message("当前没有可用于 Packet Tunnel 的节点。")
    }

    let runtimeProfile = NativeProfile.from(
      node: importedNode,
      routingPreset: selectedRoutingPreset,
      runtimeMode: .localProxy
    )
    let tunnelProfile = NativeProfile(
      id: runtimeProfile.id,
      name: runtimeProfile.name,
      node: runtimeProfile.node,
      routingPreset: runtimeProfile.routingPreset,
      runtimeMode: .vpn,
      socksPort: runtimeProfile.socksPort,
      httpPort: runtimeProfile.httpPort,
      tunMtu: runtimeProfile.tunMtu
    )
    let runtimeConfig = try compiler.compile(profile: runtimeProfile)

    return PacketTunnelLaunchContext(
      tunnelProfile: tunnelProfile,
      runtimeProfile: runtimeProfile,
      runtimeConfig: runtimeConfig
    )
  }

  private func previewProfile() -> NativeProfile? {
    guard let importedNode else {
      return nil
    }

    return NativeProfile.from(
      node: importedNode,
      routingPreset: selectedRoutingPreset,
      runtimeMode: selectedRuntimeMode == .vpn ? .localProxy : selectedRuntimeMode
    )
  }

  private static let logDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static let sampleVlessLink =
    "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=xhttp&security=reality&sni=cdn.example.com&fp=chrome&pbk=samplePublicKey&sid=abcd1234&host=cdn.example.com&path=%2Fxray&mode=auto#Sample%20Native%20Node"
}
