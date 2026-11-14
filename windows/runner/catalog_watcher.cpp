#include "catalog_watcher.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <mutex>
#include <set>
#include <thread>

namespace tamayura {
namespace {
constexpr size_t kNotifyHeader = offsetof(FILE_NOTIFY_INFORMATION, FileName);
constexpr DWORD kNotifyBytes = 64 * 1024;

[[noreturn]] void WatchError(DWORD code) {
  throw StorageError("CATALOG_WATCH_UNAVAILABLE",
                     "Cannot monitor the shared folders (Windows " +
                         std::to_string(code) + ")");
}

bool SameName(const std::wstring& left, const std::wstring& right) {
  return CompareStringOrdinal(left.c_str(), static_cast<int>(left.size()),
                              right.c_str(), static_cast<int>(right.size()),
                              TRUE) == CSTR_EQUAL;
}

Handle OpenWatchDirectory(const std::wstring& path) {
  Handle directory(CreateFileW((L"\\\\?\\" + path).c_str(),
      FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT |
                         FILE_FLAG_OVERLAPPED, nullptr));
  if (directory.get() == INVALID_HANDLE_VALUE) WatchError(GetLastError());
  FILE_ATTRIBUTE_TAG_INFO info{};
  if (!GetFileInformationByHandleEx(directory.get(), FileAttributeTagInfo,
                                    &info, sizeof(info))) WatchError(GetLastError());
  if ((info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    WatchError(ERROR_ACCESS_DENIED);
  }
  const DWORD required = GetFinalPathNameByHandleW(directory.get(), nullptr, 0, 0);
  if (required == 0) WatchError(GetLastError());
  std::wstring actual(required, L'\0');
  const DWORD length = GetFinalPathNameByHandleW(directory.get(), actual.data(), required, 0);
  if (length == 0 || length >= required) WatchError(ERROR_INVALID_DATA);
  actual.resize(length);
  // ValidateDirectory checked the whole chain; ensure a replacement between
  // that validation and this permissively shared watch handle did not redirect it.
  if (!SameName(actual, L"\\\\?\\" + path)) WatchError(ERROR_ACCESS_DENIED);
  return directory;
}
}  // namespace

CatalogWatchEvent DecodeCatalogNotifications(const uint8_t* bytes, size_t size,
                                             const std::string& folder_id,
                                             int64_t generation) {
  CatalogWatchEvent result;
  result.generation = generation;
  auto overflow = [&] {
    result.type = CatalogWatchEvent::Type::kOverflow;
    result.error = ERROR_NOTIFY_ENUM_DIR;
    result.changes.clear();
    return result;
  };
  if (!bytes || size == 0 || size > kNotifyBytes) return overflow();
  size_t offset = 0;
  std::set<std::string> seen;
  for (;;) {
    if (size - offset < kNotifyHeader) return overflow();
    DWORD next = 0, action = 0, length = 0;
    std::memcpy(&next, bytes + offset, sizeof(next));
    std::memcpy(&action, bytes + offset + sizeof(DWORD), sizeof(action));
    std::memcpy(&length, bytes + offset + 2 * sizeof(DWORD), sizeof(length));
    if (length == 0 || length % sizeof(wchar_t) != 0 ||
        length > size - offset - kNotifyHeader ||
        action < FILE_ACTION_ADDED || action > FILE_ACTION_RENAMED_NEW_NAME) {
      return overflow();
    }
    std::wstring name(length / sizeof(wchar_t), L'\0');
    std::memcpy(name.data(), bytes + offset + kNotifyHeader, length);
    std::replace(name.begin(), name.end(), L'\\', L'/');
    try {
      const auto relative = Utf8(name);
      RelativeComponents(relative);
      if (seen.insert(relative).second) result.changes.push_back({folder_id, relative});
      if (result.changes.size() > 4096) return overflow();
    } catch (const StorageError&) {
      return overflow();
    }
    if (next == 0) break;
    if (next % sizeof(DWORD) != 0 || next < kNotifyHeader + length ||
        next >= size - offset) return overflow();
    offset += next;
  }
  return result;
}

struct CatalogWatcher::State {
  struct Watch {
    std::string folder_id;
    std::wstring name_filter;
    Handle directory;
    OVERLAPPED overlapped{};
    alignas(DWORD) std::array<uint8_t, kNotifyBytes> buffer{};
  };

  Handle port;
  std::vector<std::unique_ptr<Watch>> watches;
  std::mutex arm_mutex;
  std::atomic<bool> stopping{false};
  size_t pending = 0;  // Only the worker mutates this after startup.
  int64_t generation;
  Emit emit;
  std::thread worker;

  State(int64_t value, Emit callback) : generation(value), emit(std::move(callback)) {
    const auto handle = CreateIoCompletionPort(INVALID_HANDLE_VALUE, nullptr, 0, 1);
    if (!handle) WatchError(GetLastError());
    port = Handle(handle);
  }
  ~State() { Stop(); }

  void Add(const std::wstring& path, const std::string& folder_id,
           const std::wstring& filter = {}) {
    auto watch = std::make_unique<Watch>();
    watch->folder_id = folder_id;
    watch->name_filter = filter;
    watch->directory = OpenWatchDirectory(path);
    if (!CreateIoCompletionPort(watch->directory.get(), port.get(),
                                reinterpret_cast<ULONG_PTR>(watch.get()), 0)) {
      WatchError(GetLastError());
    }
    watches.push_back(std::move(watch));
  }

