#ifndef RUNNER_APP_TEXT_H_
#define RUNNER_APP_TEXT_H_

#include <string>
#include <vector>

namespace tamayura {

// Every identifier has a Chinese, Japanese and English entry; app_text.cc
// checks the table size at compile time.
enum class TextId {
  kAppName,
  kTrayTooltip,
  kOpenApp,
  kQuitApp,
  kChooseFolder,
  kChooseAccept,
  kChooseCancel,
  kMissingArgument,
  kMissingSharingState,
  kInvalidPort,
  kInvalidLanguage,
  kInvalidDiscoveryArguments,
  kDiscoveryFailed,
  kNetworkInterfacesUnavailable,
  kSettingsUnavailable,
  kDeviceIdUnavailable,
  kOperationFailed,
  kOpenWindowFirst,
  kPickerOpen,
  kSelectLocalFolder,
  kRootDirectory,
  kCannotAccess,
  kSymbolicLink,
  kLocalPathRequired,
  kInvalidMediaName,
  kInvalidRelativePath,
  kDriveLetterPath,
  kCannotCreateSubdirectory,
  kEmptyPath,
  kCannotReadDeletion,
  kOnlyRegularFiles,
  kCannotDelete,
  kCannotReadMediaInfo,
  kMediaMissing,
  kMediaTooLarge,
  kInvalidRange,
  kFileChanged,
  kFileEnded,
  kScanCancelled,
  kDirectoryOverlap,
  kDuplicateDirectoryId,
  kCannotReadSharedDirectory,
  kFileNotShared,
  kPartsInvalid,
  kSourceLocation,
  kPartsSize,
  kCannotCreateFile,
  kCannotReadStaging,
  kPartsChanged,
  kCannotSaveSpace,
  kCannotFinishSave,
  kTooManySameName,
  kPrivateDirectoryUnavailable,
  kUnsupportedMedia,
  kOpenFailed,
  kRevealFailed,
  kPreviewRange,
  kCannotDecode,
  kCannotEncodePreview,
  kThumbnailTimeout,
  kResourcesExhausted,
  kInvalidReleaseUrl,
  kOpenReleaseFailed,
  kCount,  // Must stay last.
};

// Native text in the interface language chosen in Tamayura. Dart sends the
// preference ("system", "zh", "ja" or "en") at startup and on every change;
// "system" resolves as in Dart: the first supported preferred language,
// otherwise English. The preference is kept only in this process.
namespace app_text {

std::string Resolve(const std::string& preference,
                    const std::vector<std::string>& preferred);
// Returns false and keeps the previous preference for unsupported values.
bool SetPreference(const std::string& preference);
std::string Preference();
// Locale names from LANGUAGE, LC_ALL, LC_MESSAGES and LANG, as GLib and the
// Flutter engine read them.
std::vector<std::string> PreferredLanguages();
// The resolved language code for the current preference.
std::string Current();
const char* Text(TextId id, const std::string& language);
const char* Text(TextId id);
// Replaces the single "%s" placeholder of a text.
std::string Format(TextId id, const std::string& argument);

}  // namespace app_text
}  // namespace tamayura

#endif  // RUNNER_APP_TEXT_H_
