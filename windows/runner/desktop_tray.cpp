#include "desktop_tray.h"

#include <windowsx.h>

#include <cwchar>

#include "app_text.h"
#include "single_instance.h"

namespace tamayura {

DesktopTray::DesktopTray(HWND window, HICON icon, NotifyIcon notify_icon)
    : window_(window),
      icon_(icon),
      notify_icon_(notify_icon),
      taskbar_created_message_(RegisterWindowMessageW(L"TaskbarCreated")) {
  AddIcon();
}

DesktopTray::~DesktopTray() { RemoveIcon(); }

bool DesktopTray::AddIcon() noexcept {
  if (icon_added_) return true;
  if (!window_ || !icon_ || !taskbar_created_message_) return false;

  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kCallbackMessage;
  data.hIcon = icon_;
  wcscpy_s(data.szTip, app_text::Text(TextId::kTrayTooltip));
  if (!notify_icon_(NIM_ADD, &data)) return false;

  icon_added_ = true;
  data.uVersion = NOTIFYICON_VERSION_4;
  if (!notify_icon_(NIM_SETVERSION, &data)) {
    // Only enable close-to-tray once the icon's supported event format is known.
    RemoveIcon();
    return false;
  }
  return true;
}

void DesktopTray::RemoveIcon() noexcept {
  if (!icon_added_) return;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  notify_icon_(NIM_DELETE, &data);
  icon_added_ = false;
}

void DesktopTray::UpdateTooltip() noexcept {
  if (!icon_added_) return;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_TIP | NIF_SHOWTIP;
  wcscpy_s(data.szTip, app_text::Text(TextId::kTrayTooltip));
  notify_icon_(NIM_MODIFY, &data);
}

void DesktopTray::OpenWindow() noexcept {
  ShowAndActivateWindow(window_);
}

void DesktopTray::ShowMenu(POINT position) noexcept {
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    OpenWindow();
    return;
  }
  // Built on demand, so the menu always uses the current interface language.
  const auto language = app_text::Current();
  const bool populated =
      AppendMenuW(menu, MF_STRING, kOpenCommand,
                  app_text::Text(TextId::kOpenApp, language)) &&
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr) &&
      AppendMenuW(menu, MF_STRING, kQuitCommand,
                  app_text::Text(TextId::kQuitApp, language));
  if (!populated) {
    DestroyMenu(menu);
    OpenWindow();
    return;
  }
  SetMenuDefaultItem(menu, kOpenCommand, FALSE);
  // The foreground owner is necessary for clicking outside the menu to dismiss
  // it. The trailing WM_NULL is required for repeated notification-area menus.
  SetForegroundWindow(window_);
  const UINT selected = static_cast<UINT>(TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
      position.x, position.y, window_, nullptr));
  DestroyMenu(menu);
  PostMessageW(window_, WM_NULL, 0, 0);
  if (selected != 0) {
    PostMessageW(window_, WM_COMMAND, selected, 0);
  } else {
    NOTIFYICONDATAW data{};
    data.cbSize = sizeof(data);
    data.hWnd = window_;
    data.uID = kIconId;
    notify_icon_(NIM_SETFOCUS, &data);
  }
}

std::optional<LRESULT> DesktopTray::HandleMessage(
    UINT message, WPARAM wparam, LPARAM lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    // Explorer discards all registrations on restart. If restoration fails,
    // reveal the window so a hidden process never becomes unreachable.
    icon_added_ = false;
    if (!quitting_ && !session_ending_ && !AddIcon() &&
        !IsWindowVisible(window_)) {
      OpenWindow();
    }
    return 0;
  }
  if (message == kLanguageChangedMessage) {
    UpdateTooltip();
    return 0;
  }
  if (message == kCallbackMessage) {
    if (!icon_added_ || HIWORD(lparam) != kIconId) return 0;
    switch (LOWORD(lparam)) {
      case NIN_SELECT:
      case NIN_KEYSELECT:
        OpenWindow();
        break;
      case WM_CONTEXTMENU: {
        POINT position{GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)};
        ShowMenu(position);
        break;
      }
    }
    return 0;
  }
  switch (message) {
    case WM_CLOSE:
      // Without a usable icon, retain normal Windows close behavior.
      if (!quitting_ && !session_ending_ && AddIcon()) {
        ShowWindow(window_, SW_HIDE);
        return 0;
      }
      break;
    case WM_COMMAND:
      if (lparam == 0 && HIWORD(wparam) == 0) {
        switch (LOWORD(wparam)) {
          case kOpenCommand:
            OpenWindow();
            return 0;
          case kQuitCommand:
            // Post the close to avoid destroying this controller while its
            // callback (or the popup menu's nested message loop) is running.
            quitting_ = true;
            if (!PostMessageW(window_, WM_CLOSE, 0, 0)) {
              quitting_ = false;
              OpenWindow();
            }
            return 0;
        }
      }
      break;
    case WM_QUERYENDSESSION:
      session_ending_ = true;
      // Leave shutdown/logoff handling to the regular window procedure.
      break;
    case WM_ENDSESSION:
      session_ending_ = wparam != FALSE;
      if (session_ending_) RemoveIcon();
      break;
  }
  return std::nullopt;
}

}  // namespace tamayura
