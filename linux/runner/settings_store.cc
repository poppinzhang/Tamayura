#include "settings_store.h"

#include <glib.h>
#include <glib/gstdio.h>

#include <memory>

#include "app_text.h"
#include "discovery_core.h"
#include "storage_core.h"

namespace tamayura {
namespace {

constexpr char kDeviceGroup[] = "device";
constexpr char kSharingGroup[] = "sharing";

struct KeyFileDeleter {
  void operator()(GKeyFile* file) const { g_key_file_free(file); }
};
using KeyFile = std::unique_ptr<GKeyFile, KeyFileDeleter>;

// A missing or damaged file reads as empty; saving replaces it atomically.
KeyFile Load(const std::string& path) {
  KeyFile file(g_key_file_new());
  g_key_file_load_from_file(file.get(), path.c_str(), G_KEY_FILE_KEEP_COMMENTS,
                            nullptr);
  return file;
}

bool Save(const std::string& directory, const std::string& path,
          GKeyFile* file) {
  if (g_mkdir_with_parents(directory.c_str(), 0700) != 0) return false;
  gsize length = 0;
  g_autofree gchar* data = g_key_file_to_data(file, &length, nullptr);
  if (!data) return false;
  return g_file_set_contents_full(
      path.c_str(), data, static_cast<gssize>(length),
      G_FILE_SET_CONTENTS_CONSISTENT, 0600, nullptr);
}

}  // namespace

SettingsStore::SettingsStore(std::string directory)
    : directory_(std::move(directory)),
      path_(directory_ + "/settings.ini") {}

std::string SettingsStore::DefaultDirectory() {
  const char* base = g_get_user_config_dir();
  return std::string(base ? base : "") + "/tamayura";
}

std::string SettingsStore::DeviceId() {
  std::lock_guard<std::mutex> lock(mutex_);
  auto file = Load(path_);
  g_autofree gchar* previous =
      g_key_file_get_string(file.get(), kDeviceGroup, "id", nullptr);
  if (previous && IsLinuxId(previous)) return previous;
  g_autofree gchar* uuid = g_uuid_string_random();
  const std::string value = std::string("linux-") + uuid;
  if (!IsLinuxId(value)) {
    throw StorageError("DEVICE_ID_UNAVAILABLE", TextId::kDeviceIdUnavailable);
  }
  g_key_file_set_string(file.get(), kDeviceGroup, "id", value.c_str());
  if (directory_.empty() || directory_[0] != '/' ||
      !Save(directory_, path_, file.get())) {
    throw StorageError("DEVICE_ID_UNAVAILABLE", TextId::kDeviceIdUnavailable);
  }
  return value;
}

bool SettingsStore::BackgroundSharing() {
  std::lock_guard<std::mutex> lock(mutex_);
  auto file = Load(path_);
  g_autoptr(GError) error = nullptr;
  const gboolean value = g_key_file_get_boolean(file.get(), kSharingGroup,
                                                "background", &error);
  return !error && value;
}

void SettingsStore::SetBackgroundSharing(bool enabled) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto file = Load(path_);
  g_key_file_set_boolean(file.get(), kSharingGroup, "background", enabled);
  if (directory_.empty() || directory_[0] != '/' ||
      !Save(directory_, path_, file.get())) {
    throw StorageError("SETTINGS_UNAVAILABLE", TextId::kSettingsUnavailable);
  }
}

}  // namespace tamayura
