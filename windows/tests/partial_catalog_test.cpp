#include "storage_core.h"

#include <objbase.h>
#include <winioctl.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <filesystem>
#include <functional>
#include <iostream>
#include <set>

namespace {
using namespace tamayura;

void Expect(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void Reject(const std::string& code, const std::function<void()>& action) {
  try { action(); }
  catch (const StorageError& error) {
    Expect(error.code == code, ("Unexpected error: " + error.code).c_str());
    return;
  }
  throw std::runtime_error("Expected failure");
}

void Write(const std::wstring& path, const Bytes& bytes = {1, 2, 3}) {
  std::filesystem::create_directories(std::filesystem::path(path).parent_path());
  Handle file(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                          FILE_ATTRIBUTE_NORMAL, nullptr));
  Expect(file.get() != INVALID_HANDLE_VALUE, "Create fixture file");
  DWORD written = 0;
  Expect(WriteFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) &&
             written == bytes.size(), "Write fixture file");
}

Bytes Read(const std::wstring& path) {
  auto file = SafeFile::Open(path);
  const auto size = file.info().size;
  return file.Read(0, size, size);
}

std::array<DWORD, 3> FileIdentity(const std::wstring& path) {
  auto file = SafeFile::Open(path);
  BY_HANDLE_FILE_INFORMATION info{};
  Expect(GetFileInformationByHandle(file.handle(), &info) != FALSE, "Read fixture file identity");
  return {info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow};
}

std::set<std::string> Paths(const std::vector<MediaEntry>& entries) {
  std::set<std::string> paths;
  for (const auto& entry : entries) {
    Expect(paths.insert(entry.relative_path).second, "No duplicated catalog path");
  }
  return paths;
}

Handle Exclusive(const std::wstring& path) {
  Handle file(CreateFileW(path.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL, nullptr));
  Expect(file.get() != INVALID_HANDLE_VALUE, "Lock fixture file exclusively");
  return file;
}

// Mount-point reparse records do not require symbolic-link privileges.
void Junction(const std::wstring& link, const std::wstring& target) {
  Expect(CreateDirectoryW(link.c_str(), nullptr) != FALSE, "Create junction directory");
  Handle directory(CreateFileW(link.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                               FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr));
  Expect(directory.get() != INVALID_HANDLE_VALUE, "Open junction directory");
  const std::wstring substitute = L"\\??\\" + target;
  const size_t path_size = (substitute.size() + target.size() + 2) * sizeof(wchar_t);
  std::vector<uint8_t> buffer(16 + path_size, 0);
  const DWORD tag = IO_REPARSE_TAG_MOUNT_POINT;
  const WORD data_length = static_cast<WORD>(8 + path_size);
  const WORD substitute_length = static_cast<WORD>(substitute.size() * sizeof(wchar_t));
  const WORD print_offset = static_cast<WORD>((substitute.size() + 1) * sizeof(wchar_t));
  const WORD print_length = static_cast<WORD>(target.size() * sizeof(wchar_t));
  memcpy(buffer.data(), &tag, sizeof(tag));
  memcpy(buffer.data() + 4, &data_length, sizeof(data_length));
  memcpy(buffer.data() + 10, &substitute_length, sizeof(substitute_length));
  memcpy(buffer.data() + 12, &print_offset, sizeof(print_offset));
  memcpy(buffer.data() + 14, &print_length, sizeof(print_length));
  memcpy(buffer.data() + 16, substitute.data(), substitute_length);
  memcpy(buffer.data() + 16 + print_offset, target.data(), print_length);
  DWORD returned = 0;
  Expect(DeviceIoControl(directory.get(), FSCTL_SET_REPARSE_POINT, buffer.data(),
                          static_cast<DWORD>(buffer.size()), nullptr, 0, &returned, nullptr) != FALSE,
         "Set junction reparse record");
}

