#include "windows_platform.h"

#include <flutter/standard_method_codec.h>
#include <flutter/event_stream_handler_functions.h>

#include <algorithm>
#include <cwctype>
#include <set>

#include "discovery_core.h"
#include "lan_discovery.h"
#include "windows_storage.h"

namespace tamayura {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr wchar_t kRegistry[] = L"Software\\Tamayura";

std::string ArgumentString(const Map& args, const char* key) {
  const auto found = args.find(Value(key));
  if (found != args.end()) {
    if (const auto* value = std::get_if<std::string>(&found->second)) {
      if (!value->empty()) return *value;
    }
  }
  throw StorageError("INVALID_ARGUMENT", std::string("缺少参数：") + key);
}

bool ReadSharingEnabled() {
  DWORD value = 0, size = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER, kRegistry, L"BackgroundSharing",
      RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS && value != 0;
}

void WriteSetting(const wchar_t* name, DWORD type, const void* data, DWORD bytes) {
  HKEY key = nullptr;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kRegistry, 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status == ERROR_SUCCESS) {
    status = RegSetValueExW(key, name, 0, type, static_cast<const BYTE*>(data), bytes);
    RegCloseKey(key);
  }
  if (status != ERROR_SUCCESS) {
    throw StorageError("SETTINGS_UNAVAILABLE", "无法保存 Windows 应用设置");
  }
}

std::string DeviceId() {
  wchar_t previous[128]{};
  DWORD bytes = sizeof(previous);
  if (RegGetValueW(HKEY_CURRENT_USER, kRegistry, L"DeviceId", RRF_RT_REG_SZ,
      nullptr, previous, &bytes) == ERROR_SUCCESS) {
    const auto value = Utf8(previous);
    if (IsWindowsId(value)) return value;
  }
  GUID uuid{};
  if (FAILED(CoCreateGuid(&uuid))) {
    throw StorageError("DEVICE_ID_UNAVAILABLE", "无法创建 Windows 设备标识");
  }
  wchar_t text[40]{};
  if (StringFromGUID2(uuid, text, 40) != 39) {
    throw StorageError("DEVICE_ID_UNAVAILABLE", "无法读取 Windows 设备标识");
  }
  std::wstring value = L"windows-" + std::wstring(text + 1, 36);
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  WriteSetting(L"DeviceId", REG_SZ, value.c_str(),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  return Utf8(value);
}
}  // namespace

void UiDispatcher::Post(std::function<void()> action) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!window_) return;
  pending_.push_back(std::move(action));
  if (!PostMessageW(window_, kMessage, 0, 0)) pending_.pop_back();
}

void UiDispatcher::Drain() {
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tasks.swap(pending_);
  }
  for (auto& task : tasks) task();
}

void UiDispatcher::Shutdown() {
  std::lock_guard<std::mutex> lock(mutex_);
  window_ = nullptr;
  pending_.clear();
}

WorkerPool::WorkerPool() {
  for (int i = 0; i < 4; ++i) {
    workers_.emplace_back([this] {
      const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      for (;;) {
        std::function<void()> task;
        {
          std::unique_lock<std::mutex> lock(mutex_);
          ready_.wait(lock, [this] { return stopped_ || !pending_.empty(); });
          if (stopped_) break;
          task = std::move(pending_.front());
          pending_.pop_front();
        }
        task();
      }
      if (SUCCEEDED(com)) CoUninitialize();
    });
  }
}

WorkerPool::~WorkerPool() { Stop(); }

void WorkerPool::Submit(std::function<void()> work) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) return;
    pending_.push_back(std::move(work));
  }
  ready_.notify_one();
}

void WorkerPool::Stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopped_ = true;
    pending_.clear();
  }
  ready_.notify_all();
  for (auto& worker : workers_) if (worker.joinable()) worker.join();
  workers_.clear();
}

WindowsPlatform::WindowsPlatform(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window), sharing_enabled_(ReadSharingEnabled()),
      dispatcher_(std::make_shared<UiDispatcher>(window)),
      storage_(std::make_shared<WindowsStorage>()),
      discovery_(std::make_unique<LanDiscovery>(dispatcher_, [this](const Map& event) {
        if (discovery_sink_) discovery_sink_->Success(Value(event));
      })) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  methods_ = std::make_unique<flutter::MethodChannel<Value>>(messenger, "tamayura/platform", codec);
  methods_->SetMethodCallHandler([this](const auto& call, auto result) {
    Handle(call, std::move(result));
  });
  discovery_channel_ = std::make_unique<flutter::EventChannel<Value>>(
      messenger, "tamayura/discovery", codec);
  discovery_channel_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink) {
        discovery_sink_ = std::move(sink);
        discovery_->Replay();
        return std::unique_ptr<flutter::StreamHandlerError<Value>>();
      }, [this](const Value*) {
        discovery_sink_.reset();
        return std::unique_ptr<flutter::StreamHandlerError<Value>>();
      }));
  sharing_channel_ = std::make_unique<flutter::EventChannel<Value>>(
      messenger, "tamayura/sharing", codec);
  sharing_channel_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink) {
        sharing_sink_ = std::move(sink);
        sharing_sink_->Success(Value(SharingStatus()));
        return std::unique_ptr<flutter::StreamHandlerError<Value>>();
      }, [this](const Value*) {
        sharing_sink_.reset();
        return std::unique_ptr<flutter::StreamHandlerError<Value>>();
      }));
}

