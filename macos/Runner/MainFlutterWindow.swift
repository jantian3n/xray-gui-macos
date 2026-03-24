import Cocoa
import SwiftUI

final class MainAppWindow: NSWindow {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    configureWindow()
  }

  private func configureWindow() {
    let nativeRootView = NativeRootView()
      .environmentObject(NativeAppState.shared)
    let hostingController = NSHostingController(rootView: nativeRootView)
    contentViewController = hostingController
    title = "Xray GUI macOS"
    minSize = NSSize(width: 960, height: 640)
    titlebarAppearsTransparent = false
    toolbarStyle = .unified
    isReleasedWhenClosed = false
  }
}
