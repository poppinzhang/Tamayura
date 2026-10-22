#include "storage_core.h"

#include <dirent.h>
#include <fcntl.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <limits>

namespace tamayura {
namespace {

const char* ErrorCode(int error) {
  switch (error) {
    case ENOENT:
    case ENOTDIR:
      return "FILE_NOT_FOUND";
    case EACCES:
    case EPERM:
    case EROFS:
      return "PERMISSION_LOST";
    case ENOSPC:
    case EDQUOT:
      return "STORAGE_FULL";
    case EMFILE:
    case ENFILE:
    case ENOMEM:
      return "RESOURCE_EXHAUSTED";
    default:
      return "IO_ERROR";
  }
}

bool IsControl(gunichar character) {
  return character < 32 || (character >= 127 && character <= 159);
}

// Rejects separators and control characters in a valid UTF-8 name.
bool PeerCharacters(const std::string& value) {
  const char* end = value.data() + value.size();
  for (const char* cursor = value.data(); cursor < end;
       cursor = g_utf8_next_char(cursor)) {
    const gunichar character = g_utf8_get_char(cursor);
    if (character == '/' || character == '\\' || IsControl(character)) {
      return false;
    }
  }
  return true;
}

// The longest prefix of at most `limit` bytes that ends on a UTF-8 boundary.
std::string Utf8Prefix(const std::string& value, size_t limit) {
  if (value.size() <= limit) return value;
  size_t end = limit;
  while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xc0) == 0x80) {
    --end;
  }
  return value.substr(0, end);
}

// Splits "stem.ext" at the last dot; names starting with a dot have no
// extension, matching both other desktop implementations.
std::pair<std::string, std::string> SplitExtension(const std::string& name) {
  const auto dot = name.find_last_of('.');
  if (dot == std::string::npos || dot == 0) return {name, std::string()};
  return {name.substr(0, dot), name.substr(dot)};
}

FileIdentity Identity(int fd, TextId context) {
  struct stat info {};
  if (fstat(fd, &info) != 0) ThrowSystemError(context, errno);
  return {info.st_dev, info.st_ino};
}

void RequireName(const std::string& name) {
  if (name.empty() || name == "." || name == ".." ||
      name.find('/') != std::string::npos ||
      name.find('\0') != std::string::npos || name.size() > kMaxNameBytes) {
    throw StorageError("INVALID_ARGUMENT", TextId::kInvalidMediaName);
  }
}

// openat(2) with O_NOFOLLOW. A symbolic link gives a clear error rather than
// looking like a missing file.
int OpenComponent(int parent, const std::string& name, int flags,
                  TextId context) {
  const int fd = openat(parent, name.c_str(), flags | O_NOFOLLOW | O_CLOEXEC);
  if (fd >= 0) return fd;
  const int error = errno;
  struct stat info {};
  if ((error == ELOOP || error == ENOTDIR) &&
      fstatat(parent, name.c_str(), &info, AT_SYMLINK_NOFOLLOW) == 0 &&
      S_ISLNK(info.st_mode)) {
    throw StorageError("INVALID_ARGUMENT", TextId::kSymbolicLink);
  }
  ThrowSystemError(context, error);
}

void RequireDirectory(int fd) {
  struct stat info {};
  if (fstat(fd, &info) != 0) ThrowSystemError(TextId::kCannotAccess, errno);
  if (!S_ISDIR(info.st_mode)) {
    throw StorageError("FILE_NOT_FOUND", TextId::kCannotAccess);
  }
}

bool SameChain(const PinnedDirectory& left, const PinnedDirectory& right) {
  return left.chain.size() == right.chain.size() &&
         std::equal(left.chain.begin(), left.chain.end(), right.chain.begin());
}

// True when `ancestor` is `directory` itself or one of its parents.
bool HasAncestor(const PinnedDirectory& directory,
                 const PinnedDirectory& ancestor) {
  return std::find(directory.chain.begin(), directory.chain.end(),
                   ancestor.chain.back()) != directory.chain.end();
}

// A file or subfolder that vanished, is unreadable or cannot be named for
// peers is skipped. Cancellation and process-level failures end the scan.
bool SkippableScanError(const StorageError& error) {
  return error.code == "INVALID_ARGUMENT" || error.code == "FILE_NOT_FOUND" ||
         error.code == "PERMISSION_LOST" || error.code == "IO_ERROR";
}

// Deeper trees are skipped; this also bounds the descriptors held at once.
constexpr size_t kMaxScanDepth = 128;

