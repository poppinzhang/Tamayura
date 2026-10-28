#include "storage_core.h"

#include <bcrypt.h>
#include <objbase.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <functional>
#include <iostream>

namespace {
using namespace tamayura;

void Expect(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

void Reject(const std::string& code, const std::function<void()>& action) {
  try { action(); }
  catch (const StorageError& error) {
    Expect(error.code == code, ("Unexpected error: " + error.code).c_str());
    return;
  }
  throw std::runtime_error("Expected the operation to fail");
}

void Write(const std::wstring& path, const Bytes& bytes) {
  const auto native = std::wstring(L"\\\\?\\") + path;
  Handle file(CreateFileW(native.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                          FILE_ATTRIBUTE_NORMAL, nullptr));
  Expect(file.get() != INVALID_HANDLE_VALUE, "Cannot create fixture");
  DWORD written = 0;
  Expect(WriteFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) &&
             written == bytes.size(), "Cannot write fixture");
}

Bytes Read(const std::wstring& path) {
  auto file = SafeFile::Open(path);
  const auto size = file.info().size;
  return file.Read(0, size, size);
}

void Checksum(Bytes& bytes) {
  Expect(bytes.size() >= 32, "Fixture has a checksum");
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  Expect(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0,
         "Open fixture hashing");
  const auto payload_size = static_cast<ULONG>(bytes.size() - 32);
  const auto status = BCryptHash(algorithm, nullptr, 0, bytes.data(), payload_size,
                                 bytes.data() + payload_size, 32);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  Expect(status >= 0, "Hash fixture");
}

// Construct explicit on-disk fixtures to exercise protocol boundaries without
// depending on the production encoder accepting deliberately invalid entries.
Bytes CatalogFixture(const SharedDirectory& shared, const std::string& relative) {
  Bytes bytes{'T', 'M', 'Y', 'R', 'C', 'A', 'T', 0};
  auto integer = [&](uint64_t value, unsigned width) {
    for (unsigned i = 0; i < width; ++i) bytes.push_back(static_cast<uint8_t>(value >> (i * 8)));
  };
  auto string = [&](const std::string& value) {
    integer(value.size(), 4);
    bytes.insert(bytes.end(), value.begin(), value.end());
  };
  integer(1, 4);
  integer(1, 4);
  string(shared.id);
  string(shared.uri);
  string(shared.name);
  integer(1, 4);
  string(StableMediaId(shared.id, relative));
  string(relative.substr(relative.find_last_of('/') + 1));
  string("image/jpeg");
  integer(5, 8);
  integer(0, 8);
  string(shared.id);
  string(relative);
  bytes.resize(bytes.size() + 32);
  Checksum(bytes);
  return bytes;
}

std::string LongRelativePath(size_t units, bool supplementary) {
  std::wstring result;
  while (units - result.size() > 255) {
    if (supplementary) {
      for (unsigned i = 0; i < 100; ++i) result += L"\xD83D\xDE80";
    } else {
      result += std::wstring(200, L'a');
    }
    result += L'/';
  }
  result += std::wstring(units - result.size() - 4, L'b') + L".jpg";
  Expect(result.size() == units, "Expected UTF-16 fixture length");
  return Utf8(result);
}

struct Fixture {
  std::wstring base, root, nested, photo, cache;
  SharedDirectory shared;
  Bytes media{1, 2, 3, 4, 5};
  Fixture() {
    wchar_t temporary[MAX_PATH]{};
    Expect(GetTempPathW(MAX_PATH, temporary) != 0, "Find temporary directory");
    GUID guid{};
    wchar_t text[40]{};
    Expect(SUCCEEDED(CoCreateGuid(&guid)) && StringFromGUID2(guid, text, 40) == 39,
           "Create fixture identifier");
    base = JoinPath(temporary, std::wstring(L"tamayura-catalog-") + text);
    root = JoinPath(base, L"shared");
    nested = JoinPath(root, L"nested");
    std::filesystem::create_directories(nested);
    photo = JoinPath(nested, L"a.jpg");
    cache = JoinPath(base, L"catalog.bin");
    shared = {"photos", Utf8(root), "Photos"};
    Write(photo, media);
  }
  ~Fixture() {
    std::error_code ignored;
    // Long-path tests also clean descendants beyond the legacy MAX_PATH limit.
    std::filesystem::remove_all(std::wstring(L"\\\\?\\") + base, ignored);
  }
  std::string id() const { return StableMediaId(shared.id, "nested/a.jpg"); }
  uint64_t Begin(MediaCatalog& catalog) const { return catalog.BeginScan({shared.id}); }
  std::vector<MediaEntry> Scan(MediaCatalog& catalog) const {
    return catalog.Scan({shared}, Begin(catalog), cache);
  }
  std::optional<std::vector<MediaEntry>> Restore(MediaCatalog& catalog) const {
    return catalog.Restore({shared}, Begin(catalog), cache);
  }
  void NoTemporaryFiles() const {
    for (const auto& entry : std::filesystem::directory_iterator(base)) {
      Expect(entry.path().extension() != L".tmp", "No abandoned temporary catalog");
    }
  }
};
}  // namespace

