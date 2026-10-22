#ifndef TAMAYURA_STORAGE_CORE_H_
#define TAMAYURA_STORAGE_CORE_H_

#include <sys/types.h>

#include <condition_variable>
#include <cstdint>
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

#include "app_text.h"

namespace tamayura {

class StorageError : public std::runtime_error {
 public:
  StorageError(std::string error_code, const std::string& message)
      : std::runtime_error(message), code(std::move(error_code)) {}
  // The message is localized when the error is created.
  StorageError(std::string error_code, TextId text)
      : StorageError(std::move(error_code), app_text::Text(text)) {}
  const std::string code;
};

using Bytes = std::vector<uint8_t>;

// Largest media range read in one call; matches mediaReadChunkBytes in Dart.
constexpr int64_t kMaxReadChunkBytes = 2 * 1024 * 1024;
// Local paths and peer-visible relative paths are limited to PATH_MAX bytes.
constexpr size_t kMaxPathBytes = 4096;
// Linux file systems limit one name to 255 bytes.
constexpr size_t kMaxNameBytes = 255;

// Classifies errno before looking up the localized message, which may itself
// change errno. A symbolic link reached through O_NOFOLLOW is rejected.
[[noreturn]] void ThrowSystemError(TextId text, int error);

bool IsUtf8(const std::string& value);
// A name that peers can store: UTF-8 without control characters, separators
// or backslashes, not "." or "..", and at most 255 bytes.
void ValidateSegment(const std::string& value);
// A relative media path as defined by mediaPathSegments in Dart.
std::vector<std::string> RelativeComponents(const std::string& value);
// An absolute local path without "." / ".." or empty components. Trailing
// separators are removed. Local paths never travel to peers.
std::string LocalPath(const std::string& value);
std::vector<std::string> LocalComponents(const std::string& path);
bool ContainsPath(const std::string& root, const std::string& child);
std::string JoinPath(const std::string& parent, const std::string& name);
std::string ParentPath(const std::string& path);
std::string BaseName(const std::string& path);
// Fits a peer-supplied file or folder name into one Linux name, keeping the
// extension; other storage rules still apply as for any segment.
std::string ReceivedName(const std::string& name);
// "name (n).ext", shortened so that the suffix still fits in one name.
std::string AvailableName(const std::string& name, unsigned attempt);
std::string MediaMime(const std::string& name);
bool IsRawMime(const std::string& mime);
bool IsVideoMime(const std::string& mime);
std::string StableMediaId(const std::string& folder_id,
                          const std::string& relative_path);

class Fd {
 public:
  explicit Fd(int value = -1) : value_(value) {}
  ~Fd();
  Fd(Fd&& other) noexcept;
  Fd& operator=(Fd&& other) noexcept;
  Fd(const Fd&) = delete;
  Fd& operator=(const Fd&) = delete;
  int get() const { return value_; }
  int release();
  void reset(int value = -1);
  explicit operator bool() const { return value_ >= 0; }

 private:
  int value_;
};

struct FileIdentity {
  dev_t device = 0;
  ino_t inode = 0;
  bool operator==(const FileIdentity& other) const {
    return device == other.device && inode == other.inode;
  }
  bool operator<(const FileIdentity& other) const {
    return device != other.device ? device < other.device
                                  : inode < other.inode;
  }
};

// A directory reached from "/" one component at a time without following a
// symbolic link. Later operations stay relative to `fd` (an O_PATH
// descriptor), so renaming or replacing an ancestor cannot redirect them.
// `chain` identifies every directory from "/" to this one, which also detects
// aliases created by bind mounts.
struct PinnedDirectory {
  std::string path;
  Fd fd;
  std::vector<FileIdentity> chain;
};

PinnedDirectory PinDirectory(const std::string& path);
PinnedDirectory ChildDirectory(const PinnedDirectory& parent,
                               const std::string& name, bool create,
                               mode_t mode = 0755);
// Opens the pinned directory again with read access, for listing or fsync.
Fd ReadableDirectory(const PinnedDirectory& directory);

struct FileInfo {
  int64_t size = 0;
  int64_t modified_ms = 0;
  int64_t modified_seconds = 0;
  FileIdentity identity;
};

// A regular file opened without following a symbolic link.
class SafeFile {
 public:
  static SafeFile Open(const std::string& path);
  static SafeFile OpenAt(const PinnedDirectory& parent,
                         const std::string& name);
  SafeFile(SafeFile&&) = default;
  SafeFile& operator=(SafeFile&&) = default;
  int fd() const { return fd_.get(); }
  const std::string& path() const { return path_; }
  FileInfo info() const;
  // A peer range: at most kMaxReadChunkBytes from an unchanged file.
  Bytes Read(int64_t offset, int64_t length, int64_t expected_size) const;
  // Reads up to `length` bytes; returns fewer only at the end of the file.
  size_t ReadAt(int64_t offset, uint8_t* buffer, size_t length) const;