  DWORD Arm(Watch& watch) {
    std::lock_guard<std::mutex> lock(arm_mutex);
    if (stopping.load()) return ERROR_OPERATION_ABORTED;
    watch.overlapped = {};
    const bool subtree = watch.name_filter.empty();
    const DWORD filters = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
        FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SECURITY |
        (subtree ? FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE : 0);
    if (!ReadDirectoryChangesW(watch.directory.get(), watch.buffer.data(),
                               subtree ? kNotifyBytes : 8192, subtree, filters,
                               nullptr, &watch.overlapped, nullptr)) return GetLastError();
    ++pending;
    return ERROR_SUCCESS;
  }

  void Notify(CatalogWatchEvent event) noexcept {
    if (stopping.load()) return;
    try { emit(std::move(event)); }
    catch (...) { /* Do not unwind through the native I/O completion thread. */ }
  }

  void Run() noexcept {
    while (pending != 0) {
      DWORD bytes = 0;
      ULONG_PTR key = 0;
      OVERLAPPED* operation = nullptr;
      const BOOL success = GetQueuedCompletionStatus(port.get(), &bytes, &key,
                                                     &operation, INFINITE);
      const DWORD error = success ? ERROR_SUCCESS : GetLastError();
      if (!operation) continue;  // Explicit wakeup during cancellation.
      --pending;
      auto& watch = *reinterpret_cast<Watch*>(key);
      if (stopping.load()) continue;
      try {
        CatalogWatchEvent event;
        event.generation = generation;
        if (!success) {
          event.type = error == ERROR_NOTIFY_ENUM_DIR
                           ? CatalogWatchEvent::Type::kOverflow
                           : CatalogWatchEvent::Type::kError;
          event.error = error;
        } else {
          event = DecodeCatalogNotifications(watch.buffer.data(), bytes,
                                              watch.folder_id, generation);
          if (!watch.name_filter.empty() && event.type == CatalogWatchEvent::Type::kChanged) {
            bool root_changed = false;
            for (const auto& change : event.changes) {
              if (SameName(Wide(change.relative_path), watch.name_filter)) root_changed = true;
            }
            event.changes.clear();
            if (root_changed) {
              event.type = CatalogWatchEvent::Type::kOverflow;
              event.error = ERROR_NOTIFY_ENUM_DIR;
            }
          }
        }
        // Re-arm before forwarding events; a slow UI never leaves the next
        // read unqueued. Terminal errors are retried on the next Start request.
        DWORD rearm = ERROR_SUCCESS;
        if (success || error == ERROR_NOTIFY_ENUM_DIR) rearm = Arm(watch);
        if (event.type != CatalogWatchEvent::Type::kChanged || !event.changes.empty()) {
          Notify(std::move(event));
        }
        if (rearm != ERROR_SUCCESS && rearm != ERROR_OPERATION_ABORTED) {
          Notify({CatalogWatchEvent::Type::kError, generation, {}, rearm});
        }
      } catch (...) {
        Notify({CatalogWatchEvent::Type::kError, generation, {}, ERROR_NOT_ENOUGH_MEMORY});
      }
    }
  }

  void Stop() {
    {
      std::lock_guard<std::mutex> lock(arm_mutex);
      stopping.store(true);
      for (const auto& watch : watches) CancelIoEx(watch->directory.get(), nullptr);
    }
    if (worker.joinable()) {
      PostQueuedCompletionStatus(port.get(), 0, 0, nullptr);
      worker.join();
    } else {
      // Startup can fail after some reads were queued but before a worker was
      // created. Those OVERLAPPED buffers still need their cancellation packets.
      Run();
    }
  }
};

CatalogWatcher::CatalogWatcher() = default;
CatalogWatcher::~CatalogWatcher() { Stop(); }

void CatalogWatcher::Start(const std::vector<SharedDirectory>& directories,
                           int64_t generation, Emit emit) {
  Stop();
  if (generation < 1 || !emit) {
    throw StorageError("INVALID_ARGUMENT", "Invalid catalog watch session");
  }
  if (directories.empty()) return;
  auto next = std::make_unique<State>(generation, std::move(emit));
  std::vector<std::wstring> roots;
  std::set<std::string> ids;
  for (const auto& directory : directories) {
    ValidateSegment(directory.id);
    if (!ids.insert(directory.id).second) {
      throw StorageError("INVALID_ARGUMENT", "Duplicate shared folder identifier");
    }
    auto root = ValidateDirectory(directory.uri);
    for (const auto& existing : roots) {
      if (ContainsPath(existing, root) || ContainsPath(root, existing)) {
        throw StorageError("DIR_OVERLAP", "Shared folders overlap");
      }
    }
    roots.push_back(root);
    next->Add(root, directory.id);
    // ReadDirectoryChangesW does not report the watched directory itself.
    // Watch the name of every ancestor too, without enumerating its contents,
    // so moving/deleting the shared root (or its parent) forces a fresh check.
    while (root.size() > 3) {
      const auto slash = root.find_last_of(L'\\');
      const auto name = root.substr(slash + 1);
      root = root.substr(0, slash == 2 ? 3 : slash);
      next->Add(root, directory.id, name);
    }
  }
  for (const auto& watch : next->watches) {
    const DWORD error = next->Arm(*watch);
    if (error != ERROR_SUCCESS) WatchError(error);
  }
  next->worker = std::thread([state = next.get()] { state->Run(); });
  state_ = std::move(next);
}

void CatalogWatcher::Stop() { state_.reset(); }
}  // namespace tamayura
