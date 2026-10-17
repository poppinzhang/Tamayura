import Cocoa

enum ReleasePageError: Error {
  case invalidURL
  case cannotOpen
}

enum ReleasePage {
  static func open(_ value: String, launch: (URL) -> Bool = { NSWorkspace.shared.open($0) }) throws {
    guard value.range(of: "^https://github\\.com/poppinzhang/Tamayura/releases/tag/v[0-9]+\\.[0-9]+\\.[0-9]+\\z",
                      options: .regularExpression) != nil,
          let url = URL(string: value) else {
      throw ReleasePageError.invalidURL
    }
    guard launch(url) else { throw ReleasePageError.cannotOpen }
  }
}