 private:
  SafeFile(std::string path, Fd fd) : path_(std::move(path)), fd_(std::move(fd)) {}
  std::string path_;
  Fd fd_;
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
  int64_t size = 0;
  int64_t modified_ms = 0;
  std::string shared_folder_id;
  std::string shared_folder_name;
  std::string relative_path;
  // Local paths stay on this device; peers only see the opaque id.
  std::string path;
  // The shared folder; its access failures are never per-file.
  std::string root;
};

class MediaCatalog {
 public:
  // Source previews are process-local; zero limits disable retained entries.
  explicit MediaCatalog(size_t thumbnail_max_bytes = 32 * 1024 * 1024,
                        size_t thumbnail_max_entries = 4096)
      : thumbnail_max_bytes_(thumbnail_max_bytes),
        thumbnail_max_entries_(thumbnail_max_entries) {}
  // Stops serving every file and cancels running scans.
  uint64_t Clear();
  // Starts a rescan while the previous catalog keeps serving, so peers'
  // transfers survive a refresh. Folders no longer shared stop at once.
  uint64_t BeginScan(const std::set<std::string>& shared_folder_ids);
  void AssertScan(uint64_t ticket) const;
  // Rejects the file system root and folders that repeat or contain one
  // another, including aliases through bind mounts.
  void Validate(const std::string& uri,
                const std::vector<std::string>& existing) const;
  // A failed current scan leaves nothing servable, as a revoked folder would.
  // Files and subfolders that cannot be named or opened are skipped; only an
  // unreadable shared folder fails the scan.
  std::vector<MediaEntry> Scan(const std::vector<SharedDirectory>& directories,
                               uint64_t ticket);
  Bytes Read(const std::string& id, int64_t offset, int64_t length);
  Bytes WithMedia(
      const std::string& id,
      const std::function<Bytes(const MediaEntry&, const SafeFile&)>& operation);
  // A missing or changed file, or a preview that cannot be decoded, yields
  // empty bytes so one file cannot block a peer's catalog. Shared-folder,
  // permission, I/O and catalog errors still throw. Every request checks the
  // file and its shared folder before using the bounded LRU cache, and
  // concurrent requests for an unchanged file share one generation.
  Bytes Thumbnail(
      const std::string& id,
      const std::function<Bytes(const MediaEntry&, const SafeFile&)>& generate);

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
  void RevokeLocked();
  // A read may finish only while sharing continues and its file stays
  // published.
  void AssertCurrent(const std::string& id, const MediaEntry& entry,
                     uint64_t generation) const;
  void AssertCurrentLocked(const std::string& id, const MediaEntry& entry,
                           uint64_t generation) const;

  mutable std::mutex mutex_;
  // Changes only when sharing stops or a scan fails; every read then ends.
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
};

// Resolves a folder chosen in the picker to its canonical path and checks
// that it can be pinned.
std::string ValidateDirectory(const std::string& path);

struct TransferSpaceInfo {
  std::optional<int64_t> staging_available_bytes;
  std::optional<int64_t> destination_available_bytes;
  std::optional<bool> same_volume;
};
TransferSpaceInfo TransferSpace(const std::string& staging,
                                const std::string& destination);

// Writes the ordered parts into a new file below `destination`. The file is
// published under a name that does not exist yet, so no existing file is ever
// replaced; a failed save leaves no partial file behind. Complete output paths,
// including collision suffixes, must fit PATH_MAX with their terminating NUL.
std::string SaveDownload(const std::vector<std::string>& sources,
                         int64_t expected_size,
                         const std::vector<std::string>& allowed_roots,
                         const std::string& destination,
                         const std::vector<std::string>& directories,
                         const std::string& name);
// Native tests use the exclusive-name path taken on file systems without
// O_TMPFILE, such as FAT, exFAT and most network or FUSE mounts.
void SetAnonymousSavesForTesting(bool enabled);
// Missing files are already deleted; other storage errors are reported.
void DeleteDownload(const std::string& path);

// Creates `<base>/tamayura/<name>` with private permissions below a
// canonical base directory and returns its path.
std::string PrivateDirectoryIn(const std::string& base,
                               const std::string& name);
enum class PrivateArea { kCache, kTransfers, kDatabases, kThumbnails };
std::string PrivateDirectory(PrivateArea area);

}  // namespace tamayura

#endif  // TAMAYURA_STORAGE_CORE_H_
