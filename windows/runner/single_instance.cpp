#include "single_instance.h"

#include <sddl.h>

#include <algorithm>
#include <utility>
#include <vector>

namespace tamayura {
namespace {

constexpr wchar_t kEndpointClass[] =
    L"Tamayura.SingleInstance.MessageWindow.v1";
constexpr UINT kActivateMessage = WM_APP + 80;

std::wstring UserIdentity() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return {};
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size);
  if (size == 0 ||
      !GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
    CloseHandle(token);
    return {};
  }
  CloseHandle(token);
  LPWSTR sid = nullptr;
  const auto user = reinterpret_cast<const TOKEN_USER*>(buffer.data());
  if (!ConvertSidToStringSidW(user->User.Sid, &sid)) return {};
  std::wstring identity = L"Tamayura.SingleInstance.v1.";
  identity += sid;
  LocalFree(sid);
  return identity;
}

}  // namespace

void ShowAndActivateWindow(HWND window) noexcept {
  if (!window || !IsWindow(window)) return;
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  if (!SetForegroundWindow(window)) {
    // Windows may deny focus after intervening user input or across privilege
    // boundaries. Reveal the window and request attention without focus hacks.
    FLASHWINFO flash{};
    flash.cbSize = sizeof(flash);
    flash.hwnd = window;
    flash.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
    flash.uCount = 3;
    FlashWindowEx(&flash);
  }
}

SingleInstance::SingleInstance(std::wstring identity)
    : identity_(std::move(identity)) {}

SingleInstance::~SingleInstance() {
  StopActivation();
  if (endpoint_) DestroyWindow(endpoint_);
  if (owns_mutex_) ReleaseMutex(mutex_);
  if (mutex_) CloseHandle(mutex_);
}

SingleInstance::StartResult SingleInstance::Start(DWORD timeout_ms) {
  if (mutex_) return StartResult::kError;
  if (identity_.empty()) identity_ = UserIdentity();
  if (identity_.empty()) return StartResult::kError;
  const auto name = L"Local\\" + identity_;
  mutex_ = CreateMutexExW(nullptr, name.c_str(), 0,
                          SYNCHRONIZE | MUTEX_MODIFY_STATE);
  if (!mutex_) return StartResult::kError;

  const ULONGLONG started = GetTickCount64();
  DWORD waited = WaitForSingleObject(mutex_, 0);
  for (;;) {
    if (waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED) {
      owns_mutex_ = true;
      return CreateEndpoint() ? StartResult::kPrimary : StartResult::kError;
    }
    if (waited != WAIT_TIMEOUT) return StartResult::kError;
    const ULONGLONG elapsed = GetTickCount64() - started;
    if (elapsed >= timeout_ms) return StartResult::kError;
    const auto remaining = static_cast<DWORD>(timeout_ms - elapsed);

    // This endpoint exists before COM, plugins, or Dart begin initialization.
    // Unlike a title search, it also works while the Flutter window is hidden.
    const HWND endpoint =
        FindWindowExW(HWND_MESSAGE, nullptr, kEndpointClass, identity_.c_str());
    if (endpoint) {
      DWORD process_id = 0;
      GetWindowThreadProcessId(endpoint, &process_id);
      if (process_id != 0) {
        // A user-initiated second launch can pass its foreground permission to
        // the first process. Do this before asking it to show the window.
        AllowSetForegroundWindow(process_id);
        DWORD_PTR acknowledged = 0;
        if (SendMessageTimeoutW(
                endpoint, kActivateMessage, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK,
                std::min<DWORD>(remaining, 200), &acknowledged) &&
            acknowledged == 1) {
          return StartResult::kActivated;
        }
      }
    }
    // Wait on ownership as well as retrying discovery: if the first process
    // exits or crashes during startup, exactly one waiting launch takes over.
    const ULONGLONG after_send = GetTickCount64() - started;
    if (after_send >= timeout_ms) return StartResult::kError;
    waited = WaitForSingleObject(
        mutex_,
        std::min<DWORD>(25, static_cast<DWORD>(timeout_ms - after_send)));
  }
}

bool SingleInstance::CreateEndpoint() {
  WNDCLASSW window_class{};
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kEndpointClass;
  window_class.lpfnWndProc = WindowProc;
  if (!RegisterClassW(&window_class) &&
      GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }
  endpoint_ =
      CreateWindowExW(0, kEndpointClass, identity_.c_str(), 0, 0, 0, 0, 0,
                      HWND_MESSAGE, nullptr, window_class.hInstance, this);
  return endpoint_ != nullptr;
}

void SingleInstance::SetWindow(HWND window) noexcept {
  if (stopping_) return;
  window_ = window;
  if (window_ && pending_) {
    pending_ = false;
    ShowAndActivateWindow(window_);
  }
}

void SingleInstance::StopActivation() noexcept {
  stopping_ = true;
  pending_ = false;
  window_ = nullptr;
}

LRESULT CALLBACK SingleInstance::WindowProc(HWND window, UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) noexcept {
  auto self = reinterpret_cast<SingleInstance*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    self = static_cast<SingleInstance*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (self && message == kActivateMessage) {
    if (self->stopping_) return 0;
    if (self->window_) {
      ShowAndActivateWindow(self->window_);
    } else {
      self->pending_ = true;
    }
    return 1;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace tamayura
