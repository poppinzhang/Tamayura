#include "settings_store.h"

#include <sys/stat.h>

#include "discovery_core.h"
#include "test_support.h"

namespace {
using namespace tamayura;
using namespace tamayura_test;

void TestDeviceIdentity() {
  TempDirectory temp;
  SettingsStore settings(temp / "config/tamayura");
  const auto id = settings.DeviceId();
  Expect(IsLinuxId(id), "lowercase Linux UUID: " + id);
  Expect(settings.DeviceId() == id, "identity is stable");
  Expect(SettingsStore(temp / "config/tamayura").DeviceId() == id,
         "identity persists across processes");
  struct stat info {};
  Expect(stat((temp / "config/tamayura/settings.ini").c_str(), &info) == 0 &&
             (info.st_mode & 0777) == 0600,
         "settings are private");
  WriteText(temp / "config/tamayura/settings.ini", "[device]\nid=linux-INVALID\n");
  const auto replaced = SettingsStore(temp / "config/tamayura").DeviceId();
  Expect(IsLinuxId(replaced) && replaced != id, "an invalid identity is replaced");
}

void TestBackgroundSharing() {
  TempDirectory temp;
  SettingsStore settings(temp / "config");
  Expect(!settings.BackgroundSharing(), "off by default");
  settings.SetBackgroundSharing(true);
  Expect(settings.BackgroundSharing(), "enabled");
  const auto id = settings.DeviceId();
  settings.SetBackgroundSharing(false);
  Expect(!SettingsStore(temp / "config").BackgroundSharing(), "persisted");
  Expect(settings.DeviceId() == id, "other settings are kept");
  WriteText(temp / "config/settings.ini", "not a key file");
  Expect(!settings.BackgroundSharing(), "damaged settings read as off");
}

void TestUnwritableSettings() {
  TempDirectory temp;
  WriteText(temp / "file", "x");
  SettingsStore blocked(temp / "file/config");
  Reject("SETTINGS_UNAVAILABLE", [&] { blocked.SetBackgroundSharing(true); });
  Reject("DEVICE_ID_UNAVAILABLE", [&] { blocked.DeviceId(); });
  SettingsStore relative("relative/config");
  Reject("SETTINGS_UNAVAILABLE", [&] { relative.SetBackgroundSharing(true); });
  Expect(!blocked.BackgroundSharing(), "unreadable settings read as off");
}

}  // namespace

int main() {
  return RunTests("settings", {
      {"device identity", TestDeviceIdentity},
      {"background sharing", TestBackgroundSharing},
      {"unwritable settings fail visibly", TestUnwritableSettings},
  });
}
