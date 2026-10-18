import Foundation

private struct TestFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw TestFailure(message: message) }
}

@main
struct AppTextTests {
  static func main() throws {
    // Keep the preference out of the user's defaults.
    let suite = "dev.tamayura.tests.language.\(UUID().uuidString)"
    AppText.defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    var passed = 0
    func test(_ name: String, _ body: () throws -> Void) throws {
      try body(); passed += 1; print("PASS \(name)")
    }

    try test("every language translates every text") {
      for language in AppText.supported {
        let table = try expectTable(language)
        for key in AppText.Key.allCases {
          try expect(!(table[key] ?? "").isEmpty, "\(language) misses \(key)")
        }
      }
      try expect(AppText.table.keys.sorted() == AppText.supported.sorted(), "unexpected tables")
    }

    try test("the system preference resolves like the Dart interface") {
      try expect(AppText.resolve("system", preferred: ["zh-Hans-CN"]) == "zh", "Simplified Chinese")
      try expect(AppText.resolve("system", preferred: ["zh-Hant-TW", "en-US"]) == "zh", "Traditional Chinese")
      try expect(AppText.resolve("system", preferred: ["fr-FR", "ja-JP"]) == "ja", "first supported")
      try expect(AppText.resolve("system", preferred: ["de-DE"]) == "en", "unsupported")
      try expect(AppText.resolve("system", preferred: []) == "en", "empty")
      try expect(AppText.resolve("ja", preferred: ["zh-Hans"]) == "ja", "chosen language")
    }

    try test("the saved preference selects the text") {
      try expect(AppText.language == "system", "defaults to the system")
      for (language, title) in [("zh", "退出玉响"), ("ja", "Tamayura を終了"), ("en", "Quit Tamayura")] {
        try expect(AppText.setLanguage(language), "accepts \(language)")
        try expect(AppText.language == language, "saves \(language)")
        try expect(AppText.text(.quitApp) == title, "\(language) title")
      }
      try expect(AppText.text(.missingArgument, "uri") == "Missing uri", "formats arguments")
      try expect(!AppText.setLanguage("fr"), "rejects unsupported languages")
      try expect(AppText.language == "en", "keeps the previous language")
      AppText.defaults.set("fr", forKey: "tamayura.language")
      try expect(AppText.language == "system", "ignores invalid stored values")
    }

    try test("I/O failures keep their errno classification") {
      _ = AppText.setLanguage("ja")
      errno = ENOENT
      let missing = PlatformFailure.io(.cannotAccess)
      try expect(missing.code == "FILE_NOT_FOUND", "missing file code")
      try expect(missing.message == AppText.table["ja"]![.cannotAccess], "localized message")
      errno = EACCES
      try expect(PlatformFailure.io(.cannotDelete).code == "PERMISSION_LOST", "permission code")
      try expect(PlatformFailure.invalid(.emptyPath).message == "ファイルのパスが空です", "invalid message")
    }

    print("\(passed) language tests passed")
  }

  private static func expectTable(_ language: String) throws -> [AppText.Key: String] {
    guard let table = AppText.table[language] else { throw TestFailure(message: "missing \(language)") }
    return table
  }
}
