#include "desktop_tray.h"

#include "app_text.h"

#include <cwchar>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace {

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

struct FakeShell {
  bool fail_add = false;
  bool fail_version = false;
  int adds = 0;
  int versions = 0;
  int removes = 0;
  int modifies = 0;
  NOTIFYICONDATAW last_add{};
  NOTIFYICONDATAW last_modify{};
};

FakeShell* current_shell = nullptr;

BOOL WINAPI NotifyIcon(DWORD operation, PNOTIFYICONDATAW data) {
  switch (operation) {
    case NIM_ADD:
      ++current_shell->adds;
      current_shell->last_add = *data;
      return !current_shell->fail_add;
    case NIM_SETVERSION:
      ++current_shell->versions;
      return data->uVersion == NOTIFYICON_VERSION_4 &&
             !current_shell->fail_version;
    case NIM_DELETE:
      ++current_shell->removes;
      return TRUE;
    case NIM_MODIFY:
      ++current_shell->modifies;
      current_shell->last_modify = *data;
      return TRUE;
    default:
      return TRUE;
  }
}

// Exercise real window messages, visibility, minimization, and destruction;
// only the Explorer API is replaced so tests do not modify the user's tray.
class TestWindow {
 public:
  TestWindow() {
    window_ = CreateWindowW(L"TamayuraTrayTest", L"Tamayura tray test",
                            WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                            320, 200, nullptr, nullptr, GetModuleHandleW(nullptr),
                            this);
    Require(window_ != nullptr, "test window created");
    tray_ = std::make_unique<tamayura::DesktopTray>(
        window_, LoadIconW(nullptr, IDI_APPLICATION), NotifyIcon);
    ShowWindow(window_, SW_SHOWNORMAL);
  }

  ~TestWindow() {
    if (IsWindow(window_)) DestroyWindow(window_);
  }

  HWND handle() const { return window_; }

  void Send(UINT message, WPARAM wparam = 0, LPARAM lparam = 0) {
    SendMessageW(window_, message, wparam, lparam);
  }

  void Activate(UINT event, UINT icon_id = tamayura::DesktopTray::kIconId) {
    Send(tamayura::DesktopTray::kCallbackMessage, 0,
         MAKELPARAM(event, icon_id));
  }

  static LRESULT CALLBACK Procedure(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto self = reinterpret_cast<TestWindow*>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self && self->tray_) {
      if (const auto result =
              self->tray_->HandleMessage(message, wparam, lparam)) {
        return *result;
      }
    }
    if (message == WM_DESTROY && self) self->tray_.reset();
    return DefWindowProcW(window, message, wparam, lparam);
  }

 private:
  HWND window_ = nullptr;
  std::unique_ptr<tamayura::DesktopTray> tray_;
};

void PumpMessages() {
  MSG message{};
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
}

void TestCloseAndActivate() {
  FakeShell shell;
  current_shell = &shell;
  {
    TestWindow window;
    Require(shell.adds == 1 && shell.versions == 1,
            "startup adds a version-4 icon");
    Require(shell.last_add.hWnd == window.handle() &&
                shell.last_add.hIcon != nullptr &&
                shell.last_add.uCallbackMessage ==
                    tamayura::DesktopTray::kCallbackMessage &&
                (shell.last_add.uFlags & NIF_MESSAGE) != 0 &&
                (shell.last_add.uFlags & NIF_SHOWTIP) != 0,
            "notification icon has an owner, image, callback, and tooltip");
    window.Send(WM_CLOSE);
    Require(IsWindow(window.handle()) && !IsWindowVisible(window.handle()),
            "close hides the window without destroying its engine host");
    window.Activate(NIN_SELECT, tamayura::DesktopTray::kIconId + 1);
    Require(!IsWindowVisible(window.handle()), "ignore another icon's event");
    window.Activate(NIN_SELECT);
    Require(IsWindowVisible(window.handle()), "mouse activation opens window");
    window.Send(WM_SYSCOMMAND, SC_CLOSE);
    Require(IsWindow(window.handle()) && !IsWindowVisible(window.handle()),
            "the system close command used by Alt+F4 also hides");
    window.Activate(NIN_KEYSELECT);
    Require(IsWindowVisible(window.handle()), "keyboard activation opens window");
    ShowWindow(window.handle(), SW_MINIMIZE);
    Require(IsIconic(window.handle()), "window minimized before restore");
    window.Activate(NIN_SELECT);
    Require(IsWindowVisible(window.handle()) && !IsIconic(window.handle()),
            "activation restores a minimized window");
    ShowWindow(window.handle(), SW_MAXIMIZE);
    window.Send(WM_CLOSE);
    window.Send(WM_COMMAND, tamayura::DesktopTray::kOpenCommand);
    Require(IsWindowVisible(window.handle()) && IsZoomed(window.handle()),
            "menu open preserves maximized state");
  }
  Require(shell.removes == 1, "destruction removes the tray icon exactly once");
}

