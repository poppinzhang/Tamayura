import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var desktopStatusItem: DesktopStatusItem?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let mainFlutterWindow {
      desktopStatusItem = DesktopStatusItem(window: mainFlutterWindow)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    desktopStatusItem?.showWindow()
    return false
  }

  override func applicationDidBecomeActive(_ notification: Notification) {
    // Cmd+Tab can activate the app without a Dock/Finder reopen event.
    if let mainFlutterWindow, !mainFlutterWindow.isVisible {
      desktopStatusItem?.showWindow()
    }
  }

  override func applicationWillTerminate(_ notification: Notification) {
    desktopStatusItem?.removeStatusItem()
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
