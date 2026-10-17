import Cocoa

private struct TestFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw TestFailure(message: message) }
}

@MainActor
private final class TestWindow: ResidentDesktopWindow {
  var isMiniaturized = false
  var isFullScreen = false
  var visible = true
  var events: [String] = []

  func orderOut(_ sender: Any?) { events.append("hide"); visible = false }
  func deminiaturize(_ sender: Any?) { events.append("restore"); isMiniaturized = false }
  func makeKeyAndOrderFront(_ sender: Any?) { events.append("show"); visible = true }
  func toggleFullScreen(_ sender: Any?) { events.append("exitFullScreen") }

  func residence() -> DesktopWindowResidence {
    DesktopWindowResidence(window: self) { self.events.append("activate") }
  }
}

@main
struct DesktopStatusItemTests {
  @MainActor
  static func main() throws {
    var passed = 0
    func test(_ name: String, _ body: () throws -> Void) throws {
      try body(); passed += 1; print("PASS \(name)")
    }

    try test("closing hides the existing window and reopening restores it") {
      let window = TestWindow(), residence = window.residence()
      residence.hideWindow()
      try expect(!window.visible, "Closing should hide the window")
      residence.showWindow()
      try expect(window.visible, "Reopening should show the same window")
      try expect(window.events == ["hide", "activate", "show"], "Unexpected close/reopen sequence")
      residence.hideWindow()
      residence.showWindow()
      try expect(window.visible && window.events.count == 6, "Repeated close/reopen must work")
    }

    try test("resident controller retains the hidden window and its session") {
      weak var retainedWindow: TestWindow?
      var residence: DesktopWindowResidence?
      do {
        let window = TestWindow()
        retainedWindow = window
        // Avoid a captured reference in activate, so retention is exercised
        // through the residence's actual window ownership.
        residence = DesktopWindowResidence(window: window, activate: {})
        residence!.hideWindow()
      }
      try expect(retainedWindow != nil, "Hidden window was released")
      residence!.showWindow()
      try expect(retainedWindow?.visible == true, "Retained window cannot reopen")
      residence = nil
      try expect(retainedWindow == nil, "Residence should not create a retain cycle")
    }

    try test("reopen restores a minimized window before bringing it forward") {
      let window = TestWindow(), residence = window.residence()
      window.isMiniaturized = true
      residence.showWindow()
      try expect(window.events == ["activate", "restore", "show"], "Minimized window restoration order")
      try expect(!window.isMiniaturized && window.visible, "Minimized window not restored")
    }

    try test("full-screen close exits its Space before hiding and avoids repeated toggles") {
      let window = TestWindow(), residence = window.residence()
      window.isFullScreen = true
      residence.hideWindow()
      residence.hideWindow()
      try expect(window.events == ["exitFullScreen"] && window.visible, "Must wait for full-screen exit")
      window.isFullScreen = false
      residence.didExitFullScreen()
      residence.didExitFullScreen()
      try expect(window.events == ["exitFullScreen", "hide"] && !window.visible, "Hide exactly once after exit")
    }

    try test("reopening while leaving full-screen cancels the pending hide") {
      let window = TestWindow(), residence = window.residence()
      window.isFullScreen = true
      residence.hideWindow()
      residence.showWindow()
      window.isFullScreen = false
      residence.didExitFullScreen()
      try expect(window.visible, "Late full-screen notification hid the reopened window")
      try expect(window.events == ["exitFullScreen", "activate", "show"], "Unexpected deferred hide")
    }

    try test("failed full-screen exit leaves a usable window and permits a close retry") {
      let window = TestWindow(), residence = window.residence()
      window.isFullScreen = true
      residence.hideWindow()
      residence.didFailToExitFullScreen()
      residence.didExitFullScreen()
      try expect(window.visible, "A failed transition should not hide the window")
      residence.hideWindow()
      try expect(window.events == ["exitFullScreen", "exitFullScreen"], "Failed transition prevented a retry")
      window.isFullScreen = false
      residence.didExitFullScreen()
      try expect(!window.visible, "Successful retry did not hide the window")
    }

    try test("leaving full-screen without closing keeps the window visible") {
      let window = TestWindow(), residence = window.residence()
      residence.didExitFullScreen()
      try expect(window.visible && window.events.isEmpty, "Normal full-screen exit must not hide")
    }
    print("PASS \(passed) macOS desktop residence tests")
  }
}