void TestQuit() {
  FakeShell shell;
  current_shell = &shell;
  TestWindow window;
  window.Send(WM_CLOSE);
  window.Send(WM_COMMAND, tamayura::DesktopTray::kQuitCommand);
  Require(IsWindow(window.handle()), "quit waits for the current callback to end");
  PumpMessages();
  Require(!IsWindow(window.handle()), "explicit quit destroys the hidden window");
  Require(shell.removes == 1, "explicit quit removes the tray icon");
}

void TestCreationFailure() {
  FakeShell shell;
  shell.fail_add = true;
  current_shell = &shell;
  TestWindow window;
  window.Send(WM_CLOSE);
  Require(!IsWindow(window.handle()),
          "without an icon, close exits instead of creating an unreachable app");
  Require(shell.removes == 0, "failed icon registration is not deleted");
}

void TestVersionFailure() {
  FakeShell shell;
  shell.fail_version = true;
  current_shell = &shell;
  TestWindow window;
  Require(shell.removes == 1, "unsupported callback format removes the icon");
  window.Send(WM_CLOSE);
  Require(!IsWindow(window.handle()),
          "a failed callback-version registration never hides the app");
  Require(shell.removes == shell.adds, "every unusable added icon is removed");
}

void TestExplorerRestart() {
  FakeShell shell;
  current_shell = &shell;
  TestWindow window;
  const UINT restarted = RegisterWindowMessageW(L"TaskbarCreated");
  Require(restarted != 0, "Explorer restart message registered");
  window.Send(WM_CLOSE);
  window.Send(restarted);
  Require(shell.adds == 2 && shell.versions == 2 &&
              !IsWindowVisible(window.handle()),
          "Explorer restart recreates the icon and preserves a hidden window");
  shell.fail_add = true;
  window.Send(restarted);
  Require(IsWindowVisible(window.handle()),
          "failed Explorer recovery reveals the window");
  window.Send(WM_CLOSE);
  Require(!IsWindow(window.handle()),
          "close after failed Explorer recovery still exits normally");
}

void TestShutdown() {
  FakeShell shell;
  current_shell = &shell;
  {
    TestWindow window;
    Require(SendMessageW(window.handle(), WM_QUERYENDSESSION, 0, 0) == TRUE,
            "system shutdown is allowed");
    window.Send(WM_ENDSESSION, FALSE);
    window.Send(WM_CLOSE);
    Require(IsWindow(window.handle()) && !IsWindowVisible(window.handle()),
            "cancelled shutdown restores close-to-tray behavior");
    window.Send(WM_QUERYENDSESSION);
    window.Send(WM_ENDSESSION, TRUE);
    const int adds = shell.adds;
    window.Send(RegisterWindowMessageW(L"TaskbarCreated"));
    Require(shell.removes == 1 && shell.adds == adds,
            "session end removes its icon and never recreates it");
    window.Send(WM_CLOSE);
    Require(!IsWindow(window.handle()), "system shutdown bypasses close-to-tray");
  }
}

void TestLanguage() {
  FakeShell shell;
  current_shell = &shell;
  tamayura::app_text::SetPreference("zh");
  {
    TestWindow window;
    Require(std::wcscmp(shell.last_add.szTip, L"玉响 Tamayura") == 0,
            "the tooltip uses the interface language");
    tamayura::app_text::SetPreference("en");
    window.Send(tamayura::kLanguageChangedMessage);
    Require(shell.modifies == 1 &&
                (shell.last_modify.uFlags & NIF_TIP) != 0 &&
                std::wcscmp(shell.last_modify.szTip, L"Tamayura") == 0,
            "a language change updates the tooltip");
  }
  tamayura::app_text::SetPreference("system");
}

}  // namespace

int main() {
  try {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = TestWindow::Procedure;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"TamayuraTrayTest";
    Require(RegisterClassW(&window_class) != 0, "test window class registered");
    TestCloseAndActivate();
    TestQuit();
    TestCreationFailure();
    TestVersionFailure();
    TestExplorerRestart();
    TestShutdown();
    TestLanguage();
    Require(UnregisterClassW(window_class.lpszClassName, window_class.hInstance),
            "all test windows destroyed");
    std::cout << "Desktop tray tests passed (7 groups)\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
