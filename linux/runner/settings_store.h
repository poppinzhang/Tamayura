#ifndef TAMAYURA_SETTINGS_STORE_H_
#define TAMAYURA_SETTINGS_STORE_H_

#include <mutex>
#include <string>

namespace tamayura {

// Per-user native settings in $XDG_CONFIG_HOME/tamayura/settings.ini. The
// device identity lives outside the application data folders, so clearing
// the media database or caches keeps it, as on Windows and macOS.
class SettingsStore {
 public:
  explicit SettingsStore(std::string directory);
  static std::string DefaultDirectory();

  // Reads or creates "linux-<uuid>". Throws StorageError when it cannot be
  // persisted, so the app never runs with an identity that changes.
  std::string DeviceId();
  // Missing or unreadable settings mean background sharing is off.
  bool BackgroundSharing();
  // Throws StorageError (SETTINGS_UNAVAILABLE) when it cannot be saved.
  void SetBackgroundSharing(bool enabled);

 private:
  std::string directory_;
  std::string path_;
  std::mutex mutex_;
};

}  // namespace tamayura

#endif  // TAMAYURA_SETTINGS_STORE_H_
