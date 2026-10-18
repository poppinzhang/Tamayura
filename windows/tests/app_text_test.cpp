#include "app_text.h"

#include <cwchar>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

}  // namespace

int main() {
  using tamayura::TextId;
  namespace text = tamayura::app_text;
  try {
    Require(text::Resolve("system", {L"zh-Hans-CN"}) == "zh", "Simplified Chinese");
    Require(text::Resolve("system", {L"zh-TW", L"en-US"}) == "zh",
            "Traditional Chinese uses the Simplified Chinese translation");
    Require(text::Resolve("system", {L"fr-FR", L"ja-JP"}) == "ja",
            "the first supported language wins");
    Require(text::Resolve("system", {L"de-DE"}) == "en", "unsupported languages use English");
    Require(text::Resolve("system", {}) == "en", "no preferred languages use English");
    Require(text::Resolve("ja", {L"zh-CN"}) == "ja", "a chosen language ignores the system");

    Require(text::Preference() == "system", "the system language is the default");
    Require(!text::SetPreference("fr") && text::Preference() == "system",
            "unsupported preferences are rejected");
    Require(text::SetPreference("ja") && text::Current() == "ja", "a chosen language applies");
    Require(std::wcscmp(text::Text(TextId::kQuitApp), L"Tamayura を終了") == 0, "Japanese text");
    Require(text::Utf8(TextId::kQuitApp) == std::string("Tamayura を終了"), "UTF-8 text");
    Require(text::SetPreference("zh") &&
                std::wcscmp(text::Text(TextId::kOpenApp), L"打开玉响") == 0,
            "Chinese text");
    Require(text::SetPreference("en") &&
                std::wcscmp(text::Text(TextId::kQuitApp), L"Exit Tamayura") == 0,
            "English text");

    for (const char* language : {"zh", "ja", "en"}) {
      for (int id = 0; id <= static_cast<int>(TextId::kOperationFailed); ++id) {
        const wchar_t* value = text::Text(static_cast<TextId>(id), language);
        Require(value != nullptr && *value != L'\0', "every language translates every text");
      }
    }
    Require(text::SetPreference("system"), "the system language can be restored");
    std::cout << "App text tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