void Enumerate(MediaCatalog& catalog, const SharedDirectory& shared,
               const std::string& root, const PinnedDirectory& directory,
               const std::string& relative, uint64_t ticket, size_t depth,
               std::set<FileIdentity>& visited,
               std::vector<MediaEntry>& output) {
  catalog.AssertScan(ticket);
  struct Child {
    std::string name;
    unsigned char type;
  };
  std::vector<Child> children;
  {
    Fd listing = ReadableDirectory(directory);
    DIR* stream = fdopendir(listing.get());
    if (!stream) ThrowSystemError(TextId::kCannotReadSharedDirectory, errno);
    listing.release();
    std::unique_ptr<DIR, int (*)(DIR*)> guard(stream, closedir);
    for (;;) {
      errno = 0;
      const dirent* entry = readdir(stream);
      if (!entry) {
        if (errno != 0) {
          ThrowSystemError(TextId::kCannotReadSharedDirectory, errno);
        }
        break;
      }
      // ".", ".." and hidden entries, as macOS skips hidden files.
      if (entry->d_name[0] == '.') continue;
      children.push_back({entry->d_name, entry->d_type});
    }
  }
  // The stream is closed before descending to bound open descriptors.
  std::sort(children.begin(), children.end(),
            [](const Child& left, const Child& right) {
              return left.name < right.name;
            });
  for (const auto& child : children) {
    catalog.AssertScan(ticket);
    unsigned char type = child.type;
    if (type == DT_UNKNOWN) {
      struct stat info {};
      if (fstatat(directory.fd.get(), child.name.c_str(), &info,
                  AT_SYMLINK_NOFOLLOW) != 0) {
        continue;
      }
      type = S_ISDIR(info.st_mode)   ? DT_DIR
             : S_ISREG(info.st_mode) ? DT_REG
                                     : DT_LNK;
    }
    // Symbolic links, devices, FIFOs and sockets are never shared.
    if (type != DT_DIR && type != DT_REG) continue;
    // Only media files and folders need a valid name; ignore anything else.
    if (type == DT_REG && MediaMime(child.name).empty()) continue;
    try {
      ValidateSegment(child.name);
      const auto child_relative =
          relative.empty() ? child.name : relative + "/" + child.name;
      RelativeComponents(child_relative);
      if (type == DT_DIR) {
        if (depth + 1 >= kMaxScanDepth) continue;
        const auto subdirectory = ChildDirectory(directory, child.name, false);
        // A bind mount can make a folder reachable from itself.
        if (!visited.insert(subdirectory.chain.back()).second) continue;
        Enumerate(catalog, shared, root, subdirectory, child_relative, ticket,
                  depth + 1, visited, output);
        continue;
      }
      const auto file = SafeFile::OpenAt(directory, child.name);
      const auto info = file.info();
      output.push_back({StableMediaId(shared.id, child_relative), child.name,
                        MediaMime(child.name), info.size, info.modified_ms,
                        shared.id, shared.name, child_relative, file.path(),
                        root});
    } catch (const StorageError& error) {
      if (!SkippableScanError(error)) throw;
    }
  }
}

void WriteAll(int fd, const uint8_t* data, size_t count) {
  size_t written = 0;
  while (written < count) {
    const ssize_t amount = write(fd, data + written, count - written);
    if (amount < 0 && errno == EINTR) continue;
    if (amount <= 0) {
      ThrowSystemError(TextId::kCannotSaveSpace, amount < 0 ? errno : EIO);
    }
    written += static_cast<size_t>(amount);
  }
}

// Copies exactly `size` bytes of one staged part and confirms that the part
// did not grow. Uses in-kernel copies (and reflinks) on one file system.
void CopyPart(int input, int64_t size, int output, bool same_device,
              std::vector<uint8_t>& buffer) {
  int64_t done = 0;
  if (same_device) {
    while (done < size) {
      loff_t input_offset = done;
      const auto request = static_cast<size_t>(
          std::min<int64_t>(size - done, int64_t{1} << 30));
      const ssize_t amount =
          copy_file_range(input, &input_offset, output, nullptr, request, 0);
      if (amount < 0 && errno == EINTR) continue;
      if (amount < 0 && (errno == ENOSPC || errno == EDQUOT)) {
        ThrowSystemError(TextId::kCannotSaveSpace, errno);
      }
      // Unsupported or short copies continue with ordinary reads and writes,
      // which also report the precise read or write failure.
      if (amount <= 0) break;
      done += amount;
    }
  }
  while (done < size) {
    const auto request = static_cast<size_t>(
        std::min<int64_t>(size - done, static_cast<int64_t>(buffer.size())));
    const ssize_t amount = pread(input, buffer.data(), request, done);
    if (amount < 0 && errno == EINTR) continue;
    if (amount < 0) ThrowSystemError(TextId::kCannotReadStaging, errno);
    if (amount == 0) throw StorageError("FILE_CHANGED", TextId::kPartsChanged);
    WriteAll(output, buffer.data(), static_cast<size_t>(amount));
    done += amount;
  }
  uint8_t extra = 0;
  for (;;) {
    const ssize_t amount = pread(input, &extra, 1, size);
    if (amount < 0 && errno == EINTR) continue;
    if (amount < 0) ThrowSystemError(TextId::kCannotReadStaging, errno);
    if (amount > 0) throw StorageError("FILE_CHANGED", TextId::kPartsChanged);
    break;
  }
}

std::atomic<bool> anonymous_saves{true};

void ValidateDownloadPath(const std::string& directory, const std::string& name) {
  // Descriptor-relative creation can exceed PATH_MAX, but the returned path
  // must also work with ordinary path APIs used by the desktop and other apps.
  // PATH_MAX includes the terminating NUL, unlike std::string::size().
  if (JoinPath(directory, name).size() >= kMaxPathBytes) {
    throw StorageError("PATH_TOO_LONG", TextId::kDownloadPathTooLong);
  }
}

std::string AbsoluteBase(const char* value) {
  if (!value || value[0] != '/') {
    throw StorageError("STAGING_UNAVAILABLE",
                       TextId::kPrivateDirectoryUnavailable);
  }
  return value;
}

}  // namespace

[[noreturn]] void ThrowSystemError(TextId text, int error) {
  if (error == ELOOP) {
    throw StorageError("INVALID_ARGUMENT", TextId::kSymbolicLink);
  }
  const char* code = ErrorCode(error);
  if (std::strcmp(code, "RESOURCE_EXHAUSTED") == 0) {
    throw StorageError(code, TextId::kResourcesExhausted);
  }
  throw StorageError(code, text);
}

bool IsUtf8(const std::string& value) {
  // With an explicit length, embedded NUL bytes are invalid.
  return g_utf8_validate(value.data(), static_cast<gssize>(value.size()),
                         nullptr);
}

