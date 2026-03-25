import Observation
import SwiftUI
import XrayNativeCore

private enum SheetMode: Identifiable {
    case importNode
    case applyPatch

    var id: String {
        switch self {
        case .importNode:
            return "importNode"
        case .applyPatch:
            return "applyPatch"
        }
    }

    var title: String {
        switch self {
        case .importNode:
            return "导入节点"
        case .applyPatch:
            return "应用 split patch"
        }
    }

    var actionLabel: String {
        switch self {
        case .importNode:
            return "导入"
        case .applyPatch:
            return "应用"
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var activeSheet: SheetMode?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(item: $activeSheet) { mode in
            RawTextSheet(title: mode.title, actionLabel: mode.actionLabel) { text in
                switch mode {
                case .importNode:
                    model.importRawText(text)
                case .applyPatch:
                    model.applyPatch(raw: text)
                }
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            ),
            actions: {
                Button("好", role: .cancel) {
                    model.clearError()
                }
            },
            message: {
                Text(model.errorMessage ?? "")
            }
        )
        .alert(
            "提示",
            isPresented: Binding(
                get: { model.infoMessage != nil },
                set: { if !$0 { model.clearInfo() } }
            ),
            actions: {
                Button("知道了", role: .cancel) {
                    model.clearInfo()
                }
            },
            message: {
                Text(model.infoMessage ?? "")
            }
        )
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedNodeID },
                set: { newValue in
                    if let newValue {
                        model.selectNode(newValue)
                    }
                }
            )) {
                Section("节点") {
                    ForEach(model.drafts) { draft in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.node.name.isEmpty ? "\(draft.node.address):\(draft.node.port)" : draft.node.name)
                                .font(.headline)
                            Text("\(draft.node.address):\(draft.node.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(draft.routingPreset.label) · \(draft.runtimeMode.label)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(draft.id)
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    activeSheet = .importNode
                } label: {
                    Label("粘贴文本导入", systemImage: "square.and.arrow.down")
                }

                Button {
                    model.importFromClipboard()
                } label: {
                    Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                }

                Button {
                    activeSheet = .applyPatch
                } label: {
                    Label("粘贴 patch", systemImage: "arrow.triangle.merge")
                }
                .disabled(model.selectedDraft == nil)

                Button {
                    model.applyPatchFromClipboard()
                } label: {
                    Label("剪贴板 patch", systemImage: "arrow.triangle.branch")
                }
                .disabled(model.selectedDraft == nil)

                Divider()

                Button(role: .destructive) {
                    model.deleteSelectedNode()
                } label: {
                    Label("删除当前节点", systemImage: "trash")
                }
                .disabled(model.selectedDraft == nil)
            }
            .padding()
        }
        .navigationTitle("Xray Native")
    }

    @ViewBuilder
    private var detail: some View {
        if let draft = model.selectedDraft {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.selectedNodeTitle)
                            .font(.largeTitle.weight(.bold))
                        Text("\(draft.node.address):\(draft.node.port)")
                            .foregroundStyle(.secondary)
                        Text(model.runtimeModeDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusCard
                }

                HStack(spacing: 12) {
                    Button {
                        model.startRuntime()
                    } label: {
                        Label("连接", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)

                    Button {
                        model.stopRuntime()
                    } label: {
                        Label("停止", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!["starting", "running", "running-dry"].contains(model.status))

                    Button {
                        model.updateGeodata()
                    } label: {
                        Label("更新 geodata", systemImage: "arrow.down.circle")
                    }

                    Spacer()
                }

                HStack(alignment: .top, spacing: 16) {
                    GroupBox("路由与模式") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(
                                "分流策略",
                                selection: Binding(
                                    get: { model.selectedDraft?.routingPreset ?? .cnDirect },
                                    set: { model.updateSelectedRoutingPreset($0) }
                                )
                            ) {
                                ForEach(RoutingPreset.allCases) { preset in
                                    Text(preset.label).tag(preset)
                                }
                            }

                            Picker(
                                "运行模式",
                                selection: Binding(
                                    get: { model.selectedDraft?.runtimeMode ?? .localProxy },
                                    set: { model.updateSelectedRuntimeMode($0) }
                                )
                            ) {
                                ForEach(RuntimeMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .disabled(true)

                            Text("当前原生 macOS 版本先固定为本地代理模式，未来 iOS 宿主再接 VPN/TUN。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("实时流量") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("上传", value: model.formatRate(model.trafficSnapshot.uploadBytesPerSecond))
                            LabeledContent("下载", value: model.formatRate(model.trafficSnapshot.downloadBytesPerSecond))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                TabView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            GroupBox("节点详情") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(model.summaryRows(for: draft.node), id: \.0) { item in
                                        LabeledContent(item.0, value: item.1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .tabItem {
                        Label("节点", systemImage: "server.rack")
                    }

                    ScrollView {
                        Text(model.configPreview.isEmpty ? "选择节点后查看生成的 Xray JSON。" : model.configPreview)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .tabItem {
                        Label("配置", systemImage: "curlybraces")
                    }

                    List(model.logs, id: \.self) { line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .tabItem {
                        Label("日志", systemImage: "doc.text")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
            .background(
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(nsColor: .underPageBackgroundColor),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            ContentUnavailableView(
                "还没有选中的节点",
                systemImage: "server.rack",
                description: Text("先从剪贴板或粘贴文本导入一个 `vless://` 链接，或者导入 `client_outbound.json`。")
            )
        }
    }

    private var statusCard: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(model.statusLabel)
                .font(.headline)
            Text("↑ \(model.formatRate(model.trafficSnapshot.uploadBytesPerSecond))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("↓ \(model.formatRate(model.trafficSnapshot.downloadBytesPerSecond))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RawTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actionLabel: String
    let onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.bold))
            Text("支持 `vless://`、`client_outbound.json`，或者现有节点的 split patch JSON。")
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button(actionLabel) {
                    onSubmit(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 760, height: 500)
    }
}
