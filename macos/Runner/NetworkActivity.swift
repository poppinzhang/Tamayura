import Foundation

/// Main-thread ownership of work that must remain responsive when the window
/// is obscured. This prevents App Nap, but deliberately allows system sleep.
final class NetworkActivity {
  private enum Owner: Hashable {
    case sharing
    case transfer(String)
  }

  private let begin: (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
  private let end: (NSObjectProtocol) -> Void
  private var owners = Set<Owner>()
  private var token: NSObjectProtocol?

  init(
    begin: @escaping (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol = {
      ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
    },
    end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
  ) {
    self.begin = begin
    self.end = end
  }

  func setSharingActive(_ active: Bool) { set(.sharing, active: active) }

  func setTransferActive(_ taskID: String, active: Bool) {
    set(.transfer(taskID), active: active)
  }

  private func set(_ owner: Owner, active: Bool) {
    if active { owners.insert(owner) } else { owners.remove(owner) }
    if !owners.isEmpty && token == nil {
      token = begin(.userInitiatedAllowingIdleSystemSleep, "Tamayura LAN sharing and file transfers")
    } else if owners.isEmpty {
      stop()
    }
  }

  func stop() {
    owners.removeAll()
    if let token {
      self.token = nil
      end(token)
    }
  }

  deinit { stop() }
}