void ValidateSegment(const std::string& value) {
  if (value.empty() || value.size() > kMaxNameBytes || value == "." ||
      value == ".." || !IsUtf8(value) || !PeerCharacters(value)) {
    throw StorageError("INVALID_ARGUMENT", TextId::kInvalidMediaName);
  }
}

std::vector<std::string> RelativeComponents(const std::string& value) {
  if (value.empty() || value.size() > kMaxPathBytes) {
    throw StorageError("INVALID_ARGUMENT", TextId::kInvalidRelativePath);
  }
  if (value.size() >= 2 && g_ascii_isalpha(value[0]) && value[1] == ':') {
    throw StorageError("INVALID_ARGUMENT", TextId::kDriveLetterPath);
  }
  std::vector<std::string> result;
  size_t start = 0;
  for (;;) {
    const auto slash = value.find('/', start);
    auto part = value.substr(
        start, slash == std::string::npos ? std::string::npos : slash - start);
    ValidateSegment(part);
    result.push_back(std::move(part));
    if (slash == std::string::npos) return result;
    start = slash + 1;
  }
}

std::string LocalPath(const std::string& value) {
  if (value.empty() || value[0] != '/' || value.size() > kMaxPathBytes ||
      !IsUtf8(value)) {
    throw StorageError("INVALID_ARGUMENT", TextId::kLocalPathRequired);
  }
  std::string normalized;
  size_t start = 1;
  while (start <= value.size()) {
    const auto slash = value.find('/', start);
    const auto end = slash == std::string::npos ? value.size() : slash;
    const auto part = value.substr(start, end - start);
    if (!part.empty()) {
      if (part == "." || part == ".." || part.size() > kMaxNameBytes) {
        throw StorageError("INVALID_ARGUMENT", TextId::kLocalPathRequired);
      }
      normalized += "/" + part;
    }
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  return normalized.empty() ? "/" : normalized;
}

std::vector<std::string> LocalComponents(const std::string& path) {
  std::vector<std::string> result;
  size_t start = 1;
  while (start < path.size()) {
    const auto slash = path.find('/', start);
    const auto end = slash == std::string::npos ? path.size() : slash;
    if (end > start) result.push_back(path.substr(start, end - start));
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  return result;
}

bool ContainsPath(const std::string& root, const std::string& child) {
  if (root.empty() || child.empty()) return false;
  if (root == "/") return child[0] == '/';
  if (child.size() < root.size() || child.compare(0, root.size(), root) != 0) {
    return false;
  }
  return child.size() == root.size() || child[root.size()] == '/';
}

std::string JoinPath(const std::string& parent, const std::string& name) {
  return parent == "/" ? "/" + name : parent + "/" + name;
}

std::string ParentPath(const std::string& path) {
  const auto slash = path.find_last_of('/');
  if (slash == std::string::npos || slash == 0) return "/";
  return path.substr(0, slash);
}

std::string BaseName(const std::string& path) {
  const auto slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string ReceivedName(const std::string& name) {
  // Components from peers are names, never paths.
  if (name.empty() || name == "." || name == ".." || !IsUtf8(name) ||
      !PeerCharacters(name)) {
    throw StorageError("INVALID_ARGUMENT", TextId::kInvalidMediaName);
  }
  if (name.size() <= kMaxNameBytes) return name;
  // Other systems count characters, not bytes; a long CJK name can exceed
  // Linux's limit. Shorten the stem and keep a reasonable extension.
  auto [stem, extension] = SplitExtension(name);
  if (extension.size() > 32) {
    stem = name;
    extension.clear();
  }
  auto fitted = Utf8Prefix(stem, kMaxNameBytes - extension.size()) + extension;
  ValidateSegment(fitted);
  return fitted;
}

std::string AvailableName(const std::string& name, unsigned attempt) {
  if (!attempt) return name;
  auto [stem, extension] = SplitExtension(name);
  const auto suffix = " (" + std::to_string(attempt) + ")";
  if (extension.size() + suffix.size() >= kMaxNameBytes) extension.clear();
  stem = Utf8Prefix(stem, kMaxNameBytes - suffix.size() - extension.size());
  return stem + suffix + extension;
}

std::string MediaMime(const std::string& name) {
  const auto dot = name.find_last_of('.');
  if (dot == std::string::npos || dot == 0) return {};
  std::string extension = name.substr(dot);
  for (auto& character : extension) {
    character = g_ascii_tolower(character);
  }
  static const std::map<std::string, std::string> types = {
      {".jpg", "image/jpeg"},        {".jpeg", "image/jpeg"},
      {".jpe", "image/jpeg"},        {".png", "image/png"},
      {".gif", "image/gif"},         {".bmp", "image/bmp"},
      {".webp", "image/webp"},       {".tif", "image/tiff"},
      {".tiff", "image/tiff"},       {".heic", "image/heic"},
      {".heif", "image/heif"},       {".avif", "image/avif"},
      {".dng", "image/x-adobe-dng"}, {".cr2", "image/x-canon-cr2"},
      {".nef", "image/x-nikon-nef"}, {".arw", "image/x-sony-arw"},
      {".mp4", "video/mp4"},         {".m4v", "video/x-m4v"},
      {".mov", "video/quicktime"},   {".avi", "video/x-msvideo"},
      {".mkv", "video/x-matroska"},  {".webm", "video/webm"},
      {".wmv", "video/x-ms-wmv"},    {".mpeg", "video/mpeg"},
      {".mpg", "video/mpeg"},        {".3gp", "video/3gpp"},
      {".3g2", "video/3gpp2"},       {".mts", "video/mp2t"},
      {".m2ts", "video/mp2t"}};
  const auto found = types.find(extension);
  return found == types.end() ? std::string() : found->second;
}

bool IsRawMime(const std::string& mime) {
  return mime == "image/x-adobe-dng" || mime == "image/x-canon-cr2" ||
         mime == "image/x-nikon-nef" || mime == "image/x-sony-arw";
}

bool IsVideoMime(const std::string& mime) {
  return mime.rfind("video/", 0) == 0;
}

std::string StableMediaId(const std::string& folder_id,
                          const std::string& relative_path) {
  std::string input = folder_id;
  input.push_back('\0');
  input += relative_path;
  gchar* digest = g_compute_checksum_for_data(
      G_CHECKSUM_SHA256, reinterpret_cast<const guchar*>(input.data()),
      input.size());
  if (!digest) throw StorageError("PLATFORM_ERROR", TextId::kOperationFailed);
  std::string result(digest);
  g_free(digest);
  return result;
}

Fd::~Fd() { reset(); }

Fd::Fd(Fd&& other) noexcept : value_(other.value_) { other.value_ = -1; }

Fd& Fd::operator=(Fd&& other) noexcept {
  if (this != &other) {
    reset();
    value_ = other.value_;
    other.value_ = -1;
  }
  return *this;
}

int Fd::release() {
  const int value = value_;
  value_ = -1;
  return value;
}

void Fd::reset(int value) {
  // close(2) must not be retried on Linux, even after EINTR.
  if (value_ >= 0) close(value_);
  value_ = value;
}

PinnedDirectory PinDirectory(const std::string& path) {
  const auto normal = LocalPath(path);
  PinnedDirectory result;
  result.path = "/";
  result.fd.reset(open("/", O_PATH | O_DIRECTORY | O_CLOEXEC));
  if (!result.fd) ThrowSystemError(TextId::kCannotAccess, errno);
  result.chain.push_back(Identity(result.fd.get(), TextId::kCannotAccess));
  for (const auto& component : LocalComponents(normal)) {
    // O_PATH also passes through folders that are traversable but not
    // listable, such as some parents of mounted media.
    Fd next(OpenComponent(result.fd.get(), component, O_PATH | O_DIRECTORY,
                          TextId::kCannotAccess));
    RequireDirectory(next.get());
    result.chain.push_back(Identity(next.get(), TextId::kCannotAccess));
    result.fd = std::move(next);
    result.path = JoinPath(result.path, component);
  }
  return result;
}

PinnedDirectory ChildDirectory(const PinnedDirectory& parent,
                               const std::string& name, bool create,
                               mode_t mode) {
  RequireName(name);
  if (create && mkdirat(parent.fd.get(), name.c_str(), mode) != 0 &&
      errno != EEXIST) {
    ThrowSystemError(TextId::kCannotCreateSubdirectory, errno);
  }
  Fd child(OpenComponent(
      parent.fd.get(), name, O_PATH | O_DIRECTORY,
      create ? TextId::kCannotCreateSubdirectory : TextId::kCannotAccess));
  RequireDirectory(child.get());
  PinnedDirectory result;
  result.path = JoinPath(parent.path, name);
  result.chain = parent.chain;
  result.chain.push_back(Identity(child.get(), TextId::kCannotAccess));
  result.fd = std::move(child);
  return result;
}

Fd ReadableDirectory(const PinnedDirectory& directory) {
  Fd readable(openat(directory.fd.get(), ".",
                     O_RDONLY | O_DIRECTORY | O_CLOEXEC));
  if (!readable) ThrowSystemError(TextId::kCannotReadSharedDirectory, errno);
  return readable;
}

SafeFile SafeFile::Open(const std::string& path) {
  const auto normal = LocalPath(path);
  if (normal == "/") throw StorageError("INVALID_ARGUMENT", TextId::kEmptyPath);
  const auto parent = PinDirectory(ParentPath(normal));
  return OpenAt(parent, BaseName(normal));
}

SafeFile SafeFile::OpenAt(const PinnedDirectory& parent,
                          const std::string& name) {
  RequireName(name);
  // O_NONBLOCK keeps a FIFO from blocking before info() rejects it.
  Fd fd(OpenComponent(parent.fd.get(), name, O_RDONLY | O_NONBLOCK | O_NOCTTY,
                      TextId::kCannotAccess));
  SafeFile file(JoinPath(parent.path, name), std::move(fd));
  file.info();
  return file;
}

FileInfo SafeFile::info() const {
  struct stat info {};
  if (fstat(fd_.get(), &info) != 0) {
    ThrowSystemError(TextId::kCannotReadMediaInfo, errno);
  }
  if (!S_ISREG(info.st_mode)) {
    throw StorageError("FILE_NOT_FOUND", TextId::kMediaMissing);
  }
  FileInfo result;
  result.size = static_cast<int64_t>(info.st_size);
  result.modified_seconds = static_cast<int64_t>(info.st_mtim.tv_sec);
  result.modified_ms = result.modified_seconds * 1000 +
                       static_cast<int64_t>(info.st_mtim.tv_nsec) / 1000000;
  result.identity = {info.st_dev, info.st_ino};
  return result;
}

Bytes SafeFile::Read(int64_t offset, int64_t length,
                     int64_t expected_size) const {
  if (offset < 0 || offset > expected_size || length < 0 ||
      length > kMaxReadChunkBytes) {
    throw StorageError("INVALID_ARGUMENT", TextId::kInvalidRange);
  }
  if (info().size != expected_size) {
    throw StorageError("FILE_CHANGED", TextId::kFileChanged);
  }
  const auto count = static_cast<size_t>(std::min(length, expected_size - offset));
  Bytes bytes(count);
  if (ReadAt(offset, bytes.data(), count) != count) {
    throw StorageError("FILE_CHANGED", TextId::kFileEnded);
  }
  return bytes;
}

size_t SafeFile::ReadAt(int64_t offset, uint8_t* buffer, size_t length) const {
  size_t read = 0;
  while (read < length) {
    const ssize_t amount =
        pread(fd_.get(), buffer + read, length - read,
              static_cast<off_t>(offset + static_cast<int64_t>(read)));
    if (amount < 0 && errno == EINTR) continue;
    if (amount < 0) ThrowSystemError(TextId::kCannotReadMediaInfo, errno);
    if (amount == 0) break;
    read += static_cast<size_t>(amount);
  }
  return read;
}

uint64_t MediaCatalog::Clear() {
  std::lock_guard<std::mutex> lock(mutex_);
  RevokeLocked();
  return ticket_;
}

bool MediaCatalog::SameSource(const MediaEntry& left, const MediaEntry& right) {
  return left.id == right.id && left.path == right.path &&
         left.root == right.root && left.size == right.size &&
         left.modified_ms == right.modified_ms;
}

void MediaCatalog::EraseThumbnailLocked(const std::string& id) {
  const auto found = thumbnails_.find(id);
  if (found == thumbnails_.end()) return;
  thumbnail_bytes_ -= found->second.bytes.size();
  thumbnail_recent_.erase(found->second.recent);
  thumbnails_.erase(found);
}

void MediaCatalog::PruneThumbnailsLocked() {
  for (auto cached = thumbnails_.begin(); cached != thumbnails_.end();) {
    const auto published = files_.find(cached->first);
    if (published != files_.end() &&
        SameSource(published->second, cached->second.source)) {
      ++cached;
    } else {
      const auto id = cached->first;
      ++cached;
      EraseThumbnailLocked(id);
    }
  }
  for (auto pending = thumbnail_flights_.begin();
       pending != thumbnail_flights_.end();) {
    const auto& flight = pending->second;
    const auto published = files_.find(pending->first);
    if (flight->generation == generation_ && published != files_.end() &&
        SameSource(published->second, flight->source)) {
      ++pending;
    } else {
      flight->error = std::make_exception_ptr(
          StorageError("SCAN_CANCELLED", TextId::kScanCancelled));
      flight->done = true;
      flight->ready.notify_all();
      pending = thumbnail_flights_.erase(pending);
    }
  }
}

void MediaCatalog::CacheThumbnailLocked(const MediaEntry& source,
                                        const Bytes& bytes) {
  // A peer rejects previews above 512 KiB; retaining those would only repeat
  // an unusable response and consume the source's memory budget.
  constexpr size_t kMaxThumbnailBytes = 512 * 1024;
  if (!thumbnail_max_bytes_ || !thumbnail_max_entries_ ||
      bytes.size() > thumbnail_max_bytes_ || bytes.size() > kMaxThumbnailBytes) {
    return;
  }
  EraseThumbnailLocked(source.id);
  while (!thumbnail_recent_.empty() &&
         (thumbnails_.size() >= thumbnail_max_entries_ ||
          bytes.size() > thumbnail_max_bytes_ - thumbnail_bytes_)) {
    EraseThumbnailLocked(thumbnail_recent_.back());
  }
  thumbnail_recent_.push_front(source.id);
  try {
    thumbnails_.emplace(source.id,
                        ThumbnailEntry{source, bytes, thumbnail_recent_.begin()});
  } catch (...) {
    thumbnail_recent_.pop_front();
    throw;
  }
  thumbnail_bytes_ += bytes.size();
}

uint64_t MediaCatalog::BeginScan(const std::set<std::string>& shared_folder_ids) {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto entry = files_.begin(); entry != files_.end();) {
    if (shared_folder_ids.count(entry->second.shared_folder_id)) {
      ++entry;
    } else {
      entry = files_.erase(entry);
    }
  }
  PruneThumbnailsLocked();
  return ++ticket_;
}

void MediaCatalog::RevokeLocked() {
  files_.clear();
  ++generation_;
  ++ticket_;
  PruneThumbnailsLocked();
}

void MediaCatalog::AssertScan(uint64_t ticket) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (ticket != ticket_) {
    throw StorageError("SCAN_CANCELLED", TextId::kScanCancelled);
  }
}

void MediaCatalog::AssertCurrent(const std::string& id, const MediaEntry& entry,
                                 uint64_t generation) const {
  std::lock_guard<std::mutex> lock(mutex_);
  AssertCurrentLocked(id, entry, generation);
}

void MediaCatalog::AssertCurrentLocked(const std::string& id,
                                       const MediaEntry& entry,
                                       uint64_t generation) const {
  const auto found = files_.find(id);
  if (generation != generation_ || found == files_.end() ||
      !SameSource(found->second, entry)) {
    throw StorageError("SCAN_CANCELLED", TextId::kScanCancelled);
  }
}

void MediaCatalog::Validate(const std::string& uri,
                            const std::vector<std::string>& existing) const {
  const auto candidate = PinDirectory(uri);
  if (candidate.path == "/") {
    throw StorageError("INVALID_ARGUMENT", TextId::kRootDirectory);
  }
  for (const auto& value : existing) {
    const auto previous = PinDirectory(value);
    if (HasAncestor(candidate, previous) || HasAncestor(previous, candidate) ||
        ContainsPath(candidate.path, previous.path) ||
        ContainsPath(previous.path, candidate.path)) {
      throw StorageError("DIR_OVERLAP", TextId::kDirectoryOverlap);
    }
  }
}

std::vector<MediaEntry> MediaCatalog::Scan(
    const std::vector<SharedDirectory>& directories, uint64_t expected) try {
  AssertScan(expected);
  std::set<std::string> ids;
  std::vector<std::string> previous;
  for (const auto& directory : directories) {
    ValidateSegment(directory.id);
    // Peers validate folder names as one relative path component.
    RelativeComponents(directory.name);
    if (directory.name.find('/') != std::string::npos) {
      throw StorageError("INVALID_ARGUMENT", TextId::kInvalidMediaName);
    }
    if (!ids.insert(directory.id).second) {
      throw StorageError("INVALID_ARGUMENT", TextId::kDuplicateDirectoryId);
    }
    Validate(directory.uri, previous);
    previous.push_back(directory.uri);
  }
  std::vector<MediaEntry> metadata;
  for (const auto& directory : directories) {
    // The shared folder itself must be readable; unreadable children are
    // skipped.
    const auto root = PinDirectory(directory.uri);
    std::set<FileIdentity> visited{root.chain.back()};
    Enumerate(*this, directory, root.path, root, "", expected, 0, visited,
              metadata);
    // If the folder moved, vanished or lost access mid-scan, its files were
    // skipped; fail instead of publishing that as every file being deleted.
    const auto again = PinDirectory(directory.uri);
    if (!SameChain(root, again)) {
      throw StorageError("FILE_NOT_FOUND", TextId::kCannotReadSharedDirectory);
    }
    ReadableDirectory(again);
  }
  std::map<std::string, MediaEntry> next;
  for (const auto& entry : metadata) next.emplace(entry.id, entry);
  std::lock_guard<std::mutex> lock(mutex_);
  if (expected != ticket_) {
    throw StorageError("SCAN_CANCELLED", TextId::kScanCancelled);
  }
  files_ = std::move(next);
  PruneThumbnailsLocked();
  return metadata;
} catch (...) {
  // The publishing lock is released during unwinding, before this handler.
  std::lock_guard<std::mutex> lock(mutex_);
  if (expected == ticket_) RevokeLocked();
  throw;
}

Bytes MediaCatalog::WithMedia(
    const std::string& id,
    const std::function<Bytes(const MediaEntry&, const SafeFile&)>& operation) {
  MediaEntry entry;
  uint64_t expected = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = files_.find(id);
    if (found == files_.end()) {
      throw StorageError("FILE_NOT_FOUND", TextId::kFileNotShared);
    }
    entry = found->second;
    expected = generation_;
  }
  const auto file = SafeFile::Open(entry.path);
  AssertCurrent(id, entry, expected);
  const auto info = file.info();
  if (info.size != entry.size || info.modified_ms != entry.modified_ms) {
    throw StorageError("FILE_CHANGED", TextId::kFileChanged);
  }
  auto result = operation(entry, file);
  AssertCurrent(id, entry, expected);
  return result;
}

