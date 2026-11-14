#include "windows_platform.h"

#include <flutter/standard_method_codec.h>
#include <flutter/event_stream_handler_functions.h>
#include <objbase.h>

#include <algorithm>
#include <cwctype>
#include <set>

#include "app_text.h"
#include "discovery_core.h"
#include "lan_discovery.h"
#include "windows_storage.h"
#include "windows_update.h"

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
  throw StorageError("INVALID_ARGUMENT", app_text::Utf8(TextId::kMissingArgument) + key);
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
    throw StorageError("SETTINGS_UNAVAILABLE", app_text::Utf8(TextId::kSettingsUnavailable));
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
    throw StorageError("DEVICE_ID_UNAVAILABLE", app_text::Utf8(TextId::kDeviceIdCreateFailed));
  }
  wchar_t text[40]{};
  if (StringFromGUID2(uuid, text, 40) != 39) {
    throw StorageError("DEVICE_ID_UNAVAILABLE", app_text::Utf8(TextId::kDeviceIdReadFailed));
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

// Worker callbacks own this bridge instead of a WindowsPlatform pointer. One
// queued UI action coalesces a burst, bounded at 4096 changed paths; overflow
// explicitly requests a full scan instead of dropping changes silently.
struct CatalogEventDelivery : std::enable_shared_from_this<CatalogEventDelivery> {
  std::unique_ptr<flutter::EventSink<Value>> sink;  // UI thread only.
  std::mutex mutex;
  std::optional<CatalogWatchEvent> pending;
  bool queued = false, closed = false;

  void Post(const std::shared_ptr<UiDispatcher>& dispatcher, CatalogWatchEvent event) {
    bool schedule = false;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (closed) return;
      if (!pending || pending->generation != event.generation) {
        pending = std::move(event);
      } else if (pending->type != CatalogWatchEvent::Type::kError) {
        if (event.type != CatalogWatchEvent::Type::kChanged) {
          pending = std::move(event);
        } else if (pending->type == CatalogWatchEvent::Type::kChanged) {
          std::set<std::pair<std::string, std::string>> paths;
          for (const auto& value : pending->changes) paths.emplace(value.shared_folder_id, value.relative_path);
          for (const auto& value : event.changes) paths.emplace(value.shared_folder_id, value.relative_path);
          pending->changes.clear();
          if (paths.size() > 4096) {
            pending->type = CatalogWatchEvent::Type::kOverflow;
            pending->error = ERROR_NOTIFY_ENUM_DIR;
          } else {
            for (const auto& value : paths) pending->changes.push_back({value.first, value.second});
          }
        }
      }
      if (!queued) queued = schedule = true;
    }
    if (schedule) dispatcher->Post([self = shared_from_this()] { self->Dispatch(); });
  }

  void Dispatch() {
    std::optional<CatalogWatchEvent> event;
    {
      std::lock_guard<std::mutex> lock(mutex);
      queued = false;
      if (closed || !sink) return;
      event.swap(pending);
    }
    if (!event) return;
    const char* type = event->type == CatalogWatchEvent::Type::kChanged ? "changed" :
        event->type == CatalogWatchEvent::Type::kOverflow ? "overflow" : "error";
    Map value{{Value("type"), Value(type)}, {Value("generation"), Value(event->generation)}};
    if (event->type == CatalogWatchEvent::Type::kChanged) {
      flutter::EncodableList changes;
      for (const auto& change : event->changes) {
        changes.emplace_back(Map{{Value("sharedFolderId"), Value(change.shared_folder_id)},
                                 {Value("relativePath"), Value(change.relative_path)}});
      }
      value[Value("changes")] = Value(std::move(changes));
    } else {
      value[Value("code")] = Value(static_cast<int64_t>(event->error));
    }
    sink->Success(Value(value));
  }

  void Close() {
    std::lock_guard<std::mutex> lock(mutex);
    closed = true;
    pending.reset();
    sink.reset();
  }
};

WindowsPlatform::WindowsPlatform(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window), sharing_enabled_(ReadSharingEnabled()),
      dispatcher_(std::make_shared<UiDispatcher>(window)),
      storage_(std::make_shared<WindowsStorage>()),
      discovery_(std::make_unique<LanDiscovery>(
          [dispatcher = dispatcher_](auto action) { dispatcher->Post(std::move(action)); },
          [this](const DiscoveryEvent& event) {
            if (!discovery_sink_) return;
            Map value{{Value("type"), Value(event.type)}};
            if (event.type == "error") {
              value[Value("stage")] = Value(event.stage);
              value[Value("code")] = Value(static_cast<int64_t>(event.code));
              value[Value("message")] = Value(event.message);
            } else {
              value[Value("id")] = Value(event.id);
              value[Value("name")] = Value(event.name);
              value[Value("host")] = Value(event.host);
              value[Value("port")] = Value(static_cast<int32_t>(event.port));
            }
            discovery_sink_->Success(Value(value));
          })), updates_(std::make_shared<WindowsUpdate>()),
      catalog_events_(std::make_shared<CatalogEventDelivery>()) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  methods_ = std::make_unique<flutter::MethodChannel<Value>>(messenger, "tamayura/platform", codec);
  methods_->SetMethodCallHandler([this](const auto& call, auto result) {
    Handle(call, std::move(result));
  });
  update_methods_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "tamayura/updates", codec);
  update_methods_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleUpdate(call, std::move(result));
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
  catalog_channel_ = std::make_unique<flutter::EventChannel<Value>>(
      messenger, "tamayura/catalog", codec);
  catalog_channel_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [events = catalog_events_](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink) {
        events->sink = std::move(sink);
        events->Dispatch();
        return std::unique_ptr<flutter::StreamHandlerError<Value>>();
      }, [events = catalog_events_](const Value*) {
        events->sink.reset();
        return std::unique_ptr<flutter::StreamHandlerError<Value>>();
      }));
}

