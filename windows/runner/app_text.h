#ifndef RUNNER_APP_TEXT_H_
#define RUNNER_APP_TEXT_H_

#include <windows.h>

#include <string>
#include <vector>

namespace tamayura {

// Posted to the main window after the interface language changes.
constexpr UINT kLanguageChangedMessage = WM_APP + 79;

// Entries of each language table follow this order.
enum class TextId {
  kTrayTooltip,
  kOpenApp,
  kQuitApp,
  kChooseFolder,
  kDiscoveryFailed,
  kInvalidDiscoveryArguments,
  kDiscoveryServiceFailed,
  kNetworkInterfacesUnavailable,
  kMissingArgument,
  kMissingSharingState,
  kInvalidPort,
  kInvalidLanguage,
  kSettingsUnavailable,
  kDeviceIdCreateFailed,
  kDeviceIdReadFailed,
  kSingleInstanceFailed,
  kOperationFailed,
};

// Native text in the interface language chosen in Tamayura. Dart sends the
// preference ("system", "zh", "ja" or "en") at startup and on every change;
// "system" resolves as in Dart: the first supported preferred UI language,
// otherwise English.
namespace app_text {

std::string Resolve(const std::string& preference,
                    const std::vector<std::wstring>& preferred);
// Returns false and keeps the previous preference for unsupported values.
bool SetPreference(const std::string& preference);
std::string Preference();
// The resolved language code, using the user's preferred UI languages.
std::string Current();
const wchar_t* Text(TextId id, const std::string& language);
const wchar_t* Text(TextId id);
// UTF-8 text for errors reported to Dart.
std::string Utf8(TextId id);

}  // namespace app_text
}  // namespace tamayura

#endif  // RUNNER_APP_TEXT_H_
