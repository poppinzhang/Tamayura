#include "catalog_watcher.h"

#include <objbase.h>

#include <chrono>
#include <condition_variable>
#include <cstring>
#include <filesystem>
#include <functional>
#include <iostream>
#include <mutex>

namespace {
using namespace tamayura;
using namespace std::chrono_literals;

void Expect(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

struct Fixture {
  std::wstring base, root;
  SharedDirectory shared;
  Fixture() {
    wchar_t temporary[MAX_PATH]{};
    Expect(GetTempPathW(MAX_PATH, temporary) != 0, "Get temporary directory");
    GUID guid{};
    wchar_t text[40]{};
    Expect(SUCCEEDED(CoCreateGuid(&guid)) && StringFromGUID2(guid, text, 40) == 39,
           "Create fixture identifier");
    base = JoinPath(temporary, std::wstring(L"tamayura-watch-") + text);
    root = JoinPath(base, L"photos");
    std::filesystem::create_directories(JoinPath(root, L"nested"));
    shared = {"photos", Utf8(root), "Photos"};
  }
  ~Fixture() {
    std::error_code ignored;
    std::filesystem::remove_all(std::wstring(L"\\\\?\\") + base, ignored);
  }
  void Write(const std::wstring& relative) const {
    const auto path = std::wstring(L"\\\\?\\") + JoinPath(root, relative);
    Handle file(CreateFileW(path.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    Expect(file.get() != INVALID_HANDLE_VALUE, "Create a watched file");
    const uint8_t content[] = {1, 2, 3};
    DWORD written = 0;
    Expect(WriteFile(file.get(), content, sizeof(content), &written, nullptr) &&
               written == sizeof(content), "Write a watched file");
  }
};

struct Events {
  std::mutex mutex;
  std::condition_variable ready;
  std::vector<CatalogWatchEvent> values;
  void Add(CatalogWatchEvent event) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      values.push_back(std::move(event));
    }
    ready.notify_all();
  }
  void Wait(const std::function<bool(const std::vector<CatalogWatchEvent>&)>& predicate) {
    std::unique_lock<std::mutex> lock(mutex);
    Expect(ready.wait_for(lock, 8s, [&] { return predicate(values); }),
           "Timed out waiting for the expected directory notification");
  }
  void Path(const std::string& path, int64_t generation) {
    Wait([&](const auto& events) {
      for (const auto& event : events) {
        if (event.generation != generation) continue;
        for (const auto& change : event.changes) {
          if (change.relative_path == path) return true;
        }
      }
      return false;
    });
  }
};

Bytes Notifications(const std::vector<std::pair<DWORD, std::wstring>>& entries) {
  Bytes bytes;
  for (size_t i = 0; i < entries.size(); ++i) {
    const auto& [action, name] = entries[i];
    const DWORD name_bytes = static_cast<DWORD>(name.size() * sizeof(wchar_t));
    const DWORD record_bytes = (12 + name_bytes + 3) & ~DWORD{3};
    const DWORD next = i + 1 == entries.size() ? 0 : record_bytes;
    const auto offset = bytes.size();
    bytes.resize(offset + record_bytes);
    std::memcpy(bytes.data() + offset, &next, sizeof(next));
    std::memcpy(bytes.data() + offset + 4, &action, sizeof(action));
    std::memcpy(bytes.data() + offset + 8, &name_bytes, sizeof(name_bytes));
    std::memcpy(bytes.data() + offset + 12, name.data(), name_bytes);
  }
  return bytes;
}

bool Overflow(const Bytes& bytes) {
  const auto event = DecodeCatalogNotifications(bytes.data(), bytes.size(), "photos", 7);
  return event.type == CatalogWatchEvent::Type::kOverflow && event.changes.empty() &&
      event.generation == 7;
}
}  // namespace

int main() {
  unsigned passed = 0;
  auto test = [&](const char* name, const std::function<void()>& action) {
    action();
    ++passed;
    std::cout << "PASS " << name << '\n';
  };
  try {
    test("notification decoding preserves rename pairs and deduplicates paths", [&] {
      const auto bytes = Notifications({{FILE_ACTION_RENAMED_OLD_NAME, L"nested\\old.jpg"},
          {FILE_ACTION_RENAMED_NEW_NAME, L"nested\\新しい.jpg"},
          {FILE_ACTION_MODIFIED, L"nested\\新しい.jpg"}});
      const auto event = DecodeCatalogNotifications(bytes.data(), bytes.size(), "photos", 3);
      Expect(event.type == CatalogWatchEvent::Type::kChanged, "A valid batch is changed");
      Expect(event.generation == 3 && event.changes.size() == 2, "Preserve session and unique paths");
      Expect(event.changes[0].relative_path == "nested/old.jpg" &&
                 event.changes[1].relative_path == "nested/新しい.jpg", "Normalize relative separators");
      Expect(event.changes[0].shared_folder_id == "photos", "Preserve shared folder identity");
    });
    test("overflow and malformed records require a complete scan", [&] {
      Expect(Overflow({}), "An empty Windows buffer means lost events");
      Expect(Overflow({1, 2, 3}), "A truncated header is not a change set");
      auto bytes = Notifications({{FILE_ACTION_ADDED, L"photo.jpg"}});
      bytes.resize(14);
      Expect(Overflow(bytes), "Truncated names must not be emitted");
      bytes = Notifications({{FILE_ACTION_ADDED, L"photo.jpg"}});
      bytes[8] = 3;
      Expect(Overflow(bytes), "Odd UTF-16 name byte lengths are invalid");
      bytes = Notifications({{FILE_ACTION_ADDED, L"a.jpg"}, {FILE_ACTION_ADDED, L"b.jpg"}});
      bytes[0] = 1;
      Expect(Overflow(bytes), "Unaligned or backward offsets are invalid");
      Expect(Overflow(Notifications({{99, L"a.jpg"}})), "Unknown actions require a full scan");
      Expect(Overflow(Notifications({{FILE_ACTION_ADDED, L"..\\outside.jpg"}})),
             "Traversal names must never become local paths");
      Expect(Overflow(Notifications({{FILE_ACTION_ADDED, L"C:\\outside.jpg"}})),
             "Absolute names must never become local paths");
    });
    test("first reads are active before Start returns and include nested changes", [&] {
      Fixture fixture;
      Events events;
      CatalogWatcher watcher;
      watcher.Start({fixture.shared}, 10, [&](auto event) { events.Add(std::move(event)); });
      fixture.Write(L"nested\\追加.jpg");
      events.Path("nested/追加.jpg", 10);
      fixture.Write(L"second.jpg");
      events.Path("second.jpg", 10);
      watcher.Stop();
    });
    test("rename and delete notifications retain the old and new locations", [&] {
      Fixture fixture;
      fixture.Write(L"old.jpg");
      Events events;
      CatalogWatcher watcher;
      watcher.Start({fixture.shared}, 11, [&](auto event) { events.Add(std::move(event)); });
      const auto old_path = JoinPath(fixture.root, L"old.jpg");
      const auto new_path = JoinPath(fixture.root, L"nested\\new.jpg");
      Expect(MoveFileW(old_path.c_str(), new_path.c_str()) != FALSE, "Rename watched file");
      events.Path("old.jpg", 11);
      events.Path("nested/new.jpg", 11);
      {
        std::lock_guard<std::mutex> lock(events.mutex);
        events.values.clear();
      }
      Expect(DeleteFileW(new_path.c_str()) != FALSE, "Delete watched file");
      events.Path("nested/new.jpg", 11);
      watcher.Stop();
    });
    test("moving a shared root forces a complete check", [&] {
      Fixture fixture;
      Events events;
      CatalogWatcher watcher;
      watcher.Start({fixture.shared}, 12, [&](auto event) { events.Add(std::move(event)); });
      const auto moved = JoinPath(fixture.base, L"renamed");
      Expect(MoveFileW(fixture.root.c_str(), moved.c_str()) != FALSE,
             "Monitoring must not prevent directory moves");
      events.Wait([](const auto& values) {
        for (const auto& event : values) {
          if (event.generation == 12 && event.type != CatalogWatchEvent::Type::kChanged) return true;
        }
        return false;
      });
      watcher.Stop();
    });
    test("ancestor moves are detected when supported and Stop releases every handle", [&] {
      Fixture fixture;
      const auto previous = JoinPath(fixture.base, L"container");
      const auto moved = JoinPath(fixture.base, L"moved");
      std::filesystem::create_directory(previous);
      const auto nested_root = JoinPath(previous, L"photos");
      Expect(MoveFileW(fixture.root.c_str(), nested_root.c_str()) != FALSE,
             "Prepare the watched ancestor");
      fixture.root = nested_root;
      fixture.shared.uri = Utf8(nested_root);
      Events events;
      CatalogWatcher watcher;
      watcher.Start({fixture.shared}, 13, [&](auto event) { events.Add(std::move(event)); });
      if (!MoveFileW(previous.c_str(), moved.c_str())) {
        const auto error = GetLastError();
        Expect(error == ERROR_ACCESS_DENIED || error == ERROR_SHARING_VIOLATION,
               "Only the filesystem's open-descendant restriction can block the move");
        // NTFS may reject moving a directory with an open descendant, even
        // with FILE_SHARE_DELETE. Stopping sharing must release all such handles.
        watcher.Stop();
        if (!MoveFileW(previous.c_str(), moved.c_str())) {
          const auto stopped_error = GetLastError();
          throw std::runtime_error("Stopped monitoring still blocks an ancestor move (Windows " +
                                   std::to_string(stopped_error) + ")");
        }
        return;
      }
      events.Wait([](const auto& values) {
        for (const auto& event : values) {
          if (event.generation == 13 && event.type != CatalogWatchEvent::Type::kChanged) return true;
        }
        return false;
      });
      watcher.Stop();
    });
    test("multiple roots share one session and restart replaces old watches", [&] {
      Fixture first, second;
      second.shared.id = "second";
      Events events;
      CatalogWatcher watcher;
      watcher.Start({first.shared, second.shared}, 20,
                    [&](auto event) { events.Add(std::move(event)); });
      first.Write(L"a.jpg");
      second.Write(L"b.jpg");
      events.Path("a.jpg", 20);
      events.Path("b.jpg", 20);
      watcher.Start({second.shared}, 21, [&](auto event) { events.Add(std::move(event)); });
      first.Write(L"removed-root.jpg");
      second.Write(L"current.jpg");
      events.Path("current.jpg", 21);
      watcher.Stop();
      for (const auto& event : events.values) {
        if (event.generation != 21) continue;
        for (const auto& change : event.changes) {
          Expect(change.shared_folder_id == "second", "Old root cannot send new-session changes");
        }
      }
    });
    test("idle cancellation and repeated starts release all handles promptly", [&] {
      Fixture fixture;
      CatalogWatcher watcher;
      DWORD before = 0, after = 0;
      Expect(GetProcessHandleCount(GetCurrentProcess(), &before) != FALSE, "Count initial handles");
      const auto started = std::chrono::steady_clock::now();
      unsigned calls = 0;
      for (int64_t generation = 1; generation <= 25; ++generation) {
        watcher.Start({fixture.shared}, generation, [&](auto) { ++calls; });
        watcher.Stop();
      }
      Expect(std::chrono::steady_clock::now() - started < 5s, "Idle cancellation does not block");
      Expect(GetProcessHandleCount(GetCurrentProcess(), &after) != FALSE, "Count final handles");
      Expect(after <= before + 2, "Repeated sessions must not leak directory or IOCP handles");
      Expect(calls == 0, "Idle reads and canceled reads do not produce notifications");
      watcher.Stop();
    });
    test("invalid roots fail startup and leave the watcher reusable", [&] {
      Fixture fixture;
      CatalogWatcher watcher;
      SharedDirectory missing{"missing", Utf8(JoinPath(fixture.base, L"missing")), "Missing"};
      bool failed = false;
      try { watcher.Start({fixture.shared, missing}, 30, [](auto) {}); }
      catch (const StorageError&) { failed = true; }
      Expect(failed, "Unreadable roots must not silently leave an incomplete watcher");
      Events events;
      watcher.Start({fixture.shared}, 31, [&](auto event) { events.Add(std::move(event)); });
      fixture.Write(L"recovered.jpg");
      events.Path("recovered.jpg", 31);
      watcher.Stop();
    });
    std::cout << passed << " catalog watcher tests passed\n";
    return EXIT_SUCCESS;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