Bytes MediaCatalog::Thumbnail(
    const std::string& id,
    const std::function<Bytes(const MediaEntry&, const SafeFile&)>& generate) {
  MediaEntry entry;
  uint64_t expected = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = files_.find(id);
    if (found == files_.end()) {
      throw StorageError("FILE_NOT_FOUND", TextId::kFileNotShared);
    }
    entry = found->second;
    expected = generation_;
  }
  // Shared-folder access errors affect every file, not one preview.
  ReadableDirectory(PinDirectory(entry.root));
  AssertCurrent(id, entry, expected);
  try {
    // Even cache hits open and check the source. A cached image cannot hide
    // a deleted or changed file, or a permission failure.
    const auto file = SafeFile::Open(entry.path);
    const auto info = file.info();
    if (info.size != entry.size || info.modified_ms != entry.modified_ms) {
      throw StorageError("FILE_CHANGED", TextId::kFileChanged);
    }
    std::shared_ptr<ThumbnailFlight> flight;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      AssertCurrentLocked(id, entry, expected);
      const auto cached = thumbnails_.find(id);
      if (cached != thumbnails_.end()) {
        thumbnail_recent_.splice(thumbnail_recent_.begin(), thumbnail_recent_,
                                 cached->second.recent);
        return cached->second.bytes;
      }
      const auto pending = thumbnail_flights_.find(id);
      if (pending != thumbnail_flights_.end()) {
        flight = pending->second;
        flight->ready.wait(lock, [&] { return flight->done; });
        AssertCurrentLocked(id, entry, expected);
        if (flight->error) std::rethrow_exception(flight->error);
        return flight->bytes;
      }
      flight = std::make_shared<ThumbnailFlight>();
      flight->source = entry;
      flight->generation = expected;
      thumbnail_flights_.emplace(id, flight);
    }
    try {
      Bytes result;
      try {
        result = generate(entry, file);
      } catch (const StorageError& error) {
        // An ordinary decoder failure is a valid empty preview for this
        // unchanged file. Access and I/O failures remain retryable.
        if (error.code != "PREVIEW_FAILED") throw;
      }
      std::lock_guard<std::mutex> lock(mutex_);
      AssertCurrentLocked(id, entry, expected);
      // Removal followed by republication can have identical file metadata;
      // a cancelled generation must still never repopulate the cache.
      if (flight->done) std::rethrow_exception(flight->error);
      CacheThumbnailLocked(entry, result);
      flight->bytes = std::move(result);
      flight->done = true;
      thumbnail_flights_.erase(id);
      flight->ready.notify_all();
      return flight->bytes;
    } catch (...) {
      const auto error = std::current_exception();
      std::lock_guard<std::mutex> lock(mutex_);
      if (!flight->done) {
        flight->error = error;
        flight->done = true;
        const auto pending = thumbnail_flights_.find(id);
        if (pending != thumbnail_flights_.end() && pending->second == flight) {
          thumbnail_flights_.erase(pending);
        }
        flight->ready.notify_all();
      }
      // Revocation wins over a late decoder failure as well as late bytes.
      std::rethrow_exception(flight->error ? flight->error : error);
    }
  } catch (const StorageError& error) {
    // Permission and other I/O failures may recover; they must not be cached
    // by peers as an empty preview.
    if (error.code != "FILE_NOT_FOUND" && error.code != "FILE_CHANGED" &&
        error.code != "PREVIEW_FAILED") {
      throw;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    AssertCurrentLocked(id, entry, expected);
    EraseThumbnailLocked(id);
    return {};
  }
}

