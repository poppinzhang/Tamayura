#ifndef RUNNER_DESKTOP_TRAY_H_
#define RUNNER_DESKTOP_TRAY_H_

#include <windows.h>
#include <shellapi.h>

#include <optional>

namespace tamayura {

// Keeps the existing Flutter window and engine alive when the window is closed.
// The icon is shared with the runner; this class only owns its shell registration.
class DesktopTray {
 public:
  using NotifyIcon = BOOL(WINAPI*)(DWORD, PNOTIFYICONDATAW);

  static constexpr UINT kCallbackMessage = WM_APP + 78;
  static constexpr UINT kOpenCommand = 40001;
  static constexpr UINT kQuitCommand = 40002;
  static constexpr UINT kIconId = 1;

  DesktopTray(HWND window, HICON icon,
              NotifyIcon notify_icon = Shell_NotifyIconW);
  ~DesktopTray();

  DesktopTray(const DesktopTray&) = delete;
  DesktopTray& operator=(const DesktopTray&) = delete;

  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam) noexcept;

 private:
  bool AddIcon() noexcept;
  void RemoveIcon() noexcept;
  void UpdateTooltip() noexcept;
  void OpenWindow() noexcept;
  void ShowMenu(POINT position) noexcept;

  HWND window_;
  HICON icon_;
  NotifyIcon notify_icon_;
  UINT taskbar_created_message_;
  bool icon_added_ = false;
  bool quitting_ = false;
  bool session_ending_ = false;
};

}  // namespace tamayura

#endif  // RUNNER_DESKTOP_TRAY_H_
