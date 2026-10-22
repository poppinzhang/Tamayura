#include "storage_core.h"

#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <future>
#include <map>
#include <mutex>

#include "test_support.h"

namespace {
using namespace tamayura;
using namespace tamayura_test;
using namespace std::chrono_literals;

void AdvanceModifiedTime(const std::string& path) {
  struct stat info {};
  Expect(stat(path.c_str(), &info) == 0, "Read fixture timestamp");
  // One second later, without timing-dependent sleeps.
  struct timespec times[2] = {info.st_atim, info.st_mtim};
  times[1].tv_sec += 1;
  Expect(utimensat(AT_FDCWD, path.c_str(), times, 0) == 0, "Change fixture timestamp");
}

struct Fixture {
  TempDirectory& base;
  MediaCatalog catalog;
  std::string root;
  SharedDirectory shared;

  Fixture(TempDirectory& directory, unsigned index, size_t bytes = 32 * 1024 * 1024,
          size_t entries = 4096)
      : base(directory),
        catalog(bytes, entries),
        root(directory / ("photos-" + std::to_string(index))),
        shared{"photos", root, "Photos"} {
    MakeDirectory(root);
    for (const auto* name : {"a.jpg", "b.jpg", "c.jpg"}) WriteFile(Path(name), Bytes{1, 2, 3});
    Rescan();
  }

  std::string Path(const std::string& name) const { return root + "/" + name; }
  std::string Id(const std::string& name) const { return StableMediaId(shared.id, name); }
  void Rescan() { catalog.Scan({shared}, catalog.BeginScan({shared.id})); }
};

// A timeout bounds failures too: a regression must fail the test rather than
// leave a worker permanently blocked during stack unwinding.
class Gate {
 public:
  void Block() {
    std::unique_lock<std::mutex> lock(mutex_);
    entered_ = true;
    changed_.notify_all();
    if (!changed_.wait_for(lock, 5s, [&] { return released_; })) {
      throw std::runtime_error("Thumbnail generation gate timed out");
    }
  }
  void WaitEntered() {
    std::unique_lock<std::mutex> lock(mutex_);
    Expect(changed_.wait_for(lock, 5s, [&] { return entered_; }), "Generator did not start");
  }
  void Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    released_ = true;
    changed_.notify_all();
  }

 private:
  std::mutex mutex_;
  std::condition_variable changed_;
  bool entered_ = false;
  bool released_ = false;
};

void ExpectWaiting(std::future<Bytes>& future) {
  Expect(future.wait_for(100ms) == std::future_status::timeout,
         "A concurrent request must wait for the existing generator");
}

void ExpectReady(std::future<Bytes>& future) {
  Expect(future.wait_for(5s) == std::future_status::ready, "Thumbnail request did not finish");
}

using Generate = std::function<Bytes(const MediaEntry&, const SafeFile&)>;

}  // namespace