Bytes MediaCatalog::Read(const std::string& id, int64_t offset, int64_t length) {
  return WithMedia(id, [=](const MediaEntry& entry, const SafeFile& file) {
    return file.Read(offset, length, entry.size);
  });
}

std::string ValidateDirectory(const std::string& path) {
  const auto requested = LocalPath(path);
  // The picker may return a path through a symbolic link, such as a home
  // directory below /var/home. Store the resolved folder.
  char* resolved = realpath(requested.c_str(), nullptr);
  if (!resolved) ThrowSystemError(TextId::kCannotAccess, errno);
  std::string canonical(resolved);
  free(resolved);
  const auto pinned = PinDirectory(canonical);
  ReadableDirectory(pinned);
  return pinned.path;
}

TransferSpaceInfo TransferSpace(const std::string& staging,
                                const std::string& destination) {
  const auto source = PinDirectory(staging);
  const auto target = PinDirectory(destination);
  auto available = [](const PinnedDirectory& directory) -> std::optional<int64_t> {
    struct statvfs info {};
    if (fstatvfs(directory.fd.get(), &info) != 0) return std::nullopt;
    const auto maximum = static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
    const uint64_t blocks = info.f_bavail;
    const uint64_t size = info.f_frsize ? info.f_frsize : info.f_bsize;
    if (size && blocks > maximum / size) return std::numeric_limits<int64_t>::max();
    return static_cast<int64_t>(blocks * size);
  };
  TransferSpaceInfo result{available(source), available(target), std::nullopt};
  result.same_volume = source.chain.back().device == target.chain.back().device;
  return result;
}

