import Cocoa

private struct TestFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw TestFailure(message: message) }
}

@MainActor
private func render(_ image: NSImage, pixels: Int) throws -> NSBitmapImageRep {
  guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    throw TestFailure(message: "Could not create icon bitmap")
  }
  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }
  NSGraphicsContext.current = context
  context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
  image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
  return bitmap
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

    try test("missing status artwork permits the accessible text fallback") {
      var requestedAsset: String?
      let image = DesktopStatusIcon.image {
        requestedAsset = $0
        return nil
      }
      try expect(requestedAsset == "StatusIcon", "Should load the dedicated macOS asset")
      try expect(image == nil, "Missing artwork should permit the existing accessible text fallback")
    }

    try test("status icon preserves the SVG cutout and rounded corners as an 18-point template") {
      guard CommandLine.arguments.count == 2 else {
        throw TestFailure(message: "Expected the asset catalog path")
      }
      let assets = URL(fileURLWithPath: CommandLine.arguments[1])
      let file = assets.appendingPathComponent("StatusIcon.imageset/hibiki-macos-cutout.svg")
      guard let source = NSImage(contentsOf: file),
            let icon = DesktopStatusIcon.image(load: { $0 == "StatusIcon" ? source : nil }) else {
        throw TestFailure(message: "Missing or invalid dedicated status icon SVG")
      }
      try expect(icon.size == NSSize(width: 18, height: 18) && icon.isTemplate,
                 "AppKit should tint the 18-point template for the menu-bar appearance")
      try expect(source.size == NSSize(width: 512, height: 512) && !source.isTemplate,
                 "Preparing the status icon must not mutate the shared source image")
      for pixels in [18, 36, 72] {
        let prepared = try render(icon, pixels: pixels)
        let original = try render(source, pixels: pixels)
        for (x, y) in [(0, 0), (0, pixels - 1), (pixels - 1, 0), (pixels - 1, pixels - 1)] {
          try expect(prepared.colorAt(x: x, y: y)!.alphaComponent < 0.05,
                     "Every supplied rounded corner should remain transparent")
        }
        try expect(prepared.colorAt(x: pixels / 2, y: 0)!.alphaComponent > 0.99,
                   "The rounded square must retain its opaque outer edge")
        // Compare the complete mask, including its outer edge. Any extra
        // clipping, padding or glyph raster replacement would change it.
        for y in 0..<pixels {
          for x in 0..<pixels {
            let actual = prepared.colorAt(x: x, y: y)!.alphaComponent
            let expected = original.colorAt(x: x, y: y)!.alphaComponent
            try expect(abs(actual - expected) < 0.01,
                       "Preparing the template changed the supplied SVG alpha mask")
          }
        }
      }
      // At source resolution, the interior must contain both opaque body and
      // fully transparent character pixels, not white text over a solid fill.
      let mask = try render(icon, pixels: 512)
      var transparent = 0, opaque = 0
      for y in 52..<460 {
        for x in 52..<460 {
          let alpha = mask.colorAt(x: x, y: y)!.alphaComponent
          if alpha < 0.01 { transparent += 1 }
          if alpha > 0.99 { opaque += 1 }
        }
      }
      try expect(transparent > 20000 && opaque > 50000,
                 "The dedicated icon must retain its genuinely transparent character cutout")
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
    print("PASS \(passed) macOS desktop status and residence tests")
  }
}
