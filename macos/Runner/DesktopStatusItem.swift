import Cocoa

/// The window operations needed to keep the existing Flutter session alive.
@MainActor
protocol ResidentDesktopWindow: AnyObject {
  var isMiniaturized: Bool { get }
  var isFullScreen: Bool { get }
  func orderOut(_ sender: Any?)
  func deminiaturize(_ sender: Any?)
  func makeKeyAndOrderFront(_ sender: Any?)
  func toggleFullScreen(_ sender: Any?)
}

extension NSWindow: ResidentDesktopWindow {
  var isFullScreen: Bool { styleMask.contains(.fullScreen) }
}

@MainActor
final class DesktopWindowResidence {
  // FlutterAppDelegate's mainFlutterWindow outlet is weak. Keep this window,
  // its view controller and its engine alive even when it is ordered out.
  private let window: ResidentDesktopWindow
  private let activate: () -> Void
  private var hideAfterFullScreenExit = false

  init(window: ResidentDesktopWindow, activate: @escaping () -> Void) {
    self.window = window
    self.activate = activate
  }

  func hideWindow() {
    if window.isFullScreen {
      // Ordering a full-screen window out immediately can leave an empty Space.
      // Wait for AppKit to return it to the desktop before hiding it.
      if !hideAfterFullScreenExit {
        hideAfterFullScreenExit = true
        window.toggleFullScreen(nil)
      }
    } else {
      hideAfterFullScreenExit = false
      window.orderOut(nil)
    }
  }

  func showWindow() {
    // Reopening during the full-screen transition cancels the pending hide.
    hideAfterFullScreenExit = false
    activate()
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  func didExitFullScreen() {
    if hideAfterFullScreenExit {
      hideAfterFullScreenExit = false
      window.orderOut(nil)
    }
  }

  func didFailToExitFullScreen() {
    // AppKit can reject a transition during another gesture/animation. Keep
    // the window visible and let the user retry closing it after that gesture.
    hideAfterFullScreenExit = false
  }
}

@MainActor
final class DesktopStatusItem: NSObject, NSWindowDelegate {
  private let residence: DesktopWindowResidence
  private var statusItem: NSStatusItem?

  init(window: NSWindow) {
    residence = DesktopWindowResidence(window: window) {
      NSApp.activate(ignoringOtherApps: true)
    }
    super.init()
    window.isReleasedWhenClosed = false
    window.delegate = self

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "玉响")
    image?.isTemplate = true
    item.button?.image = image
    if image == nil { item.button?.title = "玉" }
    item.button?.toolTip = "玉响 · 关闭窗口后继续在后台运行"
    item.button?.setAccessibilityLabel("玉响")

    let menu = NSMenu()
    let openItem = NSMenuItem(title: "打开玉响", action: #selector(showWindow), keyEquivalent: "")
    openItem.target = self
    menu.addItem(openItem)
    menu.addItem(.separator())
    // Use the standard application termination path, as the main menu/Cmd+Q
    // already do. Window close interception does not intercept termination.
    let quitItem = NSMenuItem(title: "退出玉响", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quitItem.target = NSApp
    menu.addItem(quitItem)
    item.menu = menu
    statusItem = item
  }

  @objc func showWindow() { residence.showWindow() }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    residence.hideWindow()
    return false
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    residence.didExitFullScreen()
  }

  func windowDidFailToExitFullScreen(_ window: NSWindow) {
    residence.didFailToExitFullScreen()
  }

  func removeStatusItem() {
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }
}