std::string SaveDownload(const std::vector<std::string>& sources,
                         int64_t expected_size,
                         const std::vector<std::string>& allowed_roots,
                         const std::string& destination,
                         const std::vector<std::string>& directories,
                         const std::string& name) {
  const auto received_name = ReceivedName(name);
  std::vector<std::string> folders;
  for (const auto& value : directories) folders.push_back(ReceivedName(value));
  if (sources.empty() || expected_size < 0) {
    throw StorageError("INVALID_ARGUMENT", TextId::kPartsInvalid);
  }
  struct Input {
    SafeFile file;
    int64_t size;
    dev_t device;
  };
  std::vector<Input> inputs;
  inputs.reserve(sources.size());
  int64_t total = 0;
  for (const auto& source : sources) {
    const auto path = LocalPath(source);
    const std::string* root = nullptr;
    for (const auto& allowed : allowed_roots) {
      if (ContainsPath(allowed, path) && path.size() > allowed.size()) {
        root = &allowed;
        break;
      }
    }
    if (!root) throw StorageError("INVALID_ARGUMENT", TextId::kSourceLocation);
    // Walk below the private root without following links, so a staged part
    // replaced by a link cannot export an arbitrary file.
    auto parent = PinDirectory(*root);
    const auto parts = LocalComponents(path.substr(root->size()));
    for (size_t index = 0; index + 1 < parts.size(); ++index) {
      parent = ChildDirectory(parent, parts[index], false);
    }
    auto input = SafeFile::OpenAt(parent, parts.back());
    const auto info = input.info();
    if (info.size > expected_size - total) {
      throw StorageError("FILE_CHANGED", TextId::kPartsSize);
    }
    total += info.size;
    inputs.push_back({std::move(input), info.size, info.identity.device});
  }
  if (total != expected_size) {
    throw StorageError("FILE_CHANGED", TextId::kPartsSize);
  }
  auto parent = PinDirectory(destination);
  std::string output_directory = parent.path;
  for (const auto& folder : folders) {
    output_directory = JoinPath(output_directory, folder);
  }
  // Reject the complete path before creating even an empty receive hierarchy.
  ValidateDownloadPath(output_directory, received_name);
  for (const auto& folder : folders) {
    parent = ChildDirectory(parent, folder, true);
  }
  const dev_t target_device = parent.chain.back().device;

  // Prefer an unnamed file that appears only once complete. File systems
  // without O_TMPFILE use an exclusive name that is removed on failure.
  Fd output;
  if (anonymous_saves.load()) {
    output.reset(openat(parent.fd.get(), ".", O_TMPFILE | O_WRONLY | O_CLOEXEC, 0644));
  } else {
    errno = EOPNOTSUPP;
  }
  const bool anonymous = static_cast<bool>(output);
  std::string chosen;
  if (!anonymous) {
    if (errno != EOPNOTSUPP && errno != EISDIR && errno != EINVAL &&
        errno != ENOENT) {
      ThrowSystemError(TextId::kCannotCreateFile, errno);
    }
    for (unsigned attempt = 0; attempt <= 10000 && !output; ++attempt) {
      const auto candidate = AvailableName(received_name, attempt);
      ValidateSegment(candidate);
      ValidateDownloadPath(parent.path, candidate);
      output.reset(openat(parent.fd.get(), candidate.c_str(),
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          0644));
      if (output) {
        chosen = candidate;
      } else if (errno != EEXIST) {
        ThrowSystemError(TextId::kCannotCreateFile, errno);
      }
    }
    if (!output) throw StorageError("SAVE_FAILED", TextId::kTooManySameName);
  }
  try {
    std::vector<uint8_t> buffer(256 * 1024);
    for (const auto& input : inputs) {
      CopyPart(input.file.fd(), input.size, output.get(),
               input.device == target_device, buffer);
    }
    struct stat written {};
    if (fstat(output.get(), &written) != 0 || written.st_size != expected_size) {
      throw StorageError("FILE_CHANGED", TextId::kPartsChanged);
    }
    if (fsync(output.get()) != 0) {
      ThrowSystemError(TextId::kCannotFinishSave, errno);
    }
    if (anonymous) {
      const auto descriptor = "/proc/self/fd/" + std::to_string(output.get());
      for (unsigned attempt = 0; attempt <= 10000 && chosen.empty(); ++attempt) {
        const auto candidate = AvailableName(received_name, attempt);
        ValidateSegment(candidate);
        ValidateDownloadPath(parent.path, candidate);
        if (linkat(AT_FDCWD, descriptor.c_str(), parent.fd.get(),
                   candidate.c_str(), AT_SYMLINK_FOLLOW) == 0) {
          chosen = candidate;
        } else if (errno != EEXIST) {
          ThrowSystemError(TextId::kCannotFinishSave, errno);
        }
      }
      if (chosen.empty()) {
        throw StorageError("SAVE_FAILED", TextId::kTooManySameName);
      }
    }
  } catch (...) {
    // An anonymous file disappears when closed. Otherwise remove the
    // exclusive name only while it is still the file written here.
    if (!anonymous && !chosen.empty()) {
      struct stat current {};
      struct stat created {};
      if (fstat(output.get(), &created) == 0 &&
          fstatat(parent.fd.get(), chosen.c_str(), &current,
                  AT_SYMLINK_NOFOLLOW) == 0 &&
          current.st_dev == created.st_dev && current.st_ino == created.st_ino) {
        unlinkat(parent.fd.get(), chosen.c_str(), 0);
      }
    }
    throw;
  }
  // Persist the new directory entry as well; some file systems do not
  // support directory fsync, which does not affect the saved data.
  try {
    Fd directory = ReadableDirectory(parent);
    fsync(directory.get());
  } catch (const StorageError&) {
  }
  return JoinPath(parent.path, chosen);
}

