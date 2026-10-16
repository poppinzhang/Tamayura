#ifndef TAMAYURA_WINDOWS_PLATFORM_H_
#define TAMAYURA_WINDOWS_PLATFORM_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace tamayura {
class WindowsStorage;
class LanDiscovery;

// Flutter's desktop messenger must only be called from its platform thread.
// Queue ownership avoids posting heap pointers to a window that might close.
class UiDispatcher {
 public:
  static constexpr UINT kMessage = WM_APP + 77;
  explicit UiDispatcher(HWND window) : window_(window) {}
  void Post(std::function<void()> action);
  void Drain();
  void Shutdown();
 private:
  std::mutex mutex_;
  HWND window_;
  std::deque<std::function<void()>> pending_;
};

class WorkerPool {
 public:
  WorkerPool();
  ~WorkerPool();
  void Submit(std::function<void()> work);
  void Stop();
 private:
  std::mutex mutex_;
  std::condition_variable ready_;
  bool stopped_ = false;
  std::deque<std::function<void()>> pending_;
  std::vector<std::thread> workers_;
};

class WindowsPlatform {
 public:
  WindowsPlatform(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsPlatform();
  void Drain() { dispatcher_->Drain(); }
  void Tick();
 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using Result = flutter::MethodResult<Value>;
  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result);
  Map SharingStatus() const;
  void Background(std::shared_ptr<Result> result, std::function<Value()> operation);
  HWND window_;
  bool sharing_enabled_ = false;
  std::shared_ptr<UiDispatcher> dispatcher_;
  std::shared_ptr<WindowsStorage> storage_;
  std::unique_ptr<LanDiscovery> discovery_;
  WorkerPool workers_;
  std::unique_ptr<flutter::EventSink<Value>> discovery_sink_;
  std::unique_ptr<flutter::EventSink<Value>> sharing_sink_;
  std::unique_ptr<flutter::MethodChannel<Value>> methods_;
  std::unique_ptr<flutter::EventChannel<Value>> discovery_channel_;
  std::unique_ptr<flutter::EventChannel<Value>> sharing_channel_;
};
}  // namespace tamayura
#endif
