#ifndef TAMAYURA_STORAGE_CORE_H_
#define TAMAYURA_STORAGE_CORE_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <map>
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
};

class MediaCatalog {
 public:
  // Stops serving every file and cancels running scans.
  uint64_t Clear();
  // Starts a rescan while the previous catalog keeps serving, so peers'
  // transfers survive a refresh. Folders no longer shared stop at once.
  uint64_t BeginScan(const std::set<std::string>& shared_folder_ids);
  void AssertScan(uint64_t ticket) const;
  void Validate(const std::string& uri,
                const std::vector<std::string>& existing) const;
  // A failed current scan leaves nothing servable, as a revoked folder would.
  std::vector<MediaEntry> Scan(const std::vector<SharedDirectory>& directories,
                             uint64_t ticket);
  Bytes Read(const std::string& id, int64_t offset, int64_t length);
  Bytes WithMedia(const std::string& id,
                  const std::function<Bytes(const MediaEntry&, const SafeFile&)>&
                      operation);

 private:
  void RevokeLocked();
  // A read may finish only while sharing continues and its file stays published.
  void AssertCurrent(const std::string& id, const MediaEntry& entry,
                     uint64_t generation) const;

  mutable std::mutex mutex_;
  // Changes only when sharing stops or a scan fails; every read then ends.
  uint64_t generation_ = 0;
  // The latest scan; starting another scan or clearing cancels older ones.
  uint64_t ticket_ = 0;
  std::map<std::string, MediaEntry> files_;
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
Bytes JpegPreview(const SafeFile& file, unsigned maximum, bool video);

}  // namespace tamayura

#endif  // TAMAYURA_STORAGE_CORE_H_