void SetAnonymousSavesForTesting(bool enabled) { anonymous_saves.store(enabled); }

void DeleteDownload(const std::string& uri) {
  const auto path = LocalPath(uri);
  if (path == "/") throw StorageError("INVALID_ARGUMENT", TextId::kEmptyPath);
  const auto name = BaseName(path);
  PinnedDirectory parent;
  try {
    parent = PinDirectory(ParentPath(path));
  } catch (const StorageError& error) {
    // An absent parent means the saved file is already gone. Links and
    // permission failures must keep the saved record.
    if (error.code == "FILE_NOT_FOUND") return;
    throw;
  }
  struct stat info {};
  if (fstatat(parent.fd.get(), name.c_str(), &info, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT) return;
    ThrowSystemError(TextId::kCannotReadDeletion, errno);
  }
  if (!S_ISREG(info.st_mode)) {
    throw StorageError("INVALID_ARGUMENT", TextId::kOnlyRegularFiles);
  }
  // Without AT_REMOVEDIR, a replacement directory can never be removed.
  if (unlinkat(parent.fd.get(), name.c_str(), 0) != 0 && errno != ENOENT) {
    ThrowSystemError(TextId::kCannotDelete, errno);
  }
}

std::string PrivateDirectoryIn(const std::string& base,
                               const std::string& name) {
  const auto requested = AbsoluteBase(base.c_str());
  try {
    if (g_mkdir_with_parents(requested.c_str(), 0700) != 0) {
      ThrowSystemError(TextId::kPrivateDirectoryUnavailable, errno);
    }
    char* resolved = realpath(requested.c_str(), nullptr);
    if (!resolved) ThrowSystemError(TextId::kPrivateDirectoryUnavailable, errno);
    const std::string canonical(resolved);
    free(resolved);
    const auto root = PinDirectory(canonical);
    const auto application = ChildDirectory(root, "tamayura", true, 0700);
    return ChildDirectory(application, name, true, 0700).path;
  } catch (const StorageError& error) {
    if (error.code == "RESOURCE_EXHAUSTED") throw;
    throw StorageError("STAGING_UNAVAILABLE",
                       TextId::kPrivateDirectoryUnavailable);
  }
}

std::string PrivateDirectory(PrivateArea area) {
  switch (area) {
    case PrivateArea::kCache:
      return PrivateDirectoryIn(AbsoluteBase(g_get_user_cache_dir()), "media");
    case PrivateArea::kThumbnails:
      return PrivateDirectoryIn(AbsoluteBase(g_get_user_cache_dir()),
                                "thumbnailer");
    case PrivateArea::kTransfers:
      return PrivateDirectoryIn(AbsoluteBase(g_get_user_data_dir()),
                                "transfers");
    case PrivateArea::kDatabases:
      return PrivateDirectoryIn(AbsoluteBase(g_get_user_data_dir()),
                                "databases");
  }
  throw StorageError("STAGING_UNAVAILABLE", TextId::kPrivateDirectoryUnavailable);
}

}  // namespace tamayura
