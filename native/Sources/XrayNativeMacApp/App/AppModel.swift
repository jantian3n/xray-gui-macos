import AppKit
import Foundation
import Observation
import XrayNativeCore
import XrayNativeDesktopRuntime

@MainActor
@Observable
final class AppModel {
    struct CompiledDraft {
        let profile: Profile
        let config: [String: Any]
        let configPreview: String
    }

    private let nodeImporter = NodeImporter()
    private let compiler = XrayConfigCompiler()
    private let runtime = XrayDesktopRuntime()
    private let store: NodeStore

    var drafts: [StoredNodeDraft] = []
    var selectedNodeID: String?
    var configPreview = ""
    var status = "idle"
    var trafficSnapshot = RuntimeTrafficSnapshot.zero
    var logs: [String] = []
    var errorMessage: String?
    var infoMessage: String?

    init() {
        do {
            store = try NodeStore()
        } catch {
            let fallbackDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("XrayNativeFallback", isDirectory: true)
            store = NodeStore(configuration: .init(directoryURL: fallbackDirectory))
            errorMessage = "初始化持久化目录失败，已切换到临时目录：\(error.localizedDescription)"
        }

        runtime.onLog = { [weak self] line in
            DispatchQueue.main.async {
                self?.appendLog(line)
            }
        }
        runtime.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.status = state
            }
        }
        runtime.onTrafficSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.trafficSnapshot = snapshot
            }
        }
    }

    var selectedDraft: StoredNodeDraft? {
        guard let selectedNodeID else {
            return nil
        }
        return drafts.first(where: { $0.id == selectedNodeID })
    }

    var isRuntimeLocked: Bool {
        ["starting", "stopping", "running", "running-dry"].contains(status)
    }

    var isRuntimeTransitioning: Bool {
        ["starting", "stopping"].contains(status)
    }

    var canStart: Bool {
        selectedDraft != nil && !isRuntimeLocked
    }

    var menuBarTitle: String {
        switch status {
        case "running":
            return "↑ \(formatRate(trafficSnapshot.uploadBytesPerSecond)) ↓ \(formatRate(trafficSnapshot.downloadBytesPerSecond))"
        case "starting":
            return "连接中"
        case "stopping":
            return "停止中"
        default:
            return "未连接"
        }
    }

    var statusLabel: String {
        switch status {
        case "running":
            return "运行中"
        case "starting":
            return "连接中"
        case "stopping":
            return "停止中"
        case "profile-ready":
            return "已就绪"
        case "error":
            return "错误"
        default:
            return "未连接"
        }
    }

    var selectedNodeTitle: String {
        guard let draft = selectedDraft else {
            return "未选择节点"
        }
        let name = draft.node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "\(draft.node.address):\(draft.node.port)" : name
    }

    var runtimeModeDescription: String {
        runtime.runtimeModeDescription(.localProxy)
    }

    func load() {
        do {
            let collection = try store.load()
            commitCollection(
                nodes: collection.nodes,
                selectedNodeID: collection.selectedNodeID,
                successStatus: "profile-ready",
                shouldShowError: false
            )
        } catch {
            showError(error)
        }
    }

    func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            infoMessage = "剪贴板里没有可用的节点内容。"
            return
        }
        importRawText(text)
    }

    func importRawText(_ raw: String) {
        if isRuntimeLocked {
            infoMessage = "运行中请先停止连接，再导入新节点。"
            return
        }

        do {
            let node = try nodeImporter.parseNode(raw)
            let draft = try createDraft(node: node, base: nil)
            let nodes = [draft] + drafts
            commitCollection(
                nodes: nodes,
                selectedNodeID: draft.id,
                successStatus: "profile-ready",
                shouldShowError: true
            )
            infoMessage = "节点已导入并设为当前节点。"
        } catch {
            showError(error)
        }
    }

    func applyPatchFromClipboard() {
        guard let draft = selectedDraft else {
            infoMessage = "请先选中一个节点，再应用 split patch。"
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            infoMessage = "剪贴板里没有可用的补丁内容。"
            return
        }
        applyPatch(raw: text, to: draft)
    }

    func applyPatch(raw: String, to draft: StoredNodeDraft? = nil) {
        guard let draft = draft ?? selectedDraft else {
            infoMessage = "请先选中一个节点，再应用 split patch。"
            return
        }
        if isRuntimeLocked {
            infoMessage = "运行中请先停止连接，再应用补丁。"
            return
        }

        do {
            let updatedNode = try nodeImporter.applyPatch(baseNode: draft.node, raw: raw)
            let updatedDraft = try createDraft(node: updatedNode, base: draft)
            let nodes = drafts.map { $0.id == draft.id ? updatedDraft : $0 }
            commitCollection(
                nodes: nodes,
                selectedNodeID: updatedDraft.id,
                successStatus: "profile-ready",
                shouldShowError: true
            )
            infoMessage = "split patch 已应用到当前节点。"
        } catch {
            showError(error)
        }
    }

    func selectNode(_ nodeID: String) {
        guard let draft = drafts.first(where: { $0.id == nodeID }) else {
            return
        }
        if isRuntimeTransitioning {
            if draft.id != selectedNodeID {
                infoMessage = "连接状态切换中，请稍后再试。"
            }
            return
        }
        if isRuntimeLocked {
            if draft.id != selectedNodeID {
                infoMessage = "运行中请先停止连接，再切换节点。"
            }
            return
        }

        commitCollection(
            nodes: drafts,
            selectedNodeID: draft.id,
            successStatus: "profile-ready",
            shouldShowError: true
        )
    }

    func deleteSelectedNode() {
        guard let draft = selectedDraft else {
            return
        }
        if isRuntimeLocked {
            infoMessage = "运行中请先停止连接，再删除节点。"
            return
        }

        let nodes = drafts.filter { $0.id != draft.id }
        let nextSelectedNodeID = draft.id == selectedNodeID ? nodes.first?.id : selectedNodeID
        commitCollection(
            nodes: nodes,
            selectedNodeID: nextSelectedNodeID,
            successStatus: "profile-ready",
            shouldShowError: true
        )
        infoMessage = "节点已删除。"
    }

    func updateSelectedRoutingPreset(_ preset: RoutingPreset) {
        guard let selectedDraft, !isRuntimeLocked else {
            return
        }
        let updatedDraft = StoredNodeDraft(
            id: selectedDraft.id,
            node: selectedDraft.node,
            routingPreset: preset,
            runtimeMode: selectedDraft.runtimeMode
        )
        let nodes = drafts.map { $0.id == updatedDraft.id ? updatedDraft : $0 }
        commitCollection(
            nodes: nodes,
            selectedNodeID: updatedDraft.id,
            successStatus: "profile-ready",
            shouldShowError: true
        )
    }

    func updateSelectedRuntimeMode(_ mode: RuntimeMode) {
        guard let selectedDraft, !isRuntimeLocked else {
            return
        }
        let updatedDraft = StoredNodeDraft(
            id: selectedDraft.id,
            node: selectedDraft.node,
            routingPreset: selectedDraft.routingPreset,
            runtimeMode: runtime.normalizeRuntimeMode(mode)
        )
        let nodes = drafts.map { $0.id == updatedDraft.id ? updatedDraft : $0 }
        commitCollection(
            nodes: nodes,
            selectedNodeID: updatedDraft.id,
            successStatus: "profile-ready",
            shouldShowError: true
        )
    }

    func startRuntime() {
        guard let selectedDraft else {
            infoMessage = "请先选择一个节点。"
            return
        }

        do {
            let compiled = try compile(draft: selectedDraft)
            try runtime.start(profile: compiled.profile, config: compiled.config)
            configPreview = compiled.configPreview
            status = "starting"
        } catch {
            showError(error)
        }
    }

    func stopRuntime() {
        runtime.stop()
        status = "stopping"
    }

    func updateGeodata() {
        Task {
            do {
                try await runtime.updateGeodata()
                await MainActor.run {
                    self.infoMessage = "已请求更新 geodata。"
                }
            } catch {
                await MainActor.run {
                    self.showError(error)
                }
            }
        }
    }

    func quitApp() {
        if isRuntimeLocked {
            runtime.stop()
        }
        NSApplication.shared.terminate(nil)
    }

    func clearError() {
        errorMessage = nil
    }

    func clearInfo() {
        infoMessage = nil
    }

    func summaryRows(for node: VLESSNode) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("地址", node.address),
            ("端口", "\(node.port)"),
            ("UUID", node.id),
            ("传输", node.network),
            ("安全", node.security),
        ]

        if !node.serverName.isEmpty {
            rows.append(("SNI", node.serverName))
        }
        if !node.fingerprint.isEmpty {
            rows.append(("指纹", node.fingerprint))
        }
        if !node.publicKey.isEmpty {
            rows.append(("Public Key", node.publicKey))
        }
        if !node.path.isEmpty {
            rows.append(("Path", node.path))
        }
        if !node.mode.isEmpty {
            rows.append(("Mode", node.mode))
        }
        if let download = node.downloadSettings {
            rows.append(("Download", "\(download.address):\(download.port)"))
        }
        return rows
    }

    func formatRate(_ bytesPerSecond: Int) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(max(0, bytesPerSecond))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    private func createDraft(node: VLESSNode, base: StoredNodeDraft?) throws -> StoredNodeDraft {
        if node.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DraftError.missingAddress
        }
        if node.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DraftError.missingUUID
        }
        return StoredNodeDraft(
            id: base?.id ?? "node-\(Int(Date().timeIntervalSince1970 * 1_000_000))",
            node: node,
            routingPreset: base?.routingPreset ?? .cnDirect,
            runtimeMode: runtime.normalizeRuntimeMode(base?.runtimeMode ?? .localProxy)
        )
    }

    private func compile(draft: StoredNodeDraft) throws -> CompiledDraft {
        let profile = Profile.fromNode(
            draft.node,
            routingPreset: draft.routingPreset,
            runtimeMode: runtime.normalizeRuntimeMode(draft.runtimeMode)
        )
        let config = try compiler.compile(profile)
        let preview = try JSONCoding.prettyPrintedString(from: config)
        return CompiledDraft(profile: profile, config: config, configPreview: preview)
    }

    private func commitCollection(
        nodes: [StoredNodeDraft],
        selectedNodeID: String?,
        successStatus: String,
        shouldShowError: Bool
    ) {
        let normalizedNodes = nodes.map {
            StoredNodeDraft(
                id: $0.id,
                node: $0.node,
                routingPreset: $0.routingPreset,
                runtimeMode: runtime.normalizeRuntimeMode($0.runtimeMode)
            )
        }
        let selectedDraft = normalizedNodes.first(where: { $0.id == selectedNodeID })

        guard let selectedDraft else {
            drafts = normalizedNodes
            self.selectedNodeID = nil
            configPreview = ""
            status = normalizedNodes.isEmpty ? "idle" : successStatus
            persist(nodes: normalizedNodes, selectedNodeID: nil)
            return
        }

        do {
            let compiled = try compile(draft: selectedDraft)
            drafts = normalizedNodes
            self.selectedNodeID = selectedDraft.id
            configPreview = compiled.configPreview
            status = successStatus
        } catch {
            drafts = normalizedNodes
            self.selectedNodeID = selectedDraft.id
            configPreview = ""
            status = "error"
            if shouldShowError {
                showError(error)
            }
        }

        persist(nodes: normalizedNodes, selectedNodeID: selectedDraft.id)
    }

    private func persist(nodes: [StoredNodeDraft], selectedNodeID: String?) {
        do {
            try store.save(StoredNodeCollection(nodes: nodes, selectedNodeID: selectedNodeID))
        } catch {
            showError(error)
        }
    }

    private func appendLog(_ line: String) {
        logs.insert(line, at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
        if let state = extractState(from: line) {
            status = state
        }
    }

    private func extractState(from line: String) -> String? {
        guard line.hasPrefix("state=") else {
            return nil
        }
        let value = String(line.dropFirst("state=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}

private enum DraftError: LocalizedError {
    case missingAddress
    case missingUUID

    var errorDescription: String? {
        switch self {
        case .missingAddress:
            return "请先填写服务器地址。"
        case .missingUUID:
            return "请先填写 UUID。"
        }
    }
}
