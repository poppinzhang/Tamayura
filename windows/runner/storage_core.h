#ifndef TAMAYURA_STORAGE_CORE_H_
#define TAMAYURA_STORAGE_CORE_H_

#include <windows.h>

#include <cstdint>
#include <condition_variable>
#include <exception>
#include <functional>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace tamayura {

class StorageError : public std::runtime_error {
 public:
  StorageError(std::string error_code, const std::string& message)
      : std::runtime_error(message), code(std::move(error_code)) {}
  const std::string code;
};

using Bytes = std::vector<uint8_t>;

std::wstring Wide(const std::string& value);
std::string Utf8(const std::wstring& value);
void ValidateSegment(const std::string& value);
std::vector<std::string> RelativeComponents(const std::string& value);
std::wstring LocalPath(const std::string& value);
bool ContainsPath(const std::wstring& root, const std::wstring& child);
std::wstring JoinPath(const std::wstring& parent, const std::wstring& name);
std::string AvailableName(const std::string& name, unsigned attempt);
std::string ReceivedName(const std::string& name);
std::string MediaMime(const std::wstring& path);
std::string StableMediaId(const std::string& folder_id,
                          const std::string& relative_path);
std::wstring PrivateDirectory(const std::wstring& name);

class Handle {
 public:
  explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value_(value) {}
  ~Handle();
  Handle(Handle&& other) noexcept;
  Handle& operator=(Handle&& other) noexcept;
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }
  void reset();

 private:
  HANDLE value_;
};

struct FileInfo {
  int64_t size;
  int64_t modified_ms;
};

// Largest media range read in one call; matches mediaReadChunkBytes in Dart.
constexpr int64_t kMaxReadChunkBytes = 2 * 1024 * 1024;

// Every component is held without FILE_SHARE_WRITE or FILE_SHARE_DELETE.
// This prevents junction replacement, directory renames and file mutation while
// an operation is in progress. All components reject reparse points.
class SafeFile {
 public:
  static SafeFile Open(const std::wstring& path);
  HANDLE handle() const { return file_.get(); }
  const std::wstring& path() const { return path_; }
  FileInfo info() const;
  Bytes Read(int64_t offset, int64_t length, int64_t expected_size) const;

 private:
  SafeFile(std::wstring path, std::vector<Handle> parents, Handle file)
      : path_(std::move(path)), parents_(std::move(parents)),
        file_(std::move(file)) {}
  std::wstring path_;
  std::vector<Handle> parents_;
  Handle file_;
};

struct SharedDirectory {
  std::string id;
  std::string uri;
  std::string name;
};

struct MediaEntry {
  std::string id;
  std::string name;
  std::string mime_type;
  int64_t size;
  int64_t modified_ms;
  std::string shared_folder_id;
  std::string shared_folder_name;
  std::string relative_path;
  std::wstring path;
  // The pinned shared folder; its access failures are never per-file.
  std::wstring root;
};

