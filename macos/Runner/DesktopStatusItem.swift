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
  private var openItem: NSMenuItem?
  private var quitItem: NSMenuItem?
  private var languageObserver: NSObjectProtocol?

  init(window: NSWindow) {
    residence = DesktopWindowResidence(window: window) {
      NSApp.activate(ignoringOtherApps: true)
    }
    super.init()
    window.isReleasedWhenClosed = false
    window.delegate = self

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: nil)
    image?.isTemplate = true
    item.button?.image = image

    let menu = NSMenu()
    let openItem = NSMenuItem(title: "", action: #selector(showWindow), keyEquivalent: "")
    openItem.target = self
    menu.addItem(openItem)
    menu.addItem(.separator())
    // Use the standard application termination path, as the main menu/Cmd+Q
    // already do. Window close interception does not intercept termination.
    let quitItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quitItem.target = NSApp
    menu.addItem(quitItem)
    item.menu = menu
    statusItem = item
    self.openItem = openItem
    self.quitItem = quitItem
    updateText()
    languageObserver = NotificationCenter.default.addObserver(
      forName: AppText.didChange, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.updateText() } }
  }

  /// Follow the interface language chosen in the app.
  func updateText() {
    guard let button = statusItem?.button else { return }
    if button.image == nil { button.title = AppText.text(.statusTitle) }
    button.toolTip = AppText.text(.statusTooltip)
    button.setAccessibilityLabel(AppText.text(.appName))
    openItem?.title = AppText.text(.openApp)
    quitItem?.title = AppText.text(.quitApp)
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
    if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    languageObserver = nil
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }
}
