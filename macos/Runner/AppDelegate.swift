import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var mainWindow: MainAppWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NativeAppState.shared.bootstrap()
    installMainMenu()

    let window = MainAppWindow()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    mainWindow = window
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    return true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func installMainMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu(title: "Application")
    appMenu.addItem(
      withTitle: "关于 Xray GUI macOS",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "退出 Xray GUI macOS",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu

    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "最小化",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    windowMenu.addItem(
      withTitle: "缩放",
      action: #selector(NSWindow.performZoom(_:)),
      keyEquivalent: ""
    )
    windowMenuItem.submenu = windowMenu

    NSApp.mainMenu = mainMenu
    NSApp.windowsMenu = windowMenu
  }
}
