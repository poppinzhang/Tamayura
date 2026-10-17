import Foundation

@main
struct ReleasePageTests {
  static func main() throws {
    let release = "https://github.com/poppinzhang/Tamayura/releases/tag/v1.2.3"
    var opened: [String] = []
    try ReleasePage.open(release) { opened.append($0.absoluteString); return true }
    precondition(opened == [release])
    print("PASS opens the exact version release in the browser")

    for invalid in [
      "http://github.com/poppinzhang/Tamayura/releases/tag/v1.2.3",
      "https://github.com.evil.invalid/poppinzhang/Tamayura/releases/tag/v1.2.3",
      "https://github.com/other/project/releases/tag/v1.2.3",
      "https://github.com/poppinzhang/Tamayura/releases/latest",
      release + "?next=https://example.invalid", release + "#fragment", release + "\n",
      release + "/../other", "file:///Applications/Example.app",
      "https://user@github.com/poppinzhang/Tamayura/releases/tag/v1.2.3"
    ] {
      do {
        try ReleasePage.open(invalid) { _ in preconditionFailure("Invalid URL was opened") }
        preconditionFailure("Invalid URL was accepted")
      } catch ReleasePageError.invalidURL {}
    }
    print("PASS rejects unrelated, malformed and non-HTTPS links")
    do {
      try ReleasePage.open(release) { _ in false }
      preconditionFailure("Browser failure was ignored")
    } catch ReleasePageError.cannotOpen {}
    print("PASS browser launch errors remain visible and retryable")
  }
}