struct Fixture {
  std::wstring base, root, cache;
  SharedDirectory shared;
  Fixture() {
    wchar_t temporary[MAX_PATH]{};
    GUID guid{};
    wchar_t identity[40]{};
    Expect(GetTempPathW(MAX_PATH, temporary) != 0 && SUCCEEDED(CoCreateGuid(&guid)) &&
               StringFromGUID2(guid, identity, 40) == 39, "Create isolated fixture");
    base = JoinPath(temporary, std::wstring(L"tamayura-partial-catalog-") + identity);
    root = JoinPath(base, L"shared");
    cache = JoinPath(base, L"catalog.bin");
    std::filesystem::create_directories(root);
    shared = {"photos", Utf8(root), "Photos"};
  }
  ~Fixture() {
    std::error_code ignored;
    std::filesystem::remove_all(base, ignored);
  }
  std::wstring Path(const std::string& relative) const {
    auto path = root;
    for (const auto& part : RelativeComponents(relative)) path = JoinPath(path, Wide(part));
    return path;
  }
  void Add(const std::string& relative, const Bytes& bytes = {1, 2, 3}) const {
    Write(Path(relative), bytes);
  }
  std::vector<MediaEntry> Scan(MediaCatalog& catalog) const {
    return catalog.Scan({shared}, catalog.BeginScan({shared.id}), cache);
  }
  std::vector<MediaEntry> Update(MediaCatalog& catalog,
                                 const std::vector<std::string>& paths) const {
    std::vector<CatalogChange> changes;
    for (const auto& path : paths) changes.push_back({shared.id, path});
    return catalog.ScanChanges({shared}, changes, catalog.BeginScan({shared.id}), cache);
  }
  std::vector<MediaEntry> Restore(MediaCatalog& catalog) const {
    auto restored = catalog.Restore({shared}, catalog.BeginScan({shared.id}), cache);
    Expect(restored.has_value(), "Restore a complete persisted catalog");
    return *restored;
  }
  std::string Id(const std::string& relative) const { return StableMediaId(shared.id, relative); }
};
}  // namespace

