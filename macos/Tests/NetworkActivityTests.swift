import Foundation

private struct TestFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw TestFailure(message: message) }
}

private final class ActivityRecorder {
  var options: [ProcessInfo.ActivityOptions] = []
  var started: [NSObject] = []
  var ended: [NSObjectProtocol] = []

  func makeActivity() -> NetworkActivity {
    NetworkActivity(begin: { options, reason in
      precondition(!reason.isEmpty)
      self.options.append(options)
      let token = NSObject()
      self.started.append(token)
      return token
    }, end: { self.ended.append($0) })
  }
}

@main
struct NetworkActivityTests {
  static func main() throws {
    var passed = 0
    func test(_ name: String, _ body: () throws -> Void) throws {
      try body(); passed += 1; print("PASS \(name)")
    }

    try test("inactive app has no assertion; sharing protects App Nap without preventing sleep") {
      let recorder = ActivityRecorder(), activity = recorder.makeActivity()
      try expect(recorder.started.isEmpty, "Idle app should be eligible for App Nap")
      activity.setSharingActive(true)
      activity.setSharingActive(true)
      try expect(recorder.started.count == 1, "Repeated discovery start must not leak assertions")
      try expect(recorder.options == [.userInitiatedAllowingIdleSystemSleep], "Wrong activity policy")
      try expect(!recorder.options[0].contains(.idleSystemSleepDisabled), "Must allow system idle sleep")
      try expect(!recorder.options[0].contains(.idleDisplaySleepDisabled), "Must allow display sleep")
      activity.setSharingActive(false)
      activity.setSharingActive(false)
      try expect(recorder.ended.count == 1, "Sharing stop must release exactly once")
      try expect(recorder.ended[0] === recorder.started[0], "Must end the exact acquired token")
      activity.setSharingActive(true)
      try expect(recorder.started.count == 2, "Sharing restart must reacquire")
      activity.stop()
    }

    try test("downloads remain protected when sharing stops and concurrent tasks finish") {
      let recorder = ActivityRecorder(), activity = recorder.makeActivity()
      activity.setSharingActive(true)
      activity.setTransferActive("first", active: true)
      activity.setTransferActive("second", active: true)
      activity.setTransferActive("first", active: true)
      activity.setSharingActive(false)
      activity.setTransferActive("first", active: false)
      activity.setTransferActive("first", active: false)
      activity.setTransferActive("unknown", active: false)
      try expect(recorder.started.count == 1 && recorder.ended.isEmpty, "Another task still needs protection")
      activity.setTransferActive("second", active: false)
      try expect(recorder.ended.count == 1, "Final task must release protection")
    }

    try test("sharing remains protected after the final download ends") {
      let recorder = ActivityRecorder(), activity = recorder.makeActivity()
      activity.setTransferActive("sharing", active: true)
      activity.setSharingActive(true)
      activity.setTransferActive("sharing", active: false)
      try expect(recorder.ended.isEmpty, "Task IDs must not collide with sharing ownership")
      activity.setSharingActive(false)
      try expect(recorder.ended.count == 1, "Sharing should now release")
    }

    try test("stop clears all ownership and permits a fresh activity") {
      let recorder = ActivityRecorder(), activity = recorder.makeActivity()
      activity.setSharingActive(true)
      activity.setTransferActive("task", active: true)
      activity.stop()
      activity.stop()
      try expect(recorder.ended.count == 1, "Stop must be idempotent")
      activity.setTransferActive("new-task", active: true)
      activity.setTransferActive("new-task", active: false)
      try expect(recorder.started.count == 2 && recorder.ended.count == 2, "Stop left stale owners")
    }

    try test("platform teardown releases the activity") {
      let recorder = ActivityRecorder()
      var activity: NetworkActivity? = recorder.makeActivity()
      activity!.setTransferActive("task", active: true)
      activity = nil
      try expect(recorder.ended.count == 1, "Deinit leaked the activity")
    }

    try test("real ProcessInfo accepts the activity and release policy") {
      let activity = NetworkActivity()
      activity.setSharingActive(true)
      activity.setTransferActive("task", active: true)
      activity.setSharingActive(false)
      activity.setTransferActive("task", active: false)
    }
    print("PASS \(passed) macOS network activity tests")
  }
}
