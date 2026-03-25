import SwiftUI

struct NativeRootView: View {
  @EnvironmentObject private var appState: NativeAppState

  private let connectionColumns = [
    GridItem(.flexible(minimum: 280), spacing: 16),
    GridItem(.flexible(minimum: 280), spacing: 16),
  ]

  private let overviewColumns = [
    GridItem(.flexible(minimum: 180), spacing: 16),
    GridItem(.flexible(minimum: 180), spacing: 16),
    GridItem(.flexible(minimum: 180), spacing: 16),
    GridItem(.flexible(minimum: 180), spacing: 16),
  ]

  var body: some View {
    TabView {
      connectionTab
        .tabItem {
          Label("连接", systemImage: "bolt.horizontal.circle")
        }

      nodesTab
        .tabItem {
          Label("节点", systemImage: "point.3.connected.trianglepath.dotted")
        }

      diagnosticsTab
        .tabItem {
          Label("诊断", systemImage: "waveform.path.ecg.rectangle")
        }
    }
    .frame(minWidth: 1100, minHeight: 720)
  }

  private var connectionTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        heroCard

        if let errorMessage = appState.lastErrorMessage {
          errorBanner(message: errorMessage)
        }

        LazyVGrid(columns: overviewColumns, spacing: 16) {
          metricCard(
            title: "连接模式",
            value: appState.selectedRuntimeMode.label,
            detail: appState.primaryConnectionDetail,
            tint: Color(red: 0.12, green: 0.45, blue: 0.71)
          )
          metricCard(
            title: "当前状态",
            value: appState.primaryConnectionStatusLabel,
            detail: statusDetailText,
            tint: statusTint
          )
          metricCard(
            title: "当前节点",
            value: appState.importedNode?.name ?? "未导入",
            detail: appState.importedNode.map { "\($0.address):\($0.port)" } ?? "导入节点后即可连接",
            tint: Color(red: 0.12, green: 0.56, blue: 0.38)
          )
          metricCard(
            title: "Xray 内核",
            value: appState.runtimeAssetStatus?.currentXrayVersionLabel ?? "读取中",
            detail: appState.runtimeAssetStatus?.currentXraySourceLabel ?? "正在检查资源来源",
            tint: Color(red: 0.77, green: 0.35, blue: 0.14)
          )
        }

