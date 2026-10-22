#include "storage_core.h"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <set>
#include <thread>

#include "test_support.h"

namespace {
using namespace tamayura;
using namespace tamayura_test;

bool RunningAsRoot() { return geteuid() == 0; }

std::vector<MediaEntry> ScanOnce(MediaCatalog& catalog,
                                 const std::vector<SharedDirectory>& folders) {
  std::set<std::string> ids;
  for (const auto& folder : folders) ids.insert(folder.id);
  return catalog.Scan(folders, catalog.BeginScan(ids));
}

MediaEntry Find(const std::vector<MediaEntry>& entries, const std::string& relative) {
  for (const auto& entry : entries) {
    if (entry.relative_path == relative) return entry;
  }
  throw std::runtime_error("Missing scanned entry " + relative);
}

void TestNameRules() {
  for (const std::string name : {"IMG_0001.JPG", "旅行 照片.heic", "写真（1）.png",
                                 "emoji 📷.jpg", "a b", "-leading.jpg"}) {
    ValidateSegment(name);
  }
  for (const std::string& name :
       {std::string(), std::string("."), std::string(".."), std::string("a/b"),
        std::string("a\\b"), std::string("tab\tname"), std::string("\x7f"),
        std::string("bad\xff.jpg"), std::string("nul\0x", 5),
        std::string(256, 'a'), std::string("\xc2\x85next")}) {
    Reject("INVALID_ARGUMENT", [&] { ValidateSegment(name); });
  }
  ValidateSegment(std::string(255, 'a'));
  Expect(RelativeComponents("2026/旅行/a.jpg").size() == 3, "relative components");
  for (const std::string path : {"C:photo.jpg", "c:/photo.jpg", "/a.jpg", "a//b.jpg",
                                 "a/./b.jpg", "a/../b.jpg", "a/", ""}) {
    Reject("INVALID_ARGUMENT", [&] { RelativeComponents(path); });
  }
  Reject("INVALID_ARGUMENT", [] { RelativeComponents(std::string(4097, 'a')); });
}

void TestLocalPaths() {
  Expect(LocalPath("/") == "/", "root path");
  Expect(LocalPath("/home//user/Pictures/") == "/home/user/Pictures", "normalized");
  Expect(LocalPath("/照片/2026") == "/照片/2026", "Unicode path");
  for (const std::string path : {"relative", "", "/a/../b", "/a/./b", "~/Pictures",
                                 "/bad\xff", "file:///tmp"}) {
    Reject("INVALID_ARGUMENT", [&] { LocalPath(path); });
  }
  Expect(ContainsPath("/a/b", "/a/b/c"), "child contained");
  Expect(ContainsPath("/a/b", "/a/b"), "same path contained");
  Expect(!ContainsPath("/a/b", "/a/bc"), "sibling prefix");
  Expect(ContainsPath("/", "/anything"), "root contains all");
  Expect(ParentPath("/a/b") == "/a" && ParentPath("/a") == "/", "parent paths");
  Expect(BaseName("/a/b.jpg") == "b.jpg", "base name");
  Expect(JoinPath("/", "a") == "/a" && JoinPath("/a", "b") == "/a/b", "join");
}

void TestReceivedNames() {
  Expect(ReceivedName("photo.jpg") == "photo.jpg", "short name kept");
  std::string long_name;
  for (int index = 0; index < 100; ++index) long_name += "长";
  long_name += ".jpg";
  Expect(long_name.size() > 255, "fixture exceeds the Linux name limit");
  const auto fitted = ReceivedName(long_name);
  Expect(fitted.size() <= 255 && IsUtf8(fitted), "fitted to one UTF-8 name");
  Expect(fitted.size() > 4 && fitted.compare(fitted.size() - 4, 4, ".jpg") == 0,
         "extension kept");
  Reject("INVALID_ARGUMENT", [] { ReceivedName("../escape.jpg"); });
  Reject("INVALID_ARGUMENT", [] { ReceivedName("a\\b.jpg"); });
  Expect(AvailableName("photo.jpg", 0) == "photo.jpg", "first attempt");
  Expect(AvailableName("photo.jpg", 2) == "photo (2).jpg", "numbered name");
  Expect(AvailableName(".hidden", 1) == ".hidden (1)", "dot file has no extension");
  Expect(AvailableName("archive", 3) == "archive (3)", "no extension");
  const auto numbered = AvailableName(fitted, 12);
  Expect(numbered.size() <= 255 && IsUtf8(numbered), "numbered long name fits");
  Expect(numbered.find(" (12).jpg") != std::string::npos, "suffix kept");
}

void TestMediaTypes() {
  Expect(MediaMime("A.JPG") == "image/jpeg", "uppercase extension");
  Expect(MediaMime("clip.MOV") == "video/quicktime", "video type");
  Expect(MediaMime("raw.ARW") == "image/x-sony-arw", "RAW type");
  Expect(MediaMime("notes.txt").empty() && MediaMime("jpg").empty() &&
             MediaMime(".jpg").empty(),
         "unsupported names");
  Expect(IsRawMime("image/x-adobe-dng") && !IsRawMime("image/jpeg"), "RAW detection");
  Expect(IsVideoMime("video/mp4") && !IsVideoMime("image/png"), "video detection");
  const auto id = StableMediaId("folder", "2026/a.jpg");
  Expect(id.size() == 64 && id == StableMediaId("folder", "2026/a.jpg"), "stable ID");
  Expect(id != StableMediaId("folder2", "2026/a.jpg") &&
             id != StableMediaId("folder", "2026/b.jpg"),
         "ID depends on folder and path");
  // The NUL separator keeps folder and path boundaries distinct.
  Expect(StableMediaId("ab", "c") != StableMediaId("a", "bc"), "unambiguous ID input");
}

void TestScanRules() {
  TempDirectory temp;
  const auto root = temp / "共享";
  MakeDirectory(root + "/2026/旅行");
  MakeDirectory(root + "/.git");
  MakeDirectory(root + "/empty");
  WriteFile(root + "/a.jpg", Pattern(1000));
  WriteFile(root + "/2026/旅行/clip.MOV", Pattern(3000, 7));
  WriteFile(root + "/.hidden.jpg", Pattern(10));
  WriteFile(root + "/.git/inside.jpg", Pattern(10));
  WriteFile(root + "/notes.txt", Pattern(10));
  WriteFile(root + "/C:drive.jpg", Pattern(10));
  WriteFile(root + "/back\\slash.jpg", Pattern(10));
  WriteFile(root + std::string("/bad\xff.jpg"), Pattern(10));
  WriteFile(root + "/control\x01.jpg", Pattern(10));
  Expect(symlink("a.jpg", (root + "/link.jpg").c_str()) == 0, "file link fixture");
  Expect(symlink("2026", (root + "/linked-folder").c_str()) == 0, "folder link fixture");
  Expect(mkfifo((root + "/pipe.jpg").c_str(), 0600) == 0, "FIFO fixture");
  MediaCatalog catalog;
  const auto entries = ScanOnce(catalog, {{"camera", root, "相机"}});
  Expect(entries.size() == 2, "only ordinary, nameable media are shared: " +
                                  std::to_string(entries.size()));
  const auto photo = Find(entries, "a.jpg");
  Expect(photo.mime_type == "image/jpeg" && photo.size == 1000 &&
             photo.shared_folder_id == "camera" && photo.shared_folder_name == "相机" &&
             photo.id == StableMediaId("camera", "a.jpg") && photo.name == "a.jpg" &&
             photo.path == root + "/a.jpg" && photo.root == root,
         "photo metadata");
  struct stat info {};
  Expect(stat((root + "/a.jpg").c_str(), &info) == 0, "stat photo");
  Expect(photo.modified_ms == info.st_mtim.tv_sec * 1000LL + info.st_mtim.tv_nsec / 1000000,
         "modification time in milliseconds");
  const auto video = Find(entries, "2026/旅行/clip.MOV");
  Expect(video.mime_type == "video/quicktime" && video.size == 3000 &&
             video.name == "clip.MOV",
         "nested video metadata");
}

void TestUnreadableChildrenAreSkipped() {
  if (RunningAsRoot()) {
    std::cout << "  skipped permission checks while running as root\n";
    return;
  }
  TempDirectory temp;
  const auto root = temp / "root";
  MakeDirectory(root + "/private");
  WriteFile(root + "/private/secret.jpg", Pattern(10));
  WriteFile(root + "/locked.jpg", Pattern(10));
  WriteFile(root + "/open.jpg", Pattern(10));
  chmod((root + "/private").c_str(), 0000);
  chmod((root + "/locked.jpg").c_str(), 0000);
  MediaCatalog catalog;
  const auto entries = ScanOnce(catalog, {{"root", root, "root"}});
  Expect(entries.size() == 1 && entries[0].relative_path == "open.jpg",
         "unreadable file and folder skipped");
  chmod(root.c_str(), 0000);
  Reject("PERMISSION_LOST", [&] { ScanOnce(catalog, {{"root", root, "root"}}); });
  Reject("FILE_NOT_FOUND", [&] { catalog.Read(entries[0].id, 0, 1); });
}

void TestFolderValidation() {
  TempDirectory temp;
  MakeDirectory(temp / "a/b");
  MakeDirectory(temp / "c");
  MediaCatalog catalog;
  catalog.Validate(temp / "a", {temp / "c"});
  Reject("DIR_OVERLAP", [&] { catalog.Validate(temp / "a", {temp / "a/b"}); });
  Reject("DIR_OVERLAP", [&] { catalog.Validate(temp / "a/b", {temp / "a"}); });
  Reject("DIR_OVERLAP", [&] { catalog.Validate(temp / "a", {temp / "a/"}); });
  Reject("INVALID_ARGUMENT", [] { MediaCatalog().Validate("/", {}); });
  Reject("FILE_NOT_FOUND", [&] { catalog.Validate(temp / "missing", {}); });
  Expect(symlink((temp / "a").c_str(), (temp / "alias").c_str()) == 0, "alias fixture");
  Reject("INVALID_ARGUMENT", [&] { catalog.Validate(temp / "alias", {}); });
  Expect(ValidateDirectory(temp / "alias") == temp / "a",
         "picked links resolve to the canonical folder");
  WriteFile(temp / "file.jpg", Pattern(1));
  Reject("FILE_NOT_FOUND", [&] { ValidateDirectory(temp / "file.jpg"); });
  Reject("DIR_OVERLAP", [&] {
    ScanOnce(catalog, {{"one", temp / "a", "A"}, {"two", temp / "a/b", "B"}});
  });
  Reject("INVALID_ARGUMENT", [&] {
    ScanOnce(catalog, {{"same", temp / "a", "A"}, {"same", temp / "c", "C"}});
  });
  for (const std::string name : {"C:", "a/b", "", "bad\\name"}) {
    Reject("INVALID_ARGUMENT", [&] { ScanOnce(catalog, {{"id", temp / "c", name}}); });
  }
}

void TestRangeReads() {
  TempDirectory temp;
  const auto root = temp / "root";
  MakeDirectory(root);
  const auto content = Pattern(3 * 1024 * 1024 + 17);
  WriteFile(root + "/video.mp4", content);
  MediaCatalog catalog;
  const auto entries = ScanOnce(catalog, {{"root", root, "root"}});
  const auto id = entries.at(0).id;
  const auto first = catalog.Read(id, 0, kMaxReadChunkBytes);
  Expect(first.size() == static_cast<size_t>(kMaxReadChunkBytes) &&
             std::equal(first.begin(), first.end(), content.begin()),
         "first chunk");
  const auto tail = catalog.Read(id, static_cast<int64_t>(content.size()) - 10, 100);
  Expect(tail.size() == 10 && std::equal(tail.begin(), tail.end(), content.end() - 10),
         "tail is clamped to the file size");
  Expect(catalog.Read(id, static_cast<int64_t>(content.size()), 10).empty(),
         "reading at the end returns no bytes");
  Reject("INVALID_ARGUMENT", [&] { catalog.Read(id, 0, kMaxReadChunkBytes + 1); });
  Reject("INVALID_ARGUMENT", [&] { catalog.Read(id, -1, 1); });
  Reject("INVALID_ARGUMENT",
         [&] { catalog.Read(id, static_cast<int64_t>(content.size()) + 1, 1); });
  Reject("FILE_NOT_FOUND", [&] { catalog.Read("unknown", 0, 1); });
  WriteFile(root + "/video.mp4", Pattern(content.size() + 1));
  Reject("FILE_CHANGED", [&] { catalog.Read(id, 0, 1); });
  unlink((root + "/video.mp4").c_str());
  Reject("FILE_NOT_FOUND", [&] { catalog.Read(id, 0, 1); });
}

void TestLinksAreNeverFollowed() {
  TempDirectory temp;
  const auto root = temp / "root";
  MakeDirectory(root + "/sub");
  MakeDirectory(temp / "outside");
  WriteFile(root + "/a.jpg", Pattern(100));
  WriteFile(root + "/sub/b.jpg", Pattern(100, 3));
  WriteFile(temp / "outside/secret.jpg", Pattern(100, 9));
  WriteFile(temp / "outside/b.jpg", Pattern(100, 9));
  MediaCatalog catalog;
  const auto entries = ScanOnce(catalog, {{"root", root, "root"}});
  const auto a = Find(entries, "a.jpg").id;
  const auto b = Find(entries, "sub/b.jpg").id;
  unlink((root + "/a.jpg").c_str());
  Expect(symlink((temp / "outside/secret.jpg").c_str(), (root + "/a.jpg").c_str()) == 0,
         "replacement file link");
  Reject("INVALID_ARGUMENT", [&] { catalog.Read(a, 0, 10); });
  Expect(rename((root + "/sub").c_str(), (temp / "moved").c_str()) == 0, "move folder");
  Expect(symlink((temp / "outside").c_str(), (root + "/sub").c_str()) == 0,
         "replacement folder link");
  Reject("INVALID_ARGUMENT", [&] { catalog.Read(b, 0, 10); });
  Expect(rename(root.c_str(), (temp / "root-moved").c_str()) == 0, "move root");
  Expect(symlink((temp / "root-moved").c_str(), root.c_str()) == 0, "root link");
  Reject("INVALID_ARGUMENT", [&] { ScanOnce(catalog, {{"root", root, "root"}}); });
}

void TestCatalogLifecycle() {
  TempDirectory temp;
  MakeDirectory(temp / "one");
  MakeDirectory(temp / "two");
  WriteFile(temp / "one/a.jpg", Pattern(10));
  WriteFile(temp / "two/b.jpg", Pattern(10));
  MediaCatalog catalog;
  const auto entries = ScanOnce(catalog, {{"one", temp / "one", "One"},
                                          {"two", temp / "two", "Two"}});
  const auto a = Find(entries, "a.jpg").id;
  const auto b = Find(entries, "b.jpg").id;
  // A rescan keeps serving retained folders until it publishes.
  const auto ticket = catalog.BeginScan({"one"});
  Expect(catalog.Read(a, 0, 1).size() == 1, "retained folder keeps serving");
  Reject("FILE_NOT_FOUND", [&] { catalog.Read(b, 0, 1); });
  // A newer scan or clear cancels an older one.
  const auto newer = catalog.BeginScan({"one"});
  Reject("SCAN_CANCELLED", [&] { catalog.Scan({{"one", temp / "one", "One"}}, ticket); });
  Expect(catalog.Read(a, 0, 1).size() == 1, "cancelled scan leaves the catalog");
  catalog.Scan({{"one", temp / "one", "One"}}, newer);
  catalog.Clear();
  Reject("FILE_NOT_FOUND", [&] { catalog.Read(a, 0, 1); });
  // A failed current scan leaves nothing servable.
  ScanOnce(catalog, {{"one", temp / "one", "One"}});
  Reject("FILE_NOT_FOUND", [&] {
    ScanOnce(catalog, {{"one", temp / "one", "One"}, {"missing", temp / "missing", "M"}});
  });
  Reject("FILE_NOT_FOUND", [&] { catalog.Read(a, 0, 1); });
}

struct PrivateRoots {
  TempDirectory temp;
  std::string staging = temp / "staging";
  std::string destination = temp / "Pictures";
  PrivateRoots() {
    MakeDirectory(staging + "/task");
    MakeDirectory(destination);
  }
};

void TestSaveOrderedParts() {
  for (const bool anonymous : {true, false}) {
    SetAnonymousSavesForTesting(anonymous);
    PrivateRoots roots;
    const auto one = Pattern(1000, 1), two = Pattern(5000, 2), three = Pattern(1, 3);
    WriteFile(roots.staging + "/task/0.part", one);
    WriteFile(roots.staging + "/task/1.part", two);
    WriteFile(roots.staging + "/task/2.part", three);
    MakeDirectory(roots.destination + "/Phone/相册");
    WriteText(roots.destination + "/Phone/相册/photo.jpg", "existing");
    const auto saved = SaveDownload(
        {roots.staging + "/task/0.part", roots.staging + "/task/1.part",
         roots.staging + "/task/2.part"},
        6001, {roots.staging}, roots.destination, {"Phone", "相册"}, "photo.jpg");
    Expect(saved == roots.destination + "/Phone/相册/photo (1).jpg",
           "existing file is never replaced: " + saved);
    Bytes expected = one;
    expected.insert(expected.end(), two.begin(), two.end());
    expected.insert(expected.end(), three.begin(), three.end());
    Expect(ReadFile(saved) == expected, "parts are written in order");
    const auto existing = ReadFile(roots.destination + "/Phone/相册/photo.jpg");
    Expect(std::string(existing.begin(), existing.end()) == "existing", "original kept");
    WriteFile(roots.staging + "/task/empty.part", {});
    const auto empty = SaveDownload({roots.staging + "/task/empty.part"}, 0,
                                    {roots.staging}, roots.destination, {}, "empty.png");
    Expect(ReadFile(empty).empty(), "zero-byte media");
  }
  SetAnonymousSavesForTesting(true);
}

void TestSaveRejectsInvalidSources() {
  for (const bool anonymous : {true, false}) {
    SetAnonymousSavesForTesting(anonymous);
    PrivateRoots roots;
    WriteFile(roots.staging + "/task/0.part", Pattern(100));
    WriteFile(roots.temp / "outside.part", Pattern(100));
    Expect(symlink((roots.temp / "outside.part").c_str(),
                   (roots.staging + "/task/link.part").c_str()) == 0,
           "staged link fixture");
    const auto save = [&](const std::vector<std::string>& sources, int64_t size,
                          const std::vector<std::string>& folders = {},
                          const std::string& name = "a.jpg") {
      return SaveDownload(sources, size, {roots.staging}, roots.destination, folders, name);
    };
    Reject("INVALID_ARGUMENT", [&] { save({roots.temp / "outside.part"}, 100); });
    Reject("INVALID_ARGUMENT", [&] { save({roots.staging + "/task/link.part"}, 100); });
    Reject("INVALID_ARGUMENT", [&] { save({roots.staging}, 100); });
    Reject("INVALID_ARGUMENT", [&] { save({}, 0); });
    Reject("INVALID_ARGUMENT", [&] { save({roots.staging + "/task/0.part"}, -1); });
    Reject("FILE_CHANGED", [&] { save({roots.staging + "/task/0.part"}, 99); });
    Reject("FILE_CHANGED", [&] { save({roots.staging + "/task/0.part"}, 101); });
    Reject("INVALID_ARGUMENT", [&] { save({roots.staging + "/task/0.part"}, 100, {".."}); });
    Reject("INVALID_ARGUMENT", [&] { save({roots.staging + "/task/0.part"}, 100, {}, "a/b.jpg"); });
    Reject("FILE_NOT_FOUND", [&] { save({roots.staging + "/task/missing.part"}, 100); });
    Expect(symlink((roots.temp / "outside").c_str(), (roots.destination + "/Linked").c_str()) == 0,
           "destination link fixture");
    MakeDirectory(roots.temp / "outside");
    Reject("INVALID_ARGUMENT",
           [&] { save({roots.staging + "/task/0.part"}, 100, {"Linked"}); });
    std::vector<std::string> names;
    GDir* listing = g_dir_open(roots.destination.c_str(), 0, nullptr);
    while (const gchar* name = g_dir_read_name(listing)) names.emplace_back(name);
    g_dir_close(listing);
    Expect(names == std::vector<std::string>{"Linked"},
           "failed saves leave no files behind");
    Expect(!Exists(roots.temp / "outside/a.jpg"), "nothing written through a link");
  }
  SetAnonymousSavesForTesting(true);
}

void TestConcurrentSavesNeverOverwrite() {
  for (const bool anonymous : {true, false}) {
    SetAnonymousSavesForTesting(anonymous);
    PrivateRoots roots;
    constexpr int kCount = 8;
    for (int index = 0; index < kCount; ++index) {
      WriteFile(roots.staging + "/task/" + std::to_string(index) + ".part",
                Pattern(4096, static_cast<uint8_t>(index)));
    }
    std::vector<std::string> saved(kCount);
    std::atomic<int> failures{0};
    std::vector<std::thread> threads;
    for (int index = 0; index < kCount; ++index) {
      threads.emplace_back([&, index] {
        try {
          saved[index] = SaveDownload(
              {roots.staging + "/task/" + std::to_string(index) + ".part"}, 4096,
              {roots.staging}, roots.destination, {"Peer"}, "same.jpg");
        } catch (...) {
          ++failures;
        }
      });
    }
    for (auto& thread : threads) thread.join();
    Expect(failures == 0, "every concurrent save succeeds");
    std::set<std::string> unique(saved.begin(), saved.end());
    Expect(unique.size() == kCount, "concurrent saves use distinct names");
    for (int index = 0; index < kCount; ++index) {
      Expect(ReadFile(saved[index]) == Pattern(4096, static_cast<uint8_t>(index)),
             "each save keeps its own content");
    }
  }
  SetAnonymousSavesForTesting(true);
}

void TestDeleteDownload() {
  TempDirectory temp;
  MakeDirectory(temp / "Pictures/Peer");
  WriteFile(temp / "Pictures/Peer/a.jpg", Pattern(10));
  DeleteDownload(temp / "Pictures/Peer/a.jpg");
  Expect(!Exists(temp / "Pictures/Peer/a.jpg"), "file deleted");
  DeleteDownload(temp / "Pictures/Peer/a.jpg");
  DeleteDownload(temp / "Pictures/Missing/a.jpg");
  Reject("INVALID_ARGUMENT", [&] { DeleteDownload(temp / "Pictures/Peer"); });
  WriteFile(temp / "target.jpg", Pattern(10));
  Expect(symlink((temp / "target.jpg").c_str(), (temp / "Pictures/link.jpg").c_str()) == 0,
         "link fixture");
  Reject("INVALID_ARGUMENT", [&] { DeleteDownload(temp / "Pictures/link.jpg"); });
  Expect(Exists(temp / "target.jpg"), "link target kept");
  Reject("INVALID_ARGUMENT", [] { DeleteDownload("relative/a.jpg"); });
  Reject("INVALID_ARGUMENT", [] { DeleteDownload("/"); });
  if (!RunningAsRoot()) {
    WriteFile(temp / "Pictures/Peer/kept.jpg", Pattern(10));
    chmod((temp / "Pictures/Peer").c_str(), 0500);
    Reject("PERMISSION_LOST", [&] { DeleteDownload(temp / "Pictures/Peer/kept.jpg"); });
    chmod((temp / "Pictures/Peer").c_str(), 0700);
    Expect(Exists(temp / "Pictures/Peer/kept.jpg"), "failed delete keeps the file");
  }
}

void TestTransferSpace() {
  TempDirectory temp;
  MakeDirectory(temp / "a");
  MakeDirectory(temp / "b");
  const auto space = TransferSpace(temp / "a", temp / "b");
  Expect(space.staging_available_bytes && *space.staging_available_bytes >= 0 &&
             space.destination_available_bytes,
         "available bytes reported");
  Expect(space.same_volume && *space.same_volume, "same file system");
  struct stat shm {};
  struct stat tmp {};
  if (stat("/dev/shm", &shm) == 0 && stat(temp.path().c_str(), &tmp) == 0 &&
      shm.st_dev != tmp.st_dev) {
    const auto other = TransferSpace(temp / "a", "/dev/shm");
    Expect(other.same_volume && !*other.same_volume, "different file systems");
  }
  Reject("FILE_NOT_FOUND", [&] { TransferSpace(temp / "missing", temp / "b"); });
}

void TestPrivateDirectories() {
  TempDirectory temp;
  const auto created = PrivateDirectoryIn(temp / "data", "transfers");
  Expect(created == temp / "data/tamayura/transfers", "private layout: " + created);
  struct stat info {};
  Expect(stat(created.c_str(), &info) == 0 && (info.st_mode & 0777) == 0700,
         "private permissions");
  Expect(PrivateDirectoryIn(temp / "data", "transfers") == created, "idempotent");
  MakeDirectory(temp / "real");
  Expect(symlink((temp / "real").c_str(), (temp / "linked").c_str()) == 0, "base link");
  Expect(PrivateDirectoryIn(temp / "linked", "media") == temp / "real/tamayura/media",
         "base folder resolved before pinning");
  Reject("STAGING_UNAVAILABLE", [] { PrivateDirectoryIn("relative", "media"); });
  WriteFile(temp / "data/tamayura/databases", Pattern(1));
  Reject("STAGING_UNAVAILABLE", [&] { PrivateDirectoryIn(temp / "data", "databases"); });
}

void TestSafeFileRejectsSpecialFiles() {
  TempDirectory temp;
  Expect(mkfifo((temp / "pipe.jpg").c_str(), 0600) == 0, "FIFO fixture");
  Reject("FILE_NOT_FOUND", [&] { SafeFile::Open(temp / "pipe.jpg"); });
  MakeDirectory(temp / "folder.jpg");
  Reject("FILE_NOT_FOUND", [&] { SafeFile::Open(temp / "folder.jpg"); });
  Reject("FILE_NOT_FOUND", [&] { SafeFile::Open(temp / "missing.jpg"); });
  WriteFile(temp / "a.jpg", Pattern(10));
  const auto file = SafeFile::Open(temp / "a.jpg");
  Expect(file.path() == temp / "a.jpg" && file.info().size == 10, "regular file");
}

}  // namespace

int main() {
  return RunTests("storage", {
      {"peer name and relative path rules", TestNameRules},
      {"local path normalization", TestLocalPaths},
      {"received names fit Linux limits", TestReceivedNames},
      {"media types and stable identifiers", TestMediaTypes},
      {"scan shares only ordinary nameable media", TestScanRules},
      {"unreadable children are skipped, unreadable roots fail",
       TestUnreadableChildrenAreSkipped},
      {"folder overlap, root and link validation", TestFolderValidation},
      {"range reads are bounded and detect changes", TestRangeReads},
      {"replaced files and folders are never followed", TestLinksAreNeverFollowed},
      {"rescans, cancellation and revocation", TestCatalogLifecycle},
      {"saves write ordered parts without overwriting", TestSaveOrderedParts},
      {"saves reject sources outside private storage", TestSaveRejectsInvalidSources},
      {"concurrent saves never overwrite", TestConcurrentSavesNeverOverwrite},
      {"deletes only regular received files", TestDeleteDownload},
      {"transfer space and volume identity", TestTransferSpace},
      {"private directories", TestPrivateDirectories},
      {"special files are not media", TestSafeFileRejectsSpecialFiles},
  });
}
