#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <cstdint>
#include <vector>

namespace tamayura {

// An ARGB32 image in network byte order, as StatusNotifierItem expects.
struct TrayIcon {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> argb;
};

}  // namespace tamayura

#endif  // RUNNER_TRAY_ICON_H_