int main() {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  struct ComGuard { HRESULT value; ~ComGuard() { if (SUCCEEDED(value)) CoUninitialize(); } } guard{com};
  unsigned passed = 0;
  auto test = [&](const char* name, const std::function<void()>& action) {
    action();
    ++passed;
    std::cout << "PASS " << name << '\n';
  };
  try {
    test("a partial scan requires a complete matching baseline", [&] {
      Fixture fixture;
      fixture.Add("a.jpg");
      MediaCatalog catalog;
      Reject("LOCAL_CATALOG_UNAVAILABLE", [&] { fixture.Update(catalog, {"a.jpg"}); });
      Expect(!std::filesystem::exists(fixture.cache), "No partial cache is published on first use");
      fixture.Scan(catalog);
      auto changed = fixture.shared;
      changed.name = "Changed";
      Reject("LOCAL_CATALOG_UNAVAILABLE", [&] {
        catalog.ScanChanges({changed}, {{changed.id, "a.jpg"}}, catalog.BeginScan({changed.id}), fixture.cache);
      });
      catalog.Clear();
      Reject("LOCAL_CATALOG_UNAVAILABLE", [&] { fixture.Update(catalog, {"a.jpg"}); });
    });

    test("adding a photo never opens unchanged media and persists the complete result", [&] {
      Fixture fixture;
      fixture.Add("old.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      auto locked = Exclusive(fixture.Path("old.jpg"));
      fixture.Add("new.jpg", {4, 5});
      const auto result = fixture.Update(catalog, {"new.jpg"});
      Expect(Paths(result) == std::set<std::string>{"old.jpg", "new.jpg"}, "Keep locked unchanged media");
      Expect(!catalog.CatalogWarning(), "Partial result persisted successfully");
      MediaCatalog restarted;
      Expect(Paths(fixture.Restore(restarted)) == Paths(result), "Restart retains all partial changes");
      locked.reset();
      Expect(restarted.Read(fixture.Id("old.jpg"), 0, 3) == Bytes({1, 2, 3}), "Unchanged item still downloadable");
      Expect(restarted.Read(fixture.Id("new.jpg"), 0, 2) == Bytes({4, 5}), "New item downloadable");
    });

    test("an empty restored baseline supports the first changed item", [&] {
      Fixture fixture;
      MediaCatalog first;
      Expect(fixture.Scan(first).empty(), "Complete empty baseline");
      MediaCatalog restarted;
      Expect(fixture.Restore(restarted).empty(), "Restore empty baseline");
      fixture.Add("first.jpg");
      Expect(Paths(fixture.Update(restarted, {"first.jpg"})) == std::set<std::string>{"first.jpg"},
             "Apply first event to an empty catalog");
    });

    test("index writes inside a shared root and non-media hints cannot create a rewrite loop", [&] {
      Fixture fixture;
      fixture.cache = JoinPath(fixture.root, L"local-catalog.bin");
      fixture.Add("photo.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto identity = FileIdentity(fixture.cache);
      for (unsigned index = 0; index < 5; ++index) {
        fixture.Add("notes.txt", Bytes(index + 1, 7));
        const auto result = fixture.Update(catalog, {"local-catalog.bin", "notes.txt", "removed-temporary.tmp"});
        Expect(Paths(result) == std::set<std::string>{"photo.jpg"}, "Unrelated hints keep the complete catalog");
        Expect(FileIdentity(fixture.cache) == identity, "No atomic replacement for unchanged media");
        Expect(!catalog.CatalogWarning(), "An unchanged catalog does not attempt another cache write");
      }
      fixture.Add("new.jpg");
      Expect(fixture.Update(catalog, {"new.jpg"}).size() == 2, "Actual media additions still publish");
      Expect(FileIdentity(fixture.cache) != identity, "An actual change replaces the cache atomically");
      MediaCatalog restarted;
      Expect(fixture.Restore(restarted).size() == 2, "The changed catalog remains persistent");
    });

    test("unchanged media and subtree hints leave the persistent index untouched", [&] {
      Fixture fixture;
      fixture.Add("trip/a.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto identity = FileIdentity(fixture.cache);
      auto locked_cache = Exclusive(fixture.cache);
      Expect(fixture.Update(catalog, {"trip/a.jpg"}).size() == 1, "Unchanged media hint succeeds");
      Expect(!catalog.CatalogWarning(), "Unchanged hint does not open even a locked cache file");
      Expect(fixture.Update(catalog, {"trip"}).size() == 1, "Unchanged subtree hint succeeds");
      Expect(!catalog.CatalogWarning(), "Unchanged subtree also avoids cache I/O");
      locked_cache.reset();
      Expect(FileIdentity(fixture.cache) == identity, "Repeated unchanged hints do not replace the index");
    });

    test("deletions match full path boundaries and keep siblings", [&] {
      Fixture fixture;
      for (const auto& path : {"trip/a.jpg", "trip2/b.jpg", "photo.jpg", "photo.jpg.extra.jpg"}) fixture.Add(path);
      MediaCatalog catalog;
      fixture.Scan(catalog);
      std::filesystem::remove_all(fixture.Path("trip"));
      std::filesystem::remove(fixture.Path("photo.jpg"));
      const auto result = fixture.Update(catalog, {"trip", "photo.jpg"});
      Expect(Paths(result) == std::set<std::string>{"trip2/b.jpg", "photo.jpg.extra.jpg"},
             "Removing a path must not remove similarly named siblings");
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(fixture.Id("trip/a.jpg"), 0, 1); });
    });

    test("directory additions and moves rebuild only the affected subtrees", [&] {
      Fixture fixture;
      fixture.Add("unchanged.jpg");
      fixture.Add("old/child/a.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      auto locked = Exclusive(fixture.Path("unchanged.jpg"));
      std::filesystem::rename(fixture.Path("old"), fixture.Path("moved"));
      fixture.Add("new/deep/b.jpg");
      const auto result = fixture.Update(catalog, {"old", "moved", "moved/child/a.jpg", "new/deep/b.jpg", "new", "new"});
      Expect(Paths(result) == std::set<std::string>{"unchanged.jpg", "moved/child/a.jpg", "new/deep/b.jpg"},
             "Merge overlapping events and remove old subtree identity");
      Expect(catalog.Read(fixture.Id("moved/child/a.jpg"), 0, 3) == Bytes({1, 2, 3}), "Moved item readable");
    });

    test("file changes and case-only renames replace previous metadata", [&] {
      Fixture fixture;
      fixture.Add("a.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      fixture.Add("a.jpg", {6, 7, 8, 9});
      std::filesystem::rename(fixture.Path("a.jpg"), fixture.Path("A.jpg"));
      const auto result = fixture.Update(catalog, {"a.jpg", "A.jpg"});
      Expect(Paths(result) == std::set<std::string>{"A.jpg"}, "Keep the actual renamed item once");
      Expect(result.front().size == 4, "Refresh changed size");
    });

    test("a missing descendant ancestor is treated as absent rather than an I/O failure", [&] {
      Fixture fixture;
      fixture.Add("gone/nested/a.jpg");
      fixture.Add("stay.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      std::filesystem::remove_all(fixture.Path("gone"));
      Expect(Paths(fixture.Update(catalog, {"gone/nested/a.jpg"})) == std::set<std::string>{"stay.jpg"},
             "Deleted ancestor makes the changed media absent");
    });

    test("locked changed files do not publish deletions or replace the saved catalog", [&] {
      Fixture fixture;
      fixture.Add("locked.jpg");
      fixture.Add("stay.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto saved = Read(fixture.cache);
      auto locked = Exclusive(fixture.Path("locked.jpg"));
      fixture.Add("new.jpg");
      Reject("PERMISSION_LOST", [&] { fixture.Update(catalog, {"new.jpg", "locked.jpg"}); });
      Expect(Read(fixture.cache) == saved, "Failed batch keeps original cache bytes");
      Expect(catalog.Read(fixture.Id("stay.jpg"), 0, 3) == Bytes({1, 2, 3}), "Failure retains previous snapshot");
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(fixture.Id("new.jpg"), 0, 1); });
      locked.reset();
      Expect(fixture.Update(catalog, {"new.jpg", "locked.jpg"}).size() == 3, "Failed batch can retry");
    });

    test("an unreadable descendant aborts a directory batch without deleting indexed children", [&] {
      Fixture fixture;
      fixture.Add("trip/locked.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto saved = Read(fixture.cache);
      auto locked = Exclusive(fixture.Path("trip/locked.jpg"));
      fixture.Add("trip/new.jpg");
      Reject("PERMISSION_LOST", [&] { fixture.Update(catalog, {"trip"}); });
      Expect(Read(fixture.cache) == saved, "Strict subtree reconciliation keeps the prior catalog");
      locked.reset();
      Expect(catalog.Read(fixture.Id("trip/locked.jpg"), 0, 3) == Bytes({1, 2, 3}), "Old subtree remains available");
    });

    test("missing shared roots are never interpreted as deleted contents", [&] {
      Fixture fixture;
      fixture.Add("a.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto saved = Read(fixture.cache);
      const auto moved = JoinPath(fixture.base, L"offline");
      std::filesystem::rename(fixture.root, moved);
      Reject("FILE_NOT_FOUND", [&] { fixture.Update(catalog, {"a.jpg"}); });
      Expect(Read(fixture.cache) == saved, "Root failure keeps the persistent snapshot");
      std::filesystem::rename(moved, fixture.root);
      Expect(catalog.Read(fixture.Id("a.jpg"), 0, 3) == Bytes({1, 2, 3}), "Access can recover without losing the index");
    });

    test("invalid hints cannot escape the shared root or change the cache", [&] {
      Fixture fixture;
      fixture.Add("a.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto saved = Read(fixture.cache);
      for (const auto& path : {"../a.jpg", "/a.jpg", "sub\\a.jpg", "sub//a.jpg", "CON.jpg"}) {
        Reject("INVALID_ARGUMENT", [&] { fixture.Update(catalog, {path}); });
      }
      Reject("INVALID_ARGUMENT", [&] {
        catalog.ScanChanges({fixture.shared}, {{"unknown", "a.jpg"}},
                            catalog.BeginScan({fixture.shared.id}), fixture.cache);
      });
      Expect(Read(fixture.cache) == saved, "Invalid hints preserve persistent state");
    });

    test("changed junctions and hidden directories cannot import excluded media", [&] {
      Fixture fixture;
      fixture.Add("stay.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto outside = JoinPath(fixture.base, L"outside");
      Write(JoinPath(outside, L"secret.jpg"));
      const auto junction = fixture.Path("escape");
      Junction(junction, outside);
      fixture.Add("hidden/a.jpg");
      Expect(SetFileAttributesW(fixture.Path("hidden").c_str(), FILE_ATTRIBUTE_HIDDEN) != FALSE,
             "Mark hidden directory");
      const auto result = fixture.Update(catalog, {"escape/secret.jpg", "escape", "hidden/a.jpg"});
      Expect(Paths(result) == std::set<std::string>{"stay.jpg"}, "Exclude reparse and hidden ancestry");
      Expect(RemoveDirectoryW(junction.c_str()) != FALSE, "Remove fixture junction");
      Expect(Read(JoinPath(outside, L"secret.jpg")) == Bytes({1, 2, 3}), "Outside content stays intact");
    });

    test("cancellation before publication preserves cache and cannot resurrect cleared sharing", [&] {
      Fixture fixture;
      fixture.Add("old.jpg");
      bool cancel = false;
      MediaCatalog* active = nullptr;
      MediaCatalog catalog(32 * 1024 * 1024, 4096, [&] { if (cancel) active->Clear(); });
      active = &catalog;
      fixture.Scan(catalog);
      const auto saved = Read(fixture.cache);
      fixture.Add("new.jpg");
      cancel = true;
      Reject("SCAN_CANCELLED", [&] { fixture.Update(catalog, {"new.jpg"}); });
      Expect(Read(fixture.cache) == saved, "Cancelled commit leaves prior cache bytes intact");
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(fixture.Id("old.jpg"), 0, 1); });
      for (const auto& item : std::filesystem::directory_iterator(fixture.base)) {
        Expect(item.path().extension() != L".tmp", "Cancellation removes its temporary cache");
      }
    });

    test("partial persistence protects unknown cache versions while keeping live results", [&] {
      Fixture fixture;
      fixture.Add("old.jpg");
      MediaCatalog catalog;
      fixture.Scan(catalog);
      auto newer = Read(fixture.cache);
      newer[8] = 2;
      Write(fixture.cache, newer);
      fixture.Add("new.jpg");
      Expect(fixture.Update(catalog, {"new.jpg"}).size() == 2, "Live update survives auxiliary cache warning");
      Expect(catalog.CatalogWarning() && catalog.CatalogWarning()->first == "LOCAL_CATALOG_VERSION",
             "Unknown format warning remains visible");
      Expect(Read(fixture.cache) == newer, "Never overwrite an unknown cache version");
    });

    std::cout << passed << " partial catalog tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