        LazyVGrid(columns: connectionColumns, spacing: 16) {
          connectionControlCard
          runtimeAssetCard
          runtimeStatusCard
          vpnStatusCard
        }
      }
      .padding(24)
    }
  }

  private var nodesTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        sectionCard(title: "导入与编辑", eyebrow: "Nodes") {
          VStack(alignment: .leading, spacing: 14) {
            Text("支持直接粘贴 `vless://` 链接或 `client_outbound.json`。")
              .foregroundStyle(.secondary)

            TextEditor(text: $appState.importText)
              .font(.system(.body, design: .monospaced))
              .frame(minHeight: 220)
              .padding(12)
              .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                  .fill(Color(nsColor: .textBackgroundColor))
              )
              .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                  .stroke(Color.primary.opacity(0.08), lineWidth: 1)
              )

            HStack(spacing: 12) {
              Button("恢复示例") {
                appState.resetToSample()
              }

              Button("导入并生成配置") {
                appState.importCurrentText()
              }
              .buttonStyle(.borderedProminent)

              Button("保存当前节点") {
                appState.saveCurrentNode()
              }
              .disabled(appState.importedNode == nil)
            }
          }
        }

        LazyVGrid(columns: connectionColumns, spacing: 16) {
          sectionCard(title: "已保存节点", eyebrow: "Library") {
            if appState.savedNodes.isEmpty {
              placeholderText("还没有保存的节点。")
            } else {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(appState.savedNodes) { draft in
                  HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                      HStack(spacing: 8) {
                        Text(draft.title)
                          .font(.headline)
                        if appState.selectedSavedNodeID == draft.id {
                          capsuleLabel("当前", tint: Color.accentColor)
                        }
                      }
                      Text("\(draft.node.address):\(draft.node.port)")
                      Text("\(draft.routingPreset.label) / \(draft.runtimeMode.label)")
                        .foregroundStyle(.secondary)
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
                  .padding(.vertical, 4)
                }
              }
            }
          }

          sectionCard(title: "节点预览", eyebrow: "Preview") {
            if let node = appState.importedNode {
              infoLine("名称", value: node.name, systemImage: "tag")
              infoLine("服务器", value: "\(node.address):\(node.port)", systemImage: "server.rack")
              infoLine(
                "传输",
                value: "\(node.network.uppercased()) / \(node.security.uppercased())",
                systemImage: "network"
              )
              if !node.serverName.isEmpty {
                infoLine("SNI", value: node.serverName, systemImage: "globe")
              }
              if !node.path.isEmpty {
                infoLine("路径", value: node.path, systemImage: "point.3.connected.trianglepath.dotted")
              }
            } else {
              placeholderText("导入节点后会在这里显示关键信息。")
            }
          }
        }
      }
      .padding(24)
    }
  }

  private var diagnosticsTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        sectionCard(title: "诊断信息", eyebrow: "Diagnostics") {
          VStack(alignment: .leading, spacing: 10) {
            infoLine("最近刷新", value: appState.lastUpdated.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
            infoLine("Provider Bundle", value: appState.packetTunnelProviderBundleIdentifier.isEmpty ? "未配置" : appState.packetTunnelProviderBundleIdentifier, systemImage: "shippingbox")
            if !appState.runtimeBinaryPath.isEmpty {
              infoLine("Xray 路径", value: appState.runtimeBinaryPath, systemImage: "terminal")
            }
            if !appState.runtimeGeodataPath.isEmpty {
              infoLine("GeoData 路径", value: appState.runtimeGeodataPath, systemImage: "tray.full")
            }
          }
        }

        if !appState.compiledConfigPreview.isEmpty {
          sectionCard(title: "Xray 配置预览", eyebrow: "Config") {
            ScrollView(.horizontal) {
              Text(appState.compiledConfigPreview)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 320)
          }
        }

        sectionCard(title: "运行日志", eyebrow: "Logs") {
          if appState.runtimeLogText.isEmpty {
            placeholderText("连接、更新或导入节点后，运行日志会显示在这里。")
          } else {
            ScrollView(.horizontal) {
              Text(appState.runtimeLogText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)
          }
        }
      }
      .padding(24)
    }
  }

  private var heroCard: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Xray GUI")
          .font(.system(size: 34, weight: .bold, design: .rounded))
        Text("macOS 连接工作台")
          .font(.title3.weight(.semibold))
          .foregroundStyle(Color.white.opacity(0.9))
        Text(appState.statusSummary)
          .font(.body)
          .foregroundStyle(Color.white.opacity(0.86))
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 10) {
        capsuleLabel(appState.selectedRuntimeMode.label, tint: Color.white)
        capsuleLabel("状态 \(appState.primaryConnectionStatusLabel)", tint: Color.white.opacity(0.9))
        Text(appState.lastUpdated.formatted(date: .abbreviated, time: .shortened))
          .font(.caption.monospacedDigit())
          .foregroundStyle(Color.white.opacity(0.75))
      }
    }
    .padding(26)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.05, green: 0.26, blue: 0.47),
          Color(red: 0.11, green: 0.48, blue: 0.42),
          Color(red: 0.77, green: 0.42, blue: 0.20),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
  }

  private var connectionControlCard: some View {
    sectionCard(title: "连接控制", eyebrow: "Connection") {
      VStack(alignment: .leading, spacing: 14) {
        Picker("路由策略", selection: $appState.selectedRoutingPreset) {
          ForEach(NativeRoutingPreset.allCases) { preset in
            Text(preset.label).tag(preset)
          }
        }
        .pickerStyle(.menu)

        Text(appState.selectedRoutingPreset.description)
          .foregroundStyle(.secondary)

        Picker("连接模式", selection: $appState.selectedRuntimeMode) {
          ForEach(NativeRuntimeMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Text(appState.primaryConnectionDetail)
          .foregroundStyle(.secondary)

        HStack(spacing: 12) {
          if appState.selectedRuntimeMode == .vpn {
            Button("更新 VPN 配置") {
              appState.installPacketTunnelConfiguration()
            }
            .disabled(!appState.canInstallPacketTunnel)
          }

          Button(startButtonTitle) {
            appState.startSelectedConnection()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!appState.canStartSelectedConnection)

          Button(stopButtonTitle) {
            appState.stopSelectedConnection()
          }
          .disabled(!appState.canStopSelectedConnection)
        }
      }
    }
  }

  private var runtimeAssetCard: some View {
    sectionCard(title: "内核与 GeoData", eyebrow: "Runtime Assets") {
      VStack(alignment: .leading, spacing: 10) {
        infoLine("当前 Xray", value: appState.runtimeAssetStatus?.currentXrayVersionLabel ?? "读取中", systemImage: "cpu")
        infoLine("最新稳定", value: appState.runtimeAssetStatus?.latestXrayVersionLabel ?? "未获取", systemImage: "arrow.down.circle")
        infoLine("GeoData", value: appState.runtimeAssetStatus?.installedGeodataReleaseLabel ?? "读取中", systemImage: "globe.asia.australia")
        infoLine("GeoData 最新", value: appState.runtimeAssetStatus?.latestGeodataReleaseLabel ?? "未获取", systemImage: "arrow.clockwise.circle")

        if appState.isRuntimeAssetActionInFlight {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text(appState.runtimeAssetActivityLabel)
              .font(.caption)
          }
        }

        HStack(spacing: 12) {
          Button("刷新") {
            appState.refreshRuntimeAssets()
          }
          .disabled(!appState.canManageRuntimeAssets)

          Button("更新内核") {
            appState.updateXrayCore()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!appState.canManageRuntimeAssets)

          Button("更新 GeoData") {
            appState.updateGeodata()
          }
          .disabled(!appState.canManageRuntimeAssets)
        }
      }
    }
  }

  private var runtimeStatusCard: some View {
    sectionCard(title: "本地运行时", eyebrow: "Runtime") {
      VStack(alignment: .leading, spacing: 10) {
        infoLine("运行状态", value: appState.runtimeState.label, systemImage: "bolt.horizontal.circle")
        if !appState.runtimeBinaryPath.isEmpty {
          infoLine("Xray 路径", value: appState.runtimeBinaryPath, systemImage: "terminal")
        }
        if !appState.runtimeGeodataPath.isEmpty {
          infoLine("GeoData 路径", value: appState.runtimeGeodataPath, systemImage: "tray.full")
        }
        Text("系统代理和 VPN 模式都会复用同一套本地 Xray 运行时资源。")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var vpnStatusCard: some View {
    sectionCard(title: "VPN 托管状态", eyebrow: "NetworkExtension") {
      VStack(alignment: .leading, spacing: 10) {
        infoLine("VPN 状态", value: appState.packetTunnelStatus.label, systemImage: "shield.checkered")
        infoLine("Provider", value: appState.packetTunnelProviderBundleIdentifier.isEmpty ? "未配置" : appState.packetTunnelProviderBundleIdentifier, systemImage: "shippingbox")
        Text("VPN 模式会先启动本地 Xray，再由 Packet Tunnel 通过系统 VPN 配置接管 HTTP / HTTPS 代理。")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var statusTint: Color {
    let label = appState.primaryConnectionStatusLabel
    if label == NativeRuntimeState.running.label || label == NativePacketTunnelStatus.connected.label {
      return Color(red: 0.12, green: 0.56, blue: 0.38)
    }
    if label == NativeRuntimeState.error.label
      || label == NativePacketTunnelStatus.failed.label
      || label == NativePacketTunnelStatus.invalid.label {
      return Color.red
    }
    return Color(red: 0.86, green: 0.52, blue: 0.12)
  }

  private var statusDetailText: String {
    if appState.selectedRuntimeMode == .vpn {
      return "本地 Xray \(appState.runtimeState.label) / VPN \(appState.packetTunnelStatus.label)"
    }
    return appState.primaryConnectionDetail
  }

  private var startButtonTitle: String {
    switch appState.selectedRuntimeMode {
    case .vpn:
      return "连接 VPN"
    case .systemProxy:
      return "连接系统代理"
    case .localProxy:
      return "启动本地代理"
    }
  }

  private var stopButtonTitle: String {
    appState.selectedRuntimeMode == .vpn ? "断开 VPN" : "停止连接"
  }

  private func sectionCard<Content: View>(
    title: String,
    eyebrow: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(eyebrow.uppercased())
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(title)
          .font(.title3.weight(.semibold))
      }

      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(22)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private func metricCard(
    title: String,
    value: String,
    detail: String,
    tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 24, weight: .bold, design: .rounded))
        .foregroundStyle(tint)
        .lineLimit(2)
      Text(detail)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
    .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private func infoLine(_ title: String, value: String, systemImage: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(value)
          .textSelection(.enabled)
      }
    }
  }

  private func placeholderText(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func capsuleLabel(_ text: String, tint: Color) -> some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(tint.opacity(0.14))
      .foregroundStyle(tint)
      .clipShape(Capsule())
  }

  private func errorBanner(message: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 6) {
        Text("最近错误")
          .font(.headline)
          .foregroundStyle(.red)
        Text(message)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.red.opacity(0.08))
    )
  }
}