int main() {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  struct ComGuard { HRESULT result; ~ComGuard() { if (SUCCEEDED(result)) CoUninitialize(); } } guard{com};
  unsigned passed = 0;
  auto test = [&](const char* name, const std::function<void()>& action) {
    action();
    ++passed;
    std::cout << "PASS " << name << '\n';
  };
  try {
    test("a new process restores metadata without opening any media file", [&] {
      Fixture fixture;
      MediaCatalog first;
      Expect(!fixture.Restore(first), "A missing cache is distinct from an empty catalog");
      const auto scanned = fixture.Scan(first);
      Expect(scanned.size() == 1, "One media file scanned");
      Handle exclusive(CreateFileW(fixture.photo.c_str(), GENERIC_READ, 0, nullptr,
                                   OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
      Expect(exclusive.get() != INVALID_HANDLE_VALUE, "Lock source media");
      MediaCatalog restarted;
      const auto restored = fixture.Restore(restarted);
      Expect(restored && restored->size() == 1 && restored->front().id == scanned.front().id &&
                 restored->front().path == scanned.front().path &&
                 restored->front().modified_ms == scanned.front().modified_ms,
             "Restoration reuses metadata while the media file cannot be opened");
      Reject("PERMISSION_LOST", [&] { restarted.Read(fixture.id(), 0, 5); });
      exclusive.reset();
      Expect(restarted.Read(fixture.id(), 0, 5) == fixture.media, "Restored source can serve bytes");
    });

    test("an empty completed catalog is restored as a valid empty snapshot", [&] {
      Fixture fixture;
      std::filesystem::remove(fixture.photo);
      MediaCatalog first;
      Expect(fixture.Scan(first).empty(), "Empty scan");
      MediaCatalog restarted;
      const auto restored = fixture.Restore(restarted);
      Expect(restored && restored->empty(), "Empty cache is not a cache miss");
      fixture.NoTemporaryFiles();
    });

    test("configuration changes never reuse a previous root or folder identity", [&] {
      Fixture fixture;
      MediaCatalog first;
      fixture.Scan(first);
      const auto saved = Read(fixture.cache);
      for (unsigned change = 0; change < 3; ++change) {
        auto changed = fixture.shared;
        if (change == 0) changed.id = "different-folder";
        if (change == 1) changed.name = "Renamed";
        if (change == 2) changed.uri = Utf8(fixture.nested);
        MediaCatalog restarted;
        Expect(!restarted.Restore({changed}, restarted.BeginScan({changed.id}), fixture.cache),
               "Changed configuration is a cache miss");
        Reject("FILE_NOT_FOUND", [&] { restarted.Read(fixture.id(), 0, 1); });
      }
      Expect(Read(fixture.cache) == saved, "A cache miss does not change the saved catalog");
    });

    test("restored reads still reject deleted changed and unavailable sources", [&] {
      Fixture fixture;
      MediaCatalog first;
      fixture.Scan(first);
      const auto saved = Read(fixture.cache);
      Write(fixture.photo, Bytes{8, 9});
      MediaCatalog changed;
      Expect(fixture.Restore(changed)->size() == 1, "Restoration does not inspect file state");
      Reject("FILE_CHANGED", [&] { changed.Read(fixture.id(), 0, 1); });
      std::filesystem::remove(fixture.photo);
      MediaCatalog deleted;
      Expect(fixture.Restore(deleted)->size() == 1, "A stale entry survives until reconciliation");
      Reject("FILE_NOT_FOUND", [&] { deleted.Read(fixture.id(), 0, 1); });
      const auto moved = JoinPath(fixture.base, L"moved");
      std::filesystem::rename(fixture.root, moved);
      MediaCatalog unavailable;
      Reject("FILE_NOT_FOUND", [&] { fixture.Restore(unavailable); });
      Expect(Read(fixture.cache) == saved, "Source failure preserves cache bytes");
    });

    test("old newer and corrupt caches remain untouched while scans keep serving", [&] {
      Fixture fixture;
      MediaCatalog first;
      fixture.Scan(first);
      const auto original = Read(fixture.cache);
      for (unsigned kind = 0; kind < 3; ++kind) {
        auto altered = original;
        if (kind == 0) altered[8] = 0;
        if (kind == 1) altered[8] = 2;
        if (kind == 2) altered.back() ^= 1;
        const std::string code = kind == 2 ? "LOCAL_CATALOG_CORRUPT" : "LOCAL_CATALOG_VERSION";
        Write(fixture.cache, altered);
        MediaCatalog restarted;
        Reject(code, [&] { fixture.Restore(restarted); });
        fixture.Scan(restarted);
        Expect(restarted.Read(fixture.id(), 0, 5) == fixture.media, "Scan serves despite cache warning");
        Expect(restarted.CatalogWarning() && restarted.CatalogWarning()->first == code,
               "Cache warning remains visible after a full scan");
        Expect(Read(fixture.cache) == altered, "Unsupported/damaged cache bytes are preserved");
        MediaCatalog without_restore;
        fixture.Scan(without_restore);
        Expect(Read(fixture.cache) == altered, "A first scan also protects existing unknown cache bytes");
        fixture.NoTemporaryFiles();
      }
    });

    test("valid checksums do not permit cached relative-path traversal", [&] {
      Fixture fixture;
      MediaCatalog first;
      fixture.Scan(first);
      auto altered = Read(fixture.cache);
      const std::string path = "nested/a.jpg";
      const std::string escape = "../bad/a.jpg";
      const auto found = std::search(altered.begin(), altered.end(), path.begin(), path.end());
      Expect(found != altered.end() && path.size() == escape.size(), "Find relative-path fixture");
      std::copy(escape.begin(), escape.end(), found);
      Checksum(altered);
      Write(fixture.cache, altered);
      MediaCatalog restarted;
      Reject("LOCAL_CATALOG_CORRUPT", [&] { fixture.Restore(restarted); });
      Expect(Read(fixture.cache) == altered, "Unsafe cache is preserved for diagnosis");
    });

    test("cache paths use the same 4096 UTF-16 unit boundary as Dart", [&] {
      Fixture fixture;
      for (const bool supplementary : {false, true}) {
        const auto accepted = LongRelativePath(4096, supplementary);
        Write(fixture.cache, CatalogFixture(fixture.shared, accepted));
        MediaCatalog restored;
        const auto entries = fixture.Restore(restored);
        Expect(entries && entries->size() == 1 && entries->front().relative_path == accepted,
               "A 4096-unit relative path is accepted without inspecting media files");
        const auto rejected = CatalogFixture(fixture.shared, LongRelativePath(4097, supplementary));
        Write(fixture.cache, rejected);
        MediaCatalog invalid;
        Reject("LOCAL_CATALOG_CORRUPT", [&] { fixture.Restore(invalid); });
        Expect(Read(fixture.cache) == rejected, "Over-limit cache remains untouched");
      }
    });

    test("scanning skips paths that cannot be published and saves a restorable snapshot", [&] {
      Fixture fixture;
      auto directory = fixture.root;
      for (unsigned i = 0; i < 22; ++i) {
        directory = JoinPath(directory, std::wstring(200, L'a'));
        const auto native = std::wstring(L"\\\\?\\") + directory;
        Expect(CreateDirectoryW(native.c_str(), nullptr) != FALSE, "Create long-path fixture directory");
      }
      Write(JoinPath(directory, L"deep.jpg"), Bytes{7});
      MediaCatalog scanned;
      Expect(fixture.Scan(scanned).size() == 1, "Unpublishable deep media is excluded from the cache");
      MediaCatalog restarted;
      const auto restored = fixture.Restore(restarted);
      Expect(restored && restored->size() == 1 && restored->front().id == fixture.id(),
             "Ordinary media still restores with an over-limit sibling tree");
      Expect(restarted.Read(fixture.id(), 0, 5) == fixture.media, "Restored ordinary media remains readable");
    });

    test("current restore failures and misses revoke previous native publication", [&] {
      Fixture fixture;
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto original = Read(fixture.cache);
      auto damaged = original;
      damaged.back() ^= 1;
      Write(fixture.cache, damaged);
      const auto failure_ticket = fixture.Begin(catalog);
      Reject("LOCAL_CATALOG_CORRUPT", [&] {
        catalog.Restore({fixture.shared}, failure_ticket, fixture.cache);
      });
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(fixture.id(), 0, 1); });
      catalog.AssertScan(failure_ticket);
      Write(fixture.cache, original);
      fixture.Restore(catalog);
      auto changed = fixture.shared;
      changed.name = "Changed";
      const auto mismatch_ticket = fixture.Begin(catalog);
      Expect(!catalog.Restore({changed}, mismatch_ticket, fixture.cache), "Configuration mismatch is a miss");
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(fixture.id(), 0, 1); });
      catalog.AssertScan(mismatch_ticket);
      fixture.Restore(catalog);
      std::filesystem::remove(fixture.cache);
      const auto missing_ticket = fixture.Begin(catalog);
      Expect(!catalog.Restore({fixture.shared}, missing_ticket, fixture.cache), "Missing cache is a miss");
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(fixture.id(), 0, 1); });
      catalog.AssertScan(missing_ticket);
    });

    test("atomic replacement failure preserves both old cache and live sharing", [&] {
      Fixture fixture;
      MediaCatalog catalog;
      fixture.Scan(catalog);
      const auto saved = Read(fixture.cache);
      Write(JoinPath(fixture.root, L"new.jpg"), Bytes{9});
      Handle locked(CreateFileW(fixture.cache.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
      Expect(locked.get() != INVALID_HANDLE_VALUE, "Prevent catalog replacement");
      Expect(fixture.Scan(catalog).size() == 2, "Cache write failure does not discard a complete scan");
      Expect(catalog.CatalogWarning() && catalog.CatalogWarning()->first == "LOCAL_CATALOG_IO",
             "Persistence failure is independently reported");
      Expect(catalog.Read(fixture.id(), 0, 5) == fixture.media, "Sharing remains available");
      Expect(Read(fixture.cache) == saved, "Failed replacement retains old bytes");
      locked.reset();
      fixture.NoTemporaryFiles();
      fixture.Scan(catalog);
      Expect(!catalog.CatalogWarning(), "A successful retry clears the warning");
      MediaCatalog restarted;
      Expect(fixture.Restore(restarted)->size() == 2, "Retry persists the complete new snapshot");
    });

    test("clear during publication cancels restoration and pending atomic writes", [&] {
      Fixture fixture;
      MediaCatalog seed;
      fixture.Scan(seed);
      const auto saved = Read(fixture.cache);
      std::function<void()> before_publish;
      MediaCatalog catalog(0, 0, [&] { if (before_publish) before_publish(); });
      fixture.Restore(catalog);
      before_publish = [&] { catalog.Clear(); };
      Reject("SCAN_CANCELLED", [&] { fixture.Restore(catalog); });
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(fixture.id(), 0, 1); });
      Write(JoinPath(fixture.root, L"later.jpg"), Bytes{6});
      Reject("SCAN_CANCELLED", [&] { fixture.Scan(catalog); });
      Expect(Read(fixture.cache) == saved, "Cancelled prepared write cannot replace the cache");
      fixture.NoTemporaryFiles();
      before_publish = {};
      Expect(fixture.Scan(catalog).size() == 2, "The next scan can publish normally");
    });

    test("newer scan tickets prevent late restore and write publication", [&] {
      Fixture fixture;
      MediaCatalog seed;
      fixture.Scan(seed);
      const auto saved = Read(fixture.cache);
      std::function<void()> before_publish;
      MediaCatalog catalog(0, 0, [&] { if (before_publish) before_publish(); });
      fixture.Restore(catalog);
      before_publish = [&] { fixture.Begin(catalog); };
      Reject("SCAN_CANCELLED", [&] { fixture.Restore(catalog); });
      Expect(catalog.Read(fixture.id(), 0, 5) == fixture.media, "Superseded restore retains published reads");
      Write(JoinPath(fixture.root, L"later.jpg"), Bytes{6});
      Reject("SCAN_CANCELLED", [&] { fixture.Scan(catalog); });
      Expect(Read(fixture.cache) == saved, "Superseded write preserves the existing cache");
      const auto stale = fixture.Begin(catalog);
      catalog.BeginScan({});
      Reject("SCAN_CANCELLED", [&] { catalog.Restore({fixture.shared}, stale, fixture.cache); });
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(fixture.id(), 0, 1); });
      fixture.NoTemporaryFiles();
    });
    std::cout << passed << " Windows catalog cache tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL after " << passed << " tests: " << error.what() << '\n';
    return 1;
  }
}