WindowsPlatform::~WindowsPlatform() {
  methods_->SetMethodCallHandler(nullptr);
  update_methods_->SetMethodCallHandler(nullptr);
  discovery_->Stop();
  // A late queued start cannot resurrect monitoring during destruction. Join
  // its single configuration worker before touching the watcher on this thread.
  ++*catalog_command_;
  catalog_workers_.Stop();
  storage_->StopWatching();
  catalog_events_->Close();
  // Invalidate all active scans before joining the bounded worker pool.
  storage_->Handle("clearSharedDirectory", {}, window_);
  dispatcher_->Shutdown();
  workers_.Stop();
  previews_.Stop();
  discovery_channel_->SetStreamHandler(nullptr);
  sharing_channel_->SetStreamHandler(nullptr);
  catalog_channel_->SetStreamHandler(nullptr);
}

Map WindowsPlatform::SharingStatus() const {
  return {{Value("enabled"), Value(sharing_enabled_)},
          {Value("running"), Value(sharing_enabled_)},
          {Value("batteryExempt"), Value(true)}};
}

void WindowsPlatform::Tick() {
  // A native result may enter a nested message loop and destroy this platform.
  // Keep the dispatcher alive and do not touch members after dispatching it.
  const auto dispatcher = dispatcher_;
  discovery_->Sweep();
  dispatcher->Drain();
}

void WindowsPlatform::Background(std::shared_ptr<Result> result,
                                 std::function<Value()> operation, bool preview) {
  const auto dispatcher = dispatcher_;
  auto& pool = preview ? previews_ : workers_;
  pool.Submit([dispatcher, result, operation = std::move(operation)] {
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
      const auto message = app_text::Utf8(TextId::kOperationFailed);
      dispatcher->Post([result, message] { result->Error("PLATFORM_ERROR", message); });
    }
  });
}

void WindowsPlatform::ConfigureCatalogWatcher(std::shared_ptr<Result> result,
                                              Map arguments, bool start) {
  const auto command = ++*catalog_command_;
  const auto current = catalog_command_;
  const auto dispatcher = dispatcher_;
  const auto storage = storage_;
  const auto events = catalog_events_;
  const bool submitted = catalog_workers_.Submit(
      [current, command, dispatcher, storage, events, result,
       arguments = std::move(arguments), start] {
    const auto cancelled = [dispatcher, result] {
      dispatcher->Post([result] { result->Error("SCAN_CANCELLED", "Catalog watch request superseded"); });
    };
    if (current->load() != command) {
      cancelled();
      return;
    }
    try {
      if (start) {
        storage->StartWatching(arguments,
            [current, command, events, dispatcher](CatalogWatchEvent event) {
              if (current->load() == command) events->Post(dispatcher, std::move(event));
            });
      } else {
        storage->StopWatching();
      }
      if (current->load() != command) {
        // A newer stop/change may arrive while opening a sleeping HDD. Revoke
        // this completed but obsolete start before the next queued command runs.
        storage->StopWatching();
        cancelled();
        return;
      }
      dispatcher->Post([result, current, command] {
        if (current->load() == command) {
          result->Success();
        } else {
          result->Error("SCAN_CANCELLED", "Catalog watch request superseded");
        }
      });
    } catch (const StorageError& error) {
      if (current->load() != command) {
        cancelled();
        return;
      }
      const auto code = error.code;
      const std::string message = error.what();
      dispatcher->Post([result, current, command, code, message] {
        if (current->load() == command) result->Error(code, message);
        else result->Error("SCAN_CANCELLED", "Catalog watch request superseded");
      });
    } catch (...) {
      dispatcher->Post([result, current, command] {
        if (current->load() == command) {
          result->Error("CATALOG_WATCH_UNAVAILABLE", "Cannot configure shared folder monitoring");
        } else {
          result->Error("SCAN_CANCELLED", "Catalog watch request superseded");
        }
      });
    }
  });
  if (!submitted) result->Error("SCAN_CANCELLED", "Catalog monitoring has stopped");
}

