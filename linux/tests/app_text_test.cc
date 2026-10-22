#include "app_text.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using namespace tamayura;

void Require(bool value, const std::string& message) {
  if (!value) throw std::runtime_error(message);
}

void TestResolve() {
  using app_text::Resolve;
  Require(Resolve("ja", {"zh_CN.UTF-8"}) == "ja", "explicit language wins");
  Require(Resolve("system", {"zh_TW.UTF-8", "zh_TW", "zh"}) == "zh",
          "every Chinese variant uses Chinese");
  Require(Resolve("system", {"fr_FR.UTF-8", "fr", "ja_JP.UTF-8", "ja"}) == "ja",
          "first supported preferred language");
  Require(Resolve("system", {"en_GB@euro"}) == "en", "locale modifiers ignored");
  Require(Resolve("system", {"C", "POSIX"}) == "en", "C locale uses English");
  Require(Resolve("system", {}) == "en", "English fallback");
  Require(Resolve("system", {"de-DE", "ja-JP"}) == "ja", "BCP 47 separators");
  Require(Resolve("fr", {"ja"}) == "ja", "unsupported preference follows the system");
}

void TestPreference() {
  Require(app_text::Preference() == "system", "default preference");
  Require(app_text::SetPreference("zh"), "accepts zh");
  Require(app_text::Current() == "zh", "explicit current language");
  Require(!app_text::SetPreference("fr"), "rejects unsupported language");
  Require(app_text::Preference() == "zh", "rejected value keeps the preference");
  Require(std::strcmp(app_text::Text(TextId::kOpenApp), "打开玉响") == 0, "Chinese text");
  Require(app_text::SetPreference("en"), "accepts en");
  Require(app_text::Format(TextId::kMissingArgument, "uri") == "Missing argument: uri",
          "format placeholder");
  Require(app_text::SetPreference("system"), "accepts system");
  setenv("LANGUAGE", "ja_JP", 1);
  // GLib caches language names per thread until the environment changes.
  const auto languages = app_text::PreferredLanguages();
  Require(!languages.empty(), "preferred languages available");
}

void TestTables() {
  for (const char* language : {"zh", "ja", "en"}) {
    for (int index = 0; index < static_cast<int>(TextId::kCount); ++index) {
      const char* text = app_text::Text(static_cast<TextId>(index), language);
      Require(text && *text, std::string("missing text ") + std::to_string(index) +
                                 " for " + language);
    }
  }
  Require(std::strcmp(app_text::Text(TextId::kQuitApp, "ja"), "Tamayura を終了") == 0,
          "Japanese tray text");
  Require(std::strcmp(app_text::Text(TextId::kQuitApp, "de"), "Quit Tamayura") == 0,
          "unknown language uses English");
  for (const char* language : {"zh", "ja", "en"}) {
    const std::string message = app_text::Text(TextId::kDownloadPathTooLong, language);
    const char* hint = std::strcmp(language, "zh") == 0 ? "路径更短"
                       : std::strcmp(language, "ja") == 0 ? "パスが短い"
                                                          : "shorter destination path";
    Require(message.find(hint) != std::string::npos,
            std::string("path-length failure gives recovery guidance in ") + language);
  }
  Require(std::strcmp(app_text::Text(TextId::kCount, "en"), "") == 0, "out of range");
}

}  // namespace

int main() {
  try {
    TestResolve();
    TestPreference();
    TestTables();
    std::cout << "Linux native text tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
