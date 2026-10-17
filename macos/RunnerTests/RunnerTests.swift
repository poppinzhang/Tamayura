import Cocoa
import FlutterMacOS
import XCTest
@testable import Tamayura

final class RunnerTests: XCTestCase {
  @MainActor
  func testApplicationActivationRestoresTheHiddenFlutterWindow() throws {
    let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
    let window = try XCTUnwrap(appDelegate.mainFlutterWindow)
    let flutterViewController = try XCTUnwrap(window.contentViewController as? FlutterViewController)
    window.performClose(nil)
    XCTAssertFalse(window.isVisible)

    appDelegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification, object: NSApp))
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.contentViewController === flutterViewController)
  }

  @MainActor
  func testCloseAndDockReopenKeepTheSameFlutterSession() throws {
    let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
    let window = try XCTUnwrap(appDelegate.mainFlutterWindow)
    let flutterViewController = try XCTUnwrap(window.contentViewController as? FlutterViewController)
    XCTAssertTrue(window.delegate is DesktopStatusItem)
    XCTAssertFalse(appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

    window.performClose(nil)
    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(window.contentViewController === flutterViewController)

    XCTAssertFalse(appDelegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.contentViewController === flutterViewController)
  }

  func testHostDeclaresSupportedSystemAndPermissions() {
    let info = Bundle(for: MainFlutterWindow.self).infoDictionary!
    XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "15.0")
    XCTAssertEqual(info["NSBonjourServices"] as? [String], ["_tamayura._tcp"])
    XCTAssertNotNil(info["NSLocalNetworkUsageDescription"])
    XCTAssertNotNil(info["NSCameraUsageDescription"])
  }

  func testPeerPathsCannotEscapeTheirSharedRoot() throws {
    XCTAssertThrowsError(try StoragePaths.components("../private.jpg"))
    XCTAssertThrowsError(try StoragePaths.components("/private.jpg"))
    XCTAssertThrowsError(try StoragePaths.components("C:private.jpg"))
    XCTAssertEqual(try StoragePaths.components("旅行/IMG 12:30.jpg"), ["旅行", "IMG 12:30.jpg"])
  }

  func testSiblingDirectoriesDoNotOverlap() {
    let root = URL(fileURLWithPath: "/Users/test/Pictures")
    XCTAssertTrue(StoragePaths.overlap(root, root.appendingPathComponent("Trip")))
    XCTAssertFalse(StoragePaths.overlap(root, URL(fileURLWithPath: "/Users/test/Pictures-other")))
  }
}
