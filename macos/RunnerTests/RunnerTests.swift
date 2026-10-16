import Cocoa
import FlutterMacOS
import XCTest
@testable import Tamayura

final class RunnerTests: XCTestCase {
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
