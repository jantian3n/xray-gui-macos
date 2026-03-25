import AppKit
import SwiftUI

@main
struct XrayNativeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Xray GUI", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1120, minHeight: 760)
                .task {
                    model.load()
                }
        }
        .defaultSize(width: 1220, height: 820)

        MenuBarExtra(model.menuBarTitle, systemImage: "bolt.horizontal.circle") {
            MenuBarContent(model: model)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("打开控制台") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Divider()

            Text("状态: \(model.statusLabel)")
            Text("节点: \(model.selectedNodeTitle)")
            Text("上传: \(model.formatRate(model.trafficSnapshot.uploadBytesPerSecond))")
            Text("下载: \(model.formatRate(model.trafficSnapshot.downloadBytesPerSecond))")

            if !model.drafts.isEmpty {
                Divider()
                Text("切换节点")
                    .font(.headline)

                ForEach(model.drafts) { draft in
                    Button {
                        model.selectNode(draft.id)
                        openWindow(id: "main")
                    } label: {
                        HStack {
                            Text(draft.node.name.isEmpty ? "\(draft.node.address):\(draft.node.port)" : draft.node.name)
                            Spacer()
                            if draft.id == model.selectedNodeID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(model.isRuntimeLocked && draft.id != model.selectedNodeID)
                }
            }

            Divider()

            Button("退出软件") {
                model.quitApp()
            }
        }
        .padding(10)
        .frame(minWidth: 280)
    }
}