WindowsPlatform::~WindowsPlatform() {
  methods_->SetMethodCallHandler(nullptr);
  discovery_->Stop();
  // Invalidate all active scans before joining the bounded worker pool.
  storage_->Handle("clearSharedDirectory", {}, window_);
  dispatcher_->Shutdown();
  workers_.Stop();
  discovery_channel_->SetStreamHandler(nullptr);
  sharing_channel_->SetStreamHandler(nullptr);
}

Map WindowsPlatform::SharingStatus() const {
  return {{Value("enabled"), Value(sharing_enabled_)},
          {Value("running"), Value(sharing_enabled_)},
          {Value("batteryExempt"), Value(true)}};
}

void WindowsPlatform::Tick() { discovery_->Sweep(); }

void WindowsPlatform::Background(std::shared_ptr<Result> result,
                                 std::function<Value()> operation) {
  const auto dispatcher = dispatcher_;
  workers_.Submit([dispatcher, result, operation = std::move(operation)] {
    try {
      auto value = operation();
      dispatcher->Post([result, value = std::move(value)] { result->Success(value); });
    } catch (const StorageError& error) {
      const auto code = error.code;
      const std::string message = error.what();
      dispatcher->Post([result, code, message] { result->Error(code, message); });
    } catch (const std::exception& error) {
      const std::string message = error.what();
      dispatcher->Post([result, message] { result->Error("PLATFORM_ERROR", message); });
    } catch (...) {
      dispatcher->Post([result] { result->Error("PLATFORM_ERROR", "Windows 操作失败"); });
    }
  });
}

void WindowsPlatform::Handle(const flutter::MethodCall<Value>& call,
                             std::unique_ptr<Result> owned_result) {
  std::shared_ptr<Result> result(std::move(owned_result));
  Map args;
  if (call.arguments()) {
    if (const auto* map = std::get_if<Map>(call.arguments())) args = *map;
  }
  const auto& method = call.method_name();
  try {
    if (method == "deviceId") {
      result->Success(Value(DeviceId()));
    } else if (method == "localInfo") {
      Background(result, [] { return Value(LanDiscovery::LocalInfo()); });
    } else if (method == "sharingStatus") {
      result->Success(Value(SharingStatus()));
    } else if (method == "setBackgroundSharing") {
      const auto found = args.find(Value("enabled"));
      const auto* enabled = found == args.end() ? nullptr : std::get_if<bool>(&found->second);
      if (!enabled) throw StorageError("INVALID_ARGUMENT", "缺少共享状态");
      const DWORD value = *enabled ? 1 : 0;
      WriteSetting(L"BackgroundSharing", REG_DWORD, &value, sizeof(value));
      sharing_enabled_ = *enabled;
      const auto status = Value(SharingStatus());
      if (sharing_sink_) sharing_sink_->Success(status);
      result->Success(status);
    } else if (method == "startDiscovery") {
      const auto found = args.find(Value("port"));
      int64_t port = 0;
      if (found != args.end()) {
        if (auto value = std::get_if<int32_t>(&found->second)) port = *value;
        if (auto value = std::get_if<int64_t>(&found->second)) port = *value;
      }
      if (port < 1 || port > 65535) throw StorageError("INVALID_ARGUMENT", "无效的服务端口");
      discovery_->Start(ArgumentString(args, "id"), ArgumentString(args, "name"),
                        static_cast<uint16_t>(port));
      result->Success();
    } else if (method == "stopDiscovery") {
      discovery_->Stop();
      result->Success();
    } else if (method == "setTransferActivity" || method == "openBatteryOptimizationSettings" ||
               method == "scheduleTransfer" || method == "cancelTransfer") {
      result->Success();
    } else if (method == "scheduledTransferIds") {
      result->Success(Value(flutter::EncodableList{}));
    } else {
      static const std::set<std::string> storage_methods{
          "pickDirectory", "validateSharedDirectory", "scanDirectoriesMetadata",
          "clearSharedDirectory", "thumbnail", "readPreview", "readRange", "saveDownload",
          "temporaryDirectory", "transferDirectory", "databaseDirectory", "open", "share"};
      if (!storage_methods.count(method)) {
        result->NotImplemented();
        return;
      }
      if (method == "pickDirectory" || method == "open" || method == "share" ||
          method == "clearSharedDirectory") {
        result->Success(storage_->Handle(method, args, window_));
      } else {
        if (method == "scanDirectoriesMetadata") {
          args[Value("__generation")] = Value(static_cast<int64_t>(storage_->BeginScan()));
        }
        const auto storage = storage_;
        const HWND window = window_;
        Background(result, [storage, method, args, window] {
          return storage->Handle(method, args, window);
        });
      }
    }
  } catch (const StorageError& error) {
    result->Error(error.code, error.what());
  } catch (const std::exception& error) {
    result->Error("PLATFORM_ERROR", error.what());
  }
}
}  // namespace tamayura