class MediaCatalog {
 public:
  // Source previews are process-local; zero limits disable retained entries.
  explicit MediaCatalog(size_t thumbnail_max_bytes = 32 * 1024 * 1024,
                        size_t thumbnail_max_entries = 4096,
                        std::function<void()> before_catalog_publish = {})
      : thumbnail_max_bytes_(thumbnail_max_bytes),
        thumbnail_max_entries_(thumbnail_max_entries),
        before_catalog_publish_(std::move(before_catalog_publish)) {}
  // Stops serving every file and cancels running scans.
  uint64_t Clear();
  // Starts a rescan while the previous catalog keeps serving, so peers'
  // transfers survive a refresh. Folders no longer shared stop at once.
  uint64_t BeginScan(const std::set<std::string>& shared_folder_ids);
  void AssertScan(uint64_t ticket) const;
  void Validate(const std::string& uri,
                const std::vector<std::string>& existing) const;
  // A failed current scan leaves nothing servable, as a revoked folder would.
  // Files and subfolders that cannot be named or opened are skipped; only an
  // unreadable shared folder fails the scan.
  std::vector<MediaEntry> Scan(const std::vector<SharedDirectory>& directories,
                             uint64_t ticket,
                             const std::wstring& cache_path = {});
  // Restores only a complete cache for exactly these shared folders. Source
  // files are checked when read, so restoring never walks the directory tree.
  // A missing/configuration-mismatched cache returns nullopt. Unreadable,
  // corrupt or unsupported caches are reported without deleting their bytes.
  std::optional<std::vector<MediaEntry>> Restore(
      const std::vector<SharedDirectory>& directories, uint64_t ticket,
      const std::wstring& cache_path);
  std::optional<std::pair<std::string, std::string>> CatalogWarning() const;
  void ReportCatalogWarning(uint64_t ticket, const std::string& code,
                            const std::string& message);
  Bytes Read(const std::string& id, int64_t offset, int64_t length);
  Bytes WithMedia(const std::string& id,
                  const std::function<Bytes(const MediaEntry&, const SafeFile&)>&
                      operation);
  // Like macOS: a missing or changed file, or a preview that cannot be
  // decoded, yields empty bytes so one file cannot block a peer's catalog.
  // Shared-folder, permission, sharing, I/O and catalog errors still throw.
  // Every request checks file/root access before using the bounded LRU cache.
  // Concurrent requests for an unchanged file share one generation operation.
  Bytes Thumbnail(const std::string& id,
                  const std::function<Bytes(const MediaEntry&, const SafeFile&)>&
                      generate);

 private:
  struct ThumbnailEntry {
    MediaEntry source;
    Bytes bytes;
    std::list<std::string>::iterator recent;
  };
  struct ThumbnailFlight {
    MediaEntry source;
    uint64_t generation = 0;
    std::condition_variable ready;
    bool done = false;
    Bytes bytes;
    std::exception_ptr error;
  };
  static bool SameSource(const MediaEntry& left, const MediaEntry& right);
  void PruneThumbnailsLocked();
  void EraseThumbnailLocked(const std::string& id);
  void CacheThumbnailLocked(const MediaEntry& source, const Bytes& bytes);
  void RevokePublishedLocked();
  void RevokeLocked();
  // A read may finish only while sharing continues and its file stays published.
  void AssertCurrent(const std::string& id, const MediaEntry& entry,
                     uint64_t generation) const;
  void AssertCurrentLocked(const std::string& id, const MediaEntry& entry,
                           uint64_t generation) const;

  mutable std::mutex mutex_;
  // Cache reads, encoding and temporary writes run without mutex_. Only the
  // final atomic rename and publication hold it together, so a late writer
  // cannot replace a newer scan or persist after clear has returned.
  std::map<std::wstring, std::pair<std::string, std::string>> protected_cache_files_;
  std::optional<std::pair<std::string, std::string>> catalog_warning_;
  // Revoking sharing (including a failed/missing restore) ends existing reads.
  uint64_t generation_ = 0;
  // The latest scan; starting another scan or clearing cancels older ones.
  uint64_t ticket_ = 0;
  std::map<std::string, MediaEntry> files_;
  const size_t thumbnail_max_bytes_;
  const size_t thumbnail_max_entries_;
  size_t thumbnail_bytes_ = 0;
  std::list<std::string> thumbnail_recent_;
  std::map<std::string, ThumbnailEntry> thumbnails_;
  std::map<std::string, std::shared_ptr<ThumbnailFlight>> thumbnail_flights_;
  // Optional synchronization seam for deterministic publication/cancel tests.
  const std::function<void()> before_catalog_publish_;
};

std::wstring ValidateDirectory(const std::string& path);
struct TransferSpaceInfo {
  std::optional<int64_t> staging_available_bytes;
  std::optional<int64_t> destination_available_bytes;
  std::optional<bool> same_volume;
};
TransferSpaceInfo TransferSpace(const std::wstring& staging,
                               const std::string& destination);
std::wstring SaveDownload(const std::vector<std::string>& sources,
                          int64_t expected_size,
                          const std::vector<std::wstring>& allowed_roots,
                          const std::string& destination,
                          const std::vector<std::string>& directories,
                          const std::string& name);
void DeleteDownload(const std::string& uri);
Bytes JpegPreview(const SafeFile& file, unsigned maximum, bool video);

}  // namespace tamayura

#endif  // TAMAYURA_STORAGE_CORE_H_
