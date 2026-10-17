#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  platform_ = std::make_unique<tamayura::WindowsPlatform>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetTimer(GetHandle(), 1, 1000, nullptr);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  const auto tray_icon = static_cast<HICON>(LoadImageW(
      GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  desktop_tray_ =
      std::make_unique<tamayura::DesktopTray>(GetHandle(), tray_icon);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  desktop_tray_.reset();
  KillTimer(GetHandle(), 1);
  platform_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handle close before Flutter can destroy the view and its background services.
  if (desktop_tray_) {
    if (const auto result = desktop_tray_->HandleMessage(message, wparam, lparam)) {
      return *result;
    }
  }
  if (platform_ && message == tamayura::UiDispatcher::kMessage) {
    platform_->Drain();
    return 0;
  }
  if (platform_ && message == WM_TIMER && wparam == 1) {
    platform_->Tick();
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    if (message == WM_SHOWWINDOW) {
      // Flutter tracks this host and its child HWND separately. The child
      // reports visibility through resize events, so hiding only the host
      // would otherwise leave Dart in "inactive" instead of "hidden". Keep
      // both visibility records in sync without disposing the view or engine.
      flutter_controller_->engine()->ProcessExternalWindowMessage(
          flutter_controller_->view()->GetNativeWindow(), message, wparam,
          lparam);
    }
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