int main() {
  TempDirectory base;
  unsigned fixtures = 0;
  return RunTests("thumbnail cache", {
      {"unchanged bytes and empty previews are reused across scans", [&] {
         Fixture fixture(base, ++fixtures);
         unsigned calls = 0;
         const Generate generate = [&](const MediaEntry&, const SafeFile&) {
           ++calls;
           return Bytes{4, 5};
         };
         const auto id = fixture.Id("a.jpg");
         Expect(fixture.catalog.Thumbnail(id, generate) == Bytes({4, 5}), "Initial bytes");
         auto copy = fixture.catalog.Thumbnail(id, generate);
         copy[0] = 99;
         fixture.Rescan();
         Expect(fixture.catalog.Thumbnail(id, generate) == Bytes({4, 5}) && calls == 1,
                "Unchanged rescan reuses immutable cached bytes");
         const auto stale = fixture.catalog.BeginScan({fixture.shared.id});
         fixture.catalog.BeginScan({fixture.shared.id});
         Reject("SCAN_CANCELLED", [&] { fixture.catalog.Scan({fixture.shared}, stale); });
         fixture.catalog.Thumbnail(id, generate);
         Expect(calls == 1, "A superseded scan preserves the cache");
         unsigned empty_calls = 0;
         const Generate empty = [&](const MediaEntry&, const SafeFile&) {
           ++empty_calls;
           return Bytes{};
         };
         Expect(fixture.catalog.Thumbnail(fixture.Id("b.jpg"), empty).empty(), "Empty result");
         fixture.Rescan();
         Expect(fixture.catalog.Thumbnail(fixture.Id("b.jpg"), empty).empty() && empty_calls == 1,
                "Valid empty previews are cached");
       }},
      {"byte budget evicts least recently used previews", [&] {
         Fixture fixture(base, ++fixtures, 6, 10);
         std::map<std::string, unsigned> calls;
         const Generate generate = [&](const MediaEntry& entry, const SafeFile&) {
           ++calls[entry.name];
           return Bytes(3, static_cast<uint8_t>(entry.name[0]));
         };
         for (const auto* name : {"a.jpg", "b.jpg", "a.jpg", "c.jpg", "a.jpg", "b.jpg"}) {
           fixture.catalog.Thumbnail(fixture.Id(name), generate);
         }
         Expect(calls["a.jpg"] == 1 && calls["b.jpg"] == 2 && calls["c.jpg"] == 1,
                "A hit promotes the entry and the byte budget evicts the oldest");
       }},
      {"entry budget bounds zero-byte preview results", [&] {
         Fixture fixture(base, ++fixtures, 100, 2);
         std::map<std::string, unsigned> calls;
         const Generate generate = [&](const MediaEntry& entry, const SafeFile&) {
           ++calls[entry.name];
           return Bytes{};
         };
         for (const auto* name : {"a.jpg", "b.jpg", "a.jpg", "c.jpg", "a.jpg", "b.jpg"}) {
           fixture.catalog.Thumbnail(fixture.Id(name), generate);
         }
         Expect(calls["a.jpg"] == 1 && calls["b.jpg"] == 2 && calls["c.jpg"] == 1,
                "Empty entries obey the LRU count limit");
       }},
      {"oversized previews are never retained", [&] {
         for (const auto& limits :
              {std::pair<size_t, size_t>{2, 3}, {1024 * 1024, 512 * 1024 + 1}}) {
           Fixture fixture(base, ++fixtures, limits.first, 10);
           unsigned calls = 0;
           const Generate generate = [&](const MediaEntry&, const SafeFile&) {
             ++calls;
             return Bytes(limits.second, 7);
           };
           for (unsigned request = 0; request < 2; ++request) {
             Expect(fixture.catalog.Thumbnail(fixture.Id("a.jpg"), generate).size() == limits.second,
                    "Uncached payload is returned unchanged");
           }
           Expect(calls == 2, "Neither cache-budget nor wire-limit overflow is retained");
         }
       }},
      {"simultaneous requests share generation even with retention disabled", [&] {
         Fixture fixture(base, ++fixtures, 0, 0);
         Gate gate;
         std::atomic<unsigned> calls{0};
         const Generate generate = [&](const MediaEntry&, const SafeFile&) {
           if (++calls == 1) {
             gate.Block();
             return Bytes{4};
           }
           return Bytes{99};
         };
         const auto request = [&] { return fixture.catalog.Thumbnail(fixture.Id("a.jpg"), generate); };
         auto first = std::async(std::launch::async, request);
         gate.WaitEntered();
         auto second = std::async(std::launch::async, request);
         auto third = std::async(std::launch::async, request);
         ExpectWaiting(second);
         ExpectWaiting(third);
         gate.Release();
         ExpectReady(first);
         ExpectReady(second);
         ExpectReady(third);
         Expect(first.get() == Bytes{4} && second.get() == Bytes{4} && third.get() == Bytes{4} &&
                    calls == 1,
                "Concurrent peers share one generated result");
         Expect(request() == Bytes{99} && calls == 2, "Zero limits disable later retention");
       }},
      {"cached hits revalidate size, timestamp and deleted files", [&] {
         Fixture fixture(base, ++fixtures);
         unsigned calls = 0;
         const Generate generate = [&](const MediaEntry&, const SafeFile&) {
           ++calls;
           return Bytes{4};
         };
         const auto id = fixture.Id("a.jpg");
         fixture.catalog.Thumbnail(id, generate);
         WriteFile(fixture.Path("a.jpg"), Bytes{1, 2, 3, 4});
         Expect(fixture.catalog.Thumbnail(id, generate).empty() && calls == 1,
                "Changed size bypasses stale cache");
         fixture.Rescan();
         fixture.catalog.Thumbnail(id, generate);
         Expect(calls == 2, "Changed published size regenerates");
         AdvanceModifiedTime(fixture.Path("a.jpg"));
         Expect(fixture.catalog.Thumbnail(id, generate).empty() && calls == 2,
                "Changed timestamp bypasses stale cache");
         fixture.Rescan();
         fixture.catalog.Thumbnail(id, generate);
         Expect(calls == 3, "Changed published timestamp regenerates");
         Expect(unlink(fixture.Path("a.jpg").c_str()) == 0, "Delete fixture");
         Expect(fixture.catalog.Thumbnail(id, generate).empty() && calls == 3,
                "Deleted cached source has no preview");
         fixture.Rescan();
         Reject("FILE_NOT_FOUND", [&] { fixture.catalog.Thumbnail(id, generate); });
       }},
      {"a new published source path invalidates the same media ID", [&] {
         Fixture fixture(base, ++fixtures);
         unsigned calls = 0;
         const Generate generate = [&](const MediaEntry&, const SafeFile&) {
           ++calls;
           return Bytes{4};
         };
         const auto id = fixture.Id("a.jpg");
         fixture.catalog.Thumbnail(id, generate);
         const auto replacement = fixture.root + "-replacement";
         MakeDirectory(replacement);
         WriteFile(replacement + "/a.jpg", Bytes{1, 2, 3});
         struct stat info {};
         Expect(stat(fixture.Path("a.jpg").c_str(), &info) == 0, "Read source time");
         struct timespec times[2] = {info.st_atim, info.st_mtim};
         Expect(utimensat(AT_FDCWD, (replacement + "/a.jpg").c_str(), times, 0) == 0,
                "Copy unchanged file metadata to a new shared path");
         fixture.shared.uri = replacement;
         fixture.Rescan();
         fixture.catalog.Thumbnail(id, generate);
         Expect(calls == 2, "Published path and root are part of the cache identity");
       }},
      {"cached hits preserve file and shared-root access failures", [&] {
         Fixture fixture(base, ++fixtures);
         unsigned calls = 0;
         const Generate generate = [&](const MediaEntry&, const SafeFile&) {
           ++calls;
           return Bytes{4};
         };
         const auto id = fixture.Id("a.jpg");
         fixture.catalog.Thumbnail(id, generate);
         if (geteuid() != 0) {
           chmod(fixture.Path("a.jpg").c_str(), 0000);
           Reject("PERMISSION_LOST", [&] { fixture.catalog.Thumbnail(id, generate); });
           chmod(fixture.Path("a.jpg").c_str(), 0644);
           chmod(fixture.root.c_str(), 0300);
           Reject("PERMISSION_LOST", [&] { fixture.catalog.Thumbnail(id, generate); });
           chmod(fixture.root.c_str(), 0755);
         }
         const auto moved = fixture.root + "-moved";
         Expect(rename(fixture.root.c_str(), moved.c_str()) == 0, "Move shared root");
         Reject("FILE_NOT_FOUND", [&] { fixture.catalog.Thumbnail(id, generate); });
         Expect(symlink(moved.c_str(), fixture.root.c_str()) == 0, "Link shared root");
         Reject("INVALID_ARGUMENT", [&] { fixture.catalog.Thumbnail(id, generate); });
         Expect(unlink(fixture.root.c_str()) == 0 &&
                    rename(moved.c_str(), fixture.root.c_str()) == 0,
                "Restore shared root");
         Expect(fixture.catalog.Thumbnail(id, generate) == Bytes{4} && calls == 1,
                "A transient access error does not decode or return cached bytes");
       }},
      {"decoder failure caches empty while other errors remain retryable", [&] {
         Fixture fixture(base, ++fixtures);
         const auto id = fixture.Id("a.jpg");
         unsigned calls = 0;
         const Generate undecodable = [&](const MediaEntry&, const SafeFile&) -> Bytes {
           ++calls;
           throw StorageError("PREVIEW_FAILED", "No usable preview");
         };
         Expect(fixture.catalog.Thumbnail(id, undecodable).empty(), "Undecodable source is empty");
         Expect(fixture.catalog.Thumbnail(id, undecodable).empty() && calls == 1,
                "Repeat undecodable source does not decode again");
         fixture.catalog.Clear();
         fixture.Rescan();
         for (const auto* code : {"PERMISSION_LOST", "IO_ERROR", "RESOURCE_EXHAUSTED",
                                  "INVALID_ARGUMENT", "SCAN_CANCELLED"}) {
           const auto before = calls;
           for (unsigned attempt = 0; attempt < 2; ++attempt) {
             Reject(code, [&] {
               fixture.catalog.Thumbnail(id, [&](const MediaEntry&, const SafeFile&) -> Bytes {
                 ++calls;
                 throw StorageError(code, "Retryable failure");
               });
             });
           }
           Expect(calls == before + 2, "Thrown errors are not retained");
         }
         for (unsigned attempt = 0; attempt < 2; ++attempt) {
           bool rejected = false;
           try {
             fixture.catalog.Thumbnail(id, [&](const MediaEntry&, const SafeFile&) -> Bytes {
               ++calls;
               throw std::bad_alloc();
             });
           } catch (const std::bad_alloc&) {
             rejected = true;
           }
           Expect(rejected, "Resource exceptions remain visible and retryable");
         }
         const auto before_recovery = calls;
         const Generate recovered = [&](const MediaEntry&, const SafeFile&) {
           ++calls;
           return Bytes{5};
         };
         Expect(fixture.catalog.Thumbnail(id, recovered) == Bytes{5} && calls == before_recovery + 1,
                "Failed generation can retry");
       }},
      {"concurrent failure wakes peers and permits the next attempt", [&] {
         Fixture fixture(base, ++fixtures);
         Gate gate;
         std::atomic<unsigned> calls{0};
         const Generate failing = [&](const MediaEntry&, const SafeFile&) -> Bytes {
           if (++calls == 1) gate.Block();
           throw StorageError("IO_ERROR", "Transient decoder I/O");
         };
         const auto request = [&] { return fixture.catalog.Thumbnail(fixture.Id("a.jpg"), failing); };
         auto first = std::async(std::launch::async, request);
         gate.WaitEntered();
         auto second = std::async(std::launch::async, request);
         ExpectWaiting(second);
         gate.Release();
         ExpectReady(first);
         ExpectReady(second);
         Reject("IO_ERROR", [&] { first.get(); });
         Reject("IO_ERROR", [&] { second.get(); });
         Expect(calls == 1, "Waiting peers receive the same failure");
         Reject("IO_ERROR", [&] { request(); });
         Expect(calls == 2, "Failure is retried");
       }},
      {"unchanged republication preserves in-flight generation", [&] {
         Fixture fixture(base, ++fixtures);
         unsigned calls = 0;
         const Generate generate = [&](const MediaEntry&, const SafeFile&) {
           ++calls;
           fixture.Rescan();
           return Bytes{4};
         };
         Expect(fixture.catalog.Thumbnail(fixture.Id("a.jpg"), generate) == Bytes{4},
                "Generation spans an unchanged scan");
         fixture.catalog.Thumbnail(fixture.Id("a.jpg"), generate);
         Expect(calls == 1, "Spanning generation is retained");
       }},
      {"revocation removes retained entries immediately", [&] {
         Fixture fixture(base, ++fixtures);
         unsigned calls = 0;
         const Generate generate = [&](const MediaEntry&, const SafeFile&) {
           ++calls;
           return Bytes{4};
         };
         const auto id = fixture.Id("a.jpg");
         fixture.catalog.Thumbnail(id, generate);
         fixture.catalog.BeginScan({});
         Reject("FILE_NOT_FOUND", [&] { fixture.catalog.Thumbnail(id, generate); });
         fixture.Rescan();
         fixture.catalog.Thumbnail(id, generate);
         Expect(calls == 2, "Folder removal discards retained previews before republication");
         fixture.catalog.Clear();
         fixture.Rescan();
         fixture.catalog.Thumbnail(id, generate);
         Expect(calls == 3, "Clear discards retained previews");
         const SharedDirectory missing{"missing", base / "missing", "Missing"};
         Reject("FILE_NOT_FOUND", [&] {
           fixture.catalog.Scan({missing},
                                fixture.catalog.BeginScan({fixture.shared.id, missing.id}));
         });
         fixture.Rescan();
         fixture.catalog.Thumbnail(id, generate);
         Expect(calls == 4, "Failed current scan discards retained previews");
       }},
      {"clear, removed folders and failed scans discard late results", [&] {
         for (unsigned mode = 0; mode < 3; ++mode) {
           Fixture fixture(base, ++fixtures);
           Gate gate;
           std::atomic<unsigned> calls{0};
           const Generate generate = [&](const MediaEntry&, const SafeFile&) -> Bytes {
             if (++calls == 1) gate.Block();
             if (mode == 1) throw StorageError("PREVIEW_FAILED", "Late decode failure");
             return Bytes{4};
           };
           const auto id = fixture.Id("a.jpg");
           const auto request = [&] { return fixture.catalog.Thumbnail(id, generate); };
           auto first = std::async(std::launch::async, request);
           gate.WaitEntered();
           auto second = std::async(std::launch::async, request);
           ExpectWaiting(second);
           if (mode == 0) {
             fixture.catalog.Clear();
           } else if (mode == 1) {
             fixture.catalog.BeginScan({});
           } else {
             const SharedDirectory missing{"missing", base / "missing", "Missing"};
             Reject("FILE_NOT_FOUND", [&] {
               fixture.catalog.Scan({missing},
                                    fixture.catalog.BeginScan({fixture.shared.id, missing.id}));
             });
           }
           // A waiter is released without waiting for the decoder to finish.
           ExpectReady(second);
           Reject("SCAN_CANCELLED", [&] { second.get(); });
           // Republish identical metadata while the old generation still runs.
           fixture.Rescan();
           Expect(fixture.catalog.Thumbnail(id, [](const MediaEntry&, const SafeFile&) {
                    return Bytes{8};
                  }) == Bytes{8},
                  "Republished source starts a fresh generation");
           gate.Release();
           ExpectReady(first);
           Reject("SCAN_CANCELLED", [&] { first.get(); });
           const Generate unexpected = [](const MediaEntry&, const SafeFile&) -> Bytes {
             throw std::runtime_error("Late result replaced a valid cached generation");
           };
           Expect(fixture.catalog.Thumbnail(id, unexpected) == Bytes{8},
                  "Late result cannot overwrite the replacement");
         }
       }},
  });
}
