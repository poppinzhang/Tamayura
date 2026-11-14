#ifndef TAMAYURA_WINDOWS_PLATFORM_H_
#define TAMAYURA_WINDOWS_PLATFORM_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <functional>
#include <memory>

#include "windows_executor.h"

namespace tamayura {
class WindowsStorage;
class LanDiscovery;
class WindowsUpdate;

class WindowsPlatform {
 public:
  WindowsPlatform(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsPlatform();
  void Drain() {
    const auto dispatcher = dispatcher_;
    dispatcher->Drain();
  }
  void Tick();
 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using Result = flutter::MethodResult<Value>;
  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result);
  void HandleUpdate(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result);
  Map SharingStatus() const;
  void Background(std::shared_ptr<Result> result, std::function<Value()> operation,
                  bool preview = false);
  HWND window_;
  bool sharing_enabled_ = false;
  std::shared_ptr<UiDispatcher> dispatcher_;
  std::shared_ptr<WindowsStorage> storage_;
  std::unique_ptr<LanDiscovery> discovery_;
  std::shared_ptr<WindowsUpdate> updates_;
  WorkerPool workers_;
  // Shell thumbnail providers and WIC codecs can block inside third-party code.
  // Keep their concurrency bounded and independent from scans and file transfer.
  WorkerPool previews_{2};
  std::unique_ptr<flutter::EventSink<Value>> discovery_sink_;
  std::unique_ptr<flutter::EventSink<Value>> sharing_sink_;
  std::unique_ptr<flutter::MethodChannel<Value>> methods_;
  std::unique_ptr<flutter::MethodChannel<Value>> update_methods_;
  std::unique_ptr<flutter::EventChannel<Value>> discovery_channel_;
  std::unique_ptr<flutter::EventChannel<Value>> sharing_channel_;
};
}  // namespace tamayura
#endif