void WindowsPlatform::HandleUpdate(const flutter::MethodCall<Value>& call,
                                   std::unique_ptr<Result> owned_result) {
  std::shared_ptr<Result> result(std::move(owned_result));
  try {
    if (call.method_name() == "updateDirectory") {
      result->Success(Value(WindowsUpdate::Directory()));
    } else if (call.method_name() == "installUpdate") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (!args) throw StorageError("INVALID_ARGUMENT", "Missing update arguments.");
      const auto path = ArgumentString(*args, "path");
      const auto sha256 = ArgumentString(*args, "sha256");
      const auto version = ArgumentString(*args, "version");
      int64_t build = 0;
      const auto found = args->find(Value("buildNumber"));
      if (found != args->end()) {
        if (const auto value = std::get_if<int32_t>(&found->second)) build = *value;
        if (const auto value = std::get_if<int64_t>(&found->second)) build = *value;
      }
      const auto updates = updates_;
      Background(result, [updates, path, sha256, version, build] {
        updates->Prepare(path, sha256, version, build);
        return Value("readyToExit");
      });
    } else if (call.method_name() == "exitForUpdate") {
      if (!updates_->prepared()) {
        throw StorageError("UPDATE_NOT_READY", "No update is ready to install.");
      }
      result->Success();
      PostQuitMessage(EXIT_SUCCESS);
    } else {
      result->NotImplemented();
    }
  } catch (const StorageError& error) {
    result->Error(error.code, error.what());
  } catch (const std::exception&) {
    result->Error("UPDATE_ERROR", "The Windows update operation failed. Check file permissions and retry.");
  }
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
      Background(result, [] {
        const auto info = LanDiscovery::LocalInfo();
        flutter::EncodableList addresses;
        for (const auto& address : info.addresses) addresses.emplace_back(address);
        return Value(Map{{Value("name"), Value(info.name)},
                         {Value("addresses"), Value(addresses)}});
      });
    } else if (method == "sharingStatus") {
      result->Success(Value(SharingStatus()));
    } else if (method == "setBackgroundSharing") {
      const auto found = args.find(Value("enabled"));
      const auto* enabled = found == args.end() ? nullptr : std::get_if<bool>(&found->second);
      if (!enabled) {
        throw StorageError("INVALID_ARGUMENT", app_text::Utf8(TextId::kMissingSharingState));
      }
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
      if (port < 1 || port > 65535) {
        throw StorageError("INVALID_ARGUMENT", app_text::Utf8(TextId::kInvalidPort));
      }
      discovery_->Start(ArgumentString(args, "id"), ArgumentString(args, "name"),
                        static_cast<uint16_t>(port));
      result->Success();
    } else if (method == "stopDiscovery") {
      discovery_->Stop();
      result->Success();
    } else if (method == "startWatchingDirectories") {
      ConfigureCatalogWatcher(result, std::move(args), true);
    } else if (method == "stopWatchingDirectories") {
      ConfigureCatalogWatcher(result, {}, false);
    } else if (method == "setLanguage") {
      if (!app_text::SetPreference(ArgumentString(args, "language"))) {
        throw StorageError("INVALID_ARGUMENT", app_text::Utf8(TextId::kInvalidLanguage));
      }
      // The tray refreshes its tooltip; its menu is built in the current language.
      PostMessageW(window_, kLanguageChangedMessage, 0, 0);
      result->Success();
    } else if (method == "setTransferActivity" || method == "openBatteryOptimizationSettings" ||
               method == "scheduleTransfer" || method == "cancelTransfer") {
      result->Success();
    } else if (method == "scheduledTransferIds") {
      result->Success(Value(flutter::EncodableList{}));
    } else {
      static const std::set<std::string> storage_methods{
          "pickDirectory", "validateSharedDirectory", "scanDirectoriesMetadata",
          "restoreDirectoriesMetadata", "getLocalCatalogWarning",
          "scanChangedDirectoriesMetadata",
          "clearSharedDirectory", "thumbnail", "readPreview", "readRange", "saveDownload", "deleteDownload",
          "temporaryDirectory", "transferDirectory", "transferSpace", "databaseDirectory", "open", "share"};
      if (!storage_methods.count(method)) {
        result->NotImplemented();
        return;
      }
      if (method == "clearSharedDirectory") {
        // Revoke file access immediately, then serialize notification teardown
        // behind any in-flight start without blocking the platform event loop.
        storage_->Handle(method, args, window_);
        ConfigureCatalogWatcher(result, {}, false);
      } else if (method == "pickDirectory" || method == "open" || method == "share") {
        result->Success(storage_->Handle(method, args, window_));
      } else {
        if (method == "scanDirectoriesMetadata" || method == "restoreDirectoriesMetadata" ||
            method == "scanChangedDirectoriesMetadata") {
          args[Value("__generation")] = Value(static_cast<int64_t>(storage_->BeginScan(args)));
        }
        const auto storage = storage_;
        const HWND window = window_;
        Background(result, [storage, method, args, window] {
          return storage->Handle(method, args, window);
        }, method == "thumbnail" || method == "readPreview");
      }
    }
  } catch (const StorageError& error) {
    result->Error(error.code, error.what());
  } catch (const std::exception& error) {
    result->Error("PLATFORM_ERROR", error.what());
  }
}
}  // namespace tamayura
