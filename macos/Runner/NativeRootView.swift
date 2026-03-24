import SwiftUI

struct NativeRootView: View {
  @EnvironmentObject private var appState: NativeAppState

  var body: some View {
    TabView {
      overviewTab
        .tabItem {
          Label("概览", systemImage: "sparkles.rectangle.stack")
        }

      workspaceTab
        .tabItem {
          Label("工作台", systemImage: "hammer")
        }

      migrationTab
        .tabItem {
          Label("迁移", systemImage: "arrow.triangle.2.circlepath")
        }

      notesTab
        .tabItem {
          Label("说明", systemImage: "note.text")
        }
    }
    .frame(minWidth: 960, minHeight: 640)
  }

  private var overviewTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        headerCard(
          title: "Xray GUI macOS",
          subtitle: "原生 SwiftUI 重构已开始",
          body: appState.statusSummary
        )

        infoCard(title: "当前方向") {
          Label("完全改为 Swift / SwiftUI 原生 macOS 应用", systemImage: "swift")
          Label("后续用 Swift 接管运行时、系统代理和 NetworkExtension", systemImage: "network")
          Label("Flutter 逻辑将分阶段迁移，而不是长期混跑", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }

        infoCard(title: "本轮已经接管的能力") {
          Label("原生入口已经切到 SwiftUI / AppKit", systemImage: "checkmark.circle")
          Label("Swift 版已经能解析 `vless://` 和部分 JSON 导入", systemImage: "link.badge.plus")
          Label("Swift 版已经能保存节点、生成 Xray JSON，并启动原生运行时", systemImage: "doc.badge.gearshape")
        }

        infoCard(title: "离原生可用版还差什么") {
          Label("继续把订阅、节点编辑和配置管理完整迁到 Swift", systemImage: "shippingbox")
          Label("继续把 Packet Tunnel / NetworkExtension 切到原生实现", systemImage: "shield.lefthalf.filled")
          Label("补齐签名、权限和打包流程，就能更接近真正可分发的 .app", systemImage: "app.badge")
        }
      }
      .padding(24)
    }
  }

  private var workspaceTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        headerCard(
          title: "Swift 工作台",
          subtitle: "原生业务逻辑预览",
          body: "这里已经直接调用 Swift 版节点导入器、原生存储、xray 运行时和系统代理管理器，不再依赖 Flutter。"
        )

        infoCard(title: "导入输入") {
          Text("可以直接粘贴 `vless://` 或 `client_outbound.json`。")
            .foregroundStyle(.secondary)

          TextEditor(text: $appState.importText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 180)
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )

          HStack(spacing: 12) {
            Picker("路由策略", selection: $appState.selectedRoutingPreset) {
              ForEach(NativeRoutingPreset.allCases) { preset in
                Text(preset.label).tag(preset)
              }
            }
            .pickerStyle(.menu)

            Picker("运行模式", selection: $appState.selectedRuntimeMode) {
              ForEach(NativeRuntimeMode.allCases) { mode in
                Text(mode.label).tag(mode)
              }
            }
            .pickerStyle(.menu)

            Spacer()

            Button("恢复示例") {
              appState.resetToSample()
            }

            Button("保存当前节点") {
              appState.saveCurrentNode()
            }
            .disabled(appState.importedNode == nil)

            Button("导入并生成配置") {
              appState.importCurrentText()
            }
            .buttonStyle(.borderedProminent)
          }
        }

        infoCard(title: "运行控制") {
          HStack {
            Label("当前状态: \(appState.runtimeState.label)", systemImage: "bolt.horizontal.circle")
            Spacer()
            if appState.isRuntimeActionInFlight {
              ProgressView()
                .controlSize(.small)
            }
          }

          HStack(spacing: 12) {
            Button("启动运行时") {
              appState.startRuntime()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.canStartRuntime)

            Button("停止运行时") {
              appState.stopRuntime()
            }
            .disabled(!appState.canStopRuntime)
          }

          if !appState.runtimeBinaryPath.isEmpty {
            Label("xray: \(appState.runtimeBinaryPath)", systemImage: "terminal")
              .textSelection(.enabled)
          }

          if !appState.runtimeGeodataPath.isEmpty {
            Label("geodata: \(appState.runtimeGeodataPath)", systemImage: "tray.full")
              .textSelection(.enabled)
          }
        }

        if !appState.savedNodes.isEmpty {
          infoCard(title: "已保存节点") {
            ForEach(appState.savedNodes) { draft in
              HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                  HStack(spacing: 8) {
                    Text(draft.title)
                      .font(.headline)
                    if appState.selectedSavedNodeID == draft.id {
                      Text("当前")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                    }
                  }
                  Text("\(draft.node.address):\(draft.node.port)")
                  Text("\(draft.routingPreset.label) / \(draft.runtimeMode.label)")
                }

                Spacer()

                HStack(spacing: 8) {
                  Button("载入") {
                    appState.loadSavedNode(draft)
                  }
                  Button("删除") {
                    appState.deleteSavedNode(draft)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 6)
            }
          }
        }

        if let errorMessage = appState.lastErrorMessage {
          VStack(alignment: .leading, spacing: 8) {
            Label("最近错误", systemImage: "exclamationmark.triangle.fill")
              .font(.headline)
              .foregroundStyle(.red)
            Text(errorMessage)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
          .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .fill(Color.red.opacity(0.08))
          )
        }

        if let node = appState.importedNode {
          infoCard(title: "节点预览") {
            Label("名称: \(node.name)", systemImage: "tag")
            Label("服务器: \(node.address):\(node.port)", systemImage: "server.rack")
            Label("传输: \(node.network.uppercased()) / \(node.security.uppercased())", systemImage: "network")
            if !node.serverName.isEmpty {
              Label("SNI: \(node.serverName)", systemImage: "globe")
            }
            if !node.path.isEmpty {
              Label("路径: \(node.path)", systemImage: "point.3.connected.trianglepath.dotted")
            }
          }
        }

        if !appState.compiledConfigPreview.isEmpty {
          infoCard(title: "Xray JSON 预览") {
            ScrollView(.horizontal) {
              Text(appState.compiledConfigPreview)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 320)
          }
        }

        if !appState.runtimeLogText.isEmpty {
          infoCard(title: "运行日志") {
            ScrollView(.horizontal) {
              Text(appState.runtimeLogText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220)
          }
        }
      }
      .padding(24)
    }
  }

  private var migrationTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(appState.milestones) { milestone in
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              statusBadge(milestone.status)
              Text(milestone.title)
                .font(.title3.weight(.semibold))
            }

            Text(milestone.detail)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
          .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
        }
      }
      .padding(24)
    }
  }

  private var notesTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        headerCard(
          title: "迁移说明",
          subtitle: "为什么先起原生壳",
          body: "先把 App 真正变成纯 Swift 目标，后面的功能迁移才能稳定收口。"
        )

        infoCard(title: "迁移原则") {
          ForEach(appState.notes, id: \.self) { note in
            Label(note, systemImage: "chevron.right")
          }
        }

        HStack {
          Text("最近刷新")
            .foregroundStyle(.secondary)
          Spacer()
          Text(appState.lastUpdated.formatted(date: .abbreviated, time: .shortened))
            .monospacedDigit()
        }
        .padding(.horizontal, 4)
      }
      .padding(24)
    }
  }

  private func headerCard(title: String, subtitle: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(subtitle.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.system(size: 30, weight: .bold, design: .rounded))
      Text(body)
        .font(.body)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.93, green: 0.97, blue: 0.96),
          Color(red: 0.88, green: 0.94, blue: 0.98),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
  }

  private func infoCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(.title3.weight(.semibold))
      VStack(alignment: .leading, spacing: 12) {
        content()
      }
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private func statusBadge(_ status: NativeAppState.Milestone.Status) -> some View {
    let tint: Color = switch status {
    case .completed:
      Color.green
    case .inProgress:
      Color.orange
    case .pending:
      Color.secondary
    }

    return Text(status.label)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(tint.opacity(0.14))
      .foregroundStyle(tint)
      .clipShape(Capsule())
  }
}
