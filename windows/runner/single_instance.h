#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>

namespace tamayura {

// Shared by tray actions and repeat launches. Preserves maximized windows.
void ShowAndActivateWindow(HWND window) noexcept;

// Use on the runner's UI thread and keep alive until all application resources
// have been destroyed. The optional identity isolates native test processes.
class SingleInstance {
 public:
  enum class StartResult { kPrimary, kActivated, kError };

  explicit SingleInstance(std::wstring identity = L"");
  ~SingleInstance();
  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  StartResult Start(DWORD timeout_ms = 10000);
  // Bind only after the first Flutter frame; early requests remain pending.
  void SetWindow(HWND window) noexcept;
  void StopActivation() noexcept;

 private:
  bool CreateEndpoint();
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept;

  std::wstring identity_;
  HANDLE mutex_ = nullptr;
  bool owns_mutex_ = false;
  HWND endpoint_ = nullptr;
  HWND window_ = nullptr;
  bool pending_ = false;
  bool stopping_ = false;
};

}  // namespace tamayura

#endif  // RUNNER_SINGLE_INSTANCE_H_
