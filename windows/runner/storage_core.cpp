#include "storage_core.h"

#include <bcrypt.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <memory>
#include <set>
#include <sstream>
#include <utility>

namespace tamayura {
namespace {
using Microsoft::WRL::ComPtr;

[[noreturn]] void IoError(const char* message, DWORD error = GetLastError()) {
  const char* code = error == ERROR_ACCESS_DENIED || error == ERROR_SHARING_VIOLATION
                         ? "PERMISSION_LOST"
                         : error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
                               ? "FILE_NOT_FOUND"
                               : "IO_ERROR";
  throw StorageError(code, std::string(message) + " (Windows " +
                               std::to_string(error) + ")");
}

void Check(HRESULT value, const char* message) {
  if (FAILED(value)) {
    throw StorageError("PREVIEW_FAILED", std::string(message) + " (HRESULT " +
                                            std::to_string(value) + ")");
  }
}

class ComScope {
 public:
  ComScope() : result_(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {
    if (FAILED(result_) && result_ != RPC_E_CHANGED_MODE) {
      Check(result_, "Cannot initialize Windows media support");
    }
  }
  ~ComScope() { if (SUCCEEDED(result_)) CoUninitialize(); }
 private:
  HRESULT result_;
};

std::wstring NativePath(const std::wstring& path) { return L"\\\\?\\" + path; }

std::wstring CanonicalPath(HANDLE handle) {
  const DWORD size = GetFinalPathNameByHandleW(handle, nullptr, 0, FILE_NAME_NORMALIZED);
  if (!size) IoError("Cannot resolve the selected directory");
  std::wstring value(size, L'\0');
  const DWORD written = GetFinalPathNameByHandleW(handle, value.data(), size,
                                                FILE_NAME_NORMALIZED);
  if (!written || written >= size) IoError("Cannot resolve the selected directory");
  value.resize(written);
  if (value.rfind(L"\\\\?\\", 0) == 0) value.erase(0, 4);
  return LocalPath(Utf8(value));
}

void RequireOrdinary(HANDLE handle, bool directory) {
  FILE_ATTRIBUTE_TAG_INFO tag{};
  if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag, static_cast<DWORD>(sizeof(tag)))) {
    IoError("Cannot inspect file attributes");
  }
  if ((tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw StorageError("INVALID_ARGUMENT", "Symbolic links and reparse points are not supported");
  }
  if (((tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory ||
      GetFileType(handle) != FILE_TYPE_DISK) {
    throw StorageError("FILE_NOT_FOUND", directory ? "The directory is unavailable" : "The media is not a regular file");
  }
}

struct PinnedDirectory {
  std::wstring path;
  std::vector<Handle> handles;
};

Handle OpenDirectoryHandle(const std::wstring& path) {
  Handle handle(CreateFileW(NativePath(path).c_str(), FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY,
                            FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                            nullptr));
  if (handle.get() == INVALID_HANDLE_VALUE) IoError("Cannot access directory");
  RequireOrdinary(handle.get(), true);
  return handle;
}

PinnedDirectory PinDirectory(const std::wstring& path) {
  const auto normal = LocalPath(Utf8(path));
  PinnedDirectory result{normal.substr(0, 3), {}};
  result.handles.push_back(OpenDirectoryHandle(result.path));
  size_t start = 3;
  while (start < normal.size()) {
    const size_t slash = normal.find(L'\\', start);
    const auto component = normal.substr(start, slash == std::wstring::npos ? slash : slash - start);
    result.path = JoinPath(result.path, component);
    result.handles.push_back(OpenDirectoryHandle(result.path));
    if (slash == std::wstring::npos) break;
    start = slash + 1;
  }
  // Resolve DOS short names before overlap/containment checks.
  result.path = CanonicalPath(result.handles.back().get());
  return result;
}

void AddDirectory(PinnedDirectory& directory, const std::string& name) {
  ValidateSegment(name);
  const auto path = JoinPath(directory.path, Wide(name));
  if (!CreateDirectoryW(NativePath(path).c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    IoError("Cannot create the download directory");
  }
  directory.handles.push_back(OpenDirectoryHandle(path));
  directory.path = CanonicalPath(directory.handles.back().get());
}

int64_t ModifiedMs(const FILETIME& time) {
  ULARGE_INTEGER value{};
  value.LowPart = time.dwLowDateTime;
  value.HighPart = time.dwHighDateTime;
  constexpr uint64_t epoch = 116444736000000000ULL;
  return value.QuadPart >= epoch ? static_cast<int64_t>((value.QuadPart - epoch) / 10000)
                                 : -static_cast<int64_t>((epoch - value.QuadPart) / 10000);
}

struct FindHandle {
  HANDLE value;
  ~FindHandle() { if (value != INVALID_HANDLE_VALUE) FindClose(value); }
};

// A file or subfolder that is locked, vanished or cannot be named on Windows
// is skipped. Cancellation and process-level failures still end the scan.
bool SkippableScanError(const StorageError& error) {
  return error.code == "INVALID_ARGUMENT" || error.code == "FILE_NOT_FOUND" ||
         error.code == "PERMISSION_LOST" || error.code == "IO_ERROR";
}

void Enumerate(MediaCatalog& catalog, const SharedDirectory& shared,
               const std::wstring& root, const std::wstring& directory,
               const std::string& relative, uint64_t generation,
               std::vector<MediaEntry>& output) {
  catalog.AssertScan(generation);
  // Pin ancestors while FindFirstFile and child opens use absolute Win32 paths.
  // The caller decides whether this directory failing is fatal.
  auto pinned = PinDirectory(directory);
  WIN32_FIND_DATAW data{};
  const auto pattern = JoinPath(pinned.path, L"*");
  FindHandle search{FindFirstFileExW(NativePath(pattern).c_str(), FindExInfoBasic,
                                   &data, FindExSearchNameMatch, nullptr,
                                   FIND_FIRST_EX_LARGE_FETCH)};
  if (search.value == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND) return;
    IoError("Cannot enumerate shared directory");
  }
  do {
    catalog.AssertScan(generation);
    const std::wstring name(data.cFileName);
    if (name == L"." || name == L".." ||
        (data.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_HIDDEN |
                                 FILE_ATTRIBUTE_SYSTEM)) != 0) continue;
    const auto path = JoinPath(pinned.path, name);
    const bool is_directory = (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    // Only media files and folders need a valid name; ignore anything else.
    if (!is_directory && MediaMime(path).empty()) continue;
    try {
      const std::string utf8_name = Utf8(name);
      ValidateSegment(utf8_name);
      const auto child_relative = relative.empty() ? utf8_name : relative + "/" + utf8_name;
      if (is_directory) {
        Enumerate(catalog, shared, root, path, child_relative, generation, output);
        continue;
      }
      RelativeComponents(child_relative);
      auto file = SafeFile::Open(path);
      const auto info = file.info();
      output.push_back({StableMediaId(shared.id, child_relative), utf8_name, MediaMime(path),
                        info.size, info.modified_ms, shared.id, shared.name,
                        child_relative, path, root});
    } catch (const StorageError& error) {
      if (!SkippableScanError(error)) throw;
    }
  } while (FindNextFileW(search.value, &data));
  if (GetLastError() != ERROR_NO_MORE_FILES) IoError("Cannot finish directory scan");
}

Bytes EncodeJpeg(IWICImagingFactory* factory, IWICBitmapSource* source,
                 unsigned maximum) {
  UINT width = 0, height = 0;
  Check(source->GetSize(&width, &height), "Cannot read image size");
  if (!width || !height) throw StorageError("PREVIEW_FAILED", "The image dimensions are empty");
  ComPtr<IWICBitmapSource> scaled(source);
  if (std::max(width, height) > maximum) {
    const double ratio = static_cast<double>(maximum) / std::max(width, height);
    width = std::max(1u, static_cast<UINT>(width * ratio));
    height = std::max(1u, static_cast<UINT>(height * ratio));
    ComPtr<IWICBitmapScaler> scaler;
    Check(factory->CreateBitmapScaler(&scaler), "Cannot create image scaler");
    Check(scaler->Initialize(source, width, height, WICBitmapInterpolationModeFant),
          "Cannot resize image");
    Check(scaler.As(&scaled), "Cannot prepare resized image");
  }
  ComPtr<IWICFormatConverter> converter;
  Check(factory->CreateFormatConverter(&converter), "Cannot create pixel converter");
  Check(converter->Initialize(scaled.Get(), GUID_WICPixelFormat24bppBGR,
                             WICBitmapDitherTypeNone, nullptr, 0,
                             WICBitmapPaletteTypeCustom), "Cannot convert image pixels");
  ComPtr<IStream> stream;
  Check(CreateStreamOnHGlobal(nullptr, TRUE, &stream), "Cannot allocate preview stream");
  ComPtr<IWICBitmapEncoder> encoder;
  Check(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder),
        "Cannot create JPEG encoder");
  Check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache), "Cannot initialize JPEG encoder");
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> options;
  Check(encoder->CreateNewFrame(&frame, &options), "Cannot create JPEG frame");
  Check(frame->Initialize(options.Get()), "Cannot initialize JPEG frame");
  Check(frame->SetSize(width, height), "Cannot set JPEG dimensions");
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  Check(frame->SetPixelFormat(&format), "Cannot set JPEG pixel format");
  Check(frame->WriteSource(converter.Get(), nullptr), "Cannot write JPEG pixels");
  Check(frame->Commit(), "Cannot complete JPEG frame");
  Check(encoder->Commit(), "Cannot complete JPEG preview");
  STATSTG stat{};
  Check(stream->Stat(&stat, STATFLAG_NONAME), "Cannot inspect preview stream");
  if (stat.cbSize.QuadPart > 32 * 1024 * 1024) {
    throw StorageError("PREVIEW_FAILED", "The preview exceeds the size limit");
  }
  HGLOBAL memory = nullptr;
  Check(GetHGlobalFromStream(stream.Get(), &memory), "Cannot access preview bytes");
  const auto size = static_cast<size_t>(stat.cbSize.QuadPart);
  if (!size) throw StorageError("PREVIEW_FAILED", "The JPEG codec returned an empty preview");
  const auto data = static_cast<const uint8_t*>(GlobalLock(memory));
  if (!data) IoError("Cannot lock preview memory");
  Bytes bytes(data, data + size);
  GlobalUnlock(memory);
  return bytes;
}

ComPtr<IWICBitmapSource> OrientedFrame(IWICImagingFactory* factory,
                                      IWICBitmapFrameDecode* frame) {
  ComPtr<IWICBitmapSource> source(frame);
  ComPtr<IWICMetadataQueryReader> metadata;
  if (FAILED(frame->GetMetadataQueryReader(&metadata))) return source;
  unsigned orientation = 1;
  for (const auto query : {L"/app1/ifd/{ushort=274}", L"/ifd/{ushort=274}"}) {
    PROPVARIANT value{};
    const auto status = metadata->GetMetadataByName(query, &value);
    if (SUCCEEDED(status)) {
      if (value.vt == VT_UI2) orientation = value.uiVal;
      else if (value.vt == VT_UI4) orientation = value.ulVal;
    }
    PropVariantClear(&value);
    if (SUCCEEDED(status)) break;
  }
  // Apply rotation and reflection separately so EXIF transpose/transverse do
  // not depend on an individual codec's ordering of combined transforms.
  WICBitmapTransformOptions rotation = WICBitmapTransformRotate0;
  WICBitmapTransformOptions reflection = WICBitmapTransformRotate0;
  switch (orientation) {
    case 2: reflection = WICBitmapTransformFlipHorizontal; break;
    case 3: rotation = WICBitmapTransformRotate180; break;
    case 4: reflection = WICBitmapTransformFlipVertical; break;
    case 5: rotation = WICBitmapTransformRotate90; reflection = WICBitmapTransformFlipHorizontal; break;
    case 6: rotation = WICBitmapTransformRotate90; break;
    case 7: rotation = WICBitmapTransformRotate270; reflection = WICBitmapTransformFlipHorizontal; break;
    case 8: rotation = WICBitmapTransformRotate270; break;
    default: break;
  }
  for (const auto transform : {rotation, reflection}) {
    if (transform == WICBitmapTransformRotate0) continue;
    ComPtr<IWICBitmapFlipRotator> rotator;
    Check(factory->CreateBitmapFlipRotator(&rotator), "Cannot create image orientation transform");
    Check(rotator->Initialize(source.Get(), transform), "Cannot apply photo orientation");
    Check(rotator.As(&source), "Cannot prepare oriented photo");
  }
  return source;
}

}  // namespace

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  if (value.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    throw StorageError("INVALID_ARGUMENT", "String is too long");
  }
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                      static_cast<int>(value.size()), nullptr, 0);
  if (!size) throw StorageError("INVALID_ARGUMENT", "Invalid UTF-8 string");
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  if (value.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    throw StorageError("INVALID_ARGUMENT", "String is too long");
  }
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (!size) throw StorageError("INVALID_ARGUMENT", "Invalid UTF-16 string");
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
  return result;
}

void ValidateSegment(const std::string& value) {
  const auto wide = Wide(value);
  if (wide.empty() || wide.size() > 255 || wide == L"." || wide == L".." ||
      wide.back() == L'.' || wide.back() == L' ' ||
      wide.find_first_of(L"<>:\"/\\|?*") != std::wstring::npos ||
      std::any_of(wide.begin(), wide.end(), [](wchar_t ch) {
        return ch < 32 || (ch >= 127 && ch <= 159);
      })) {
    throw StorageError("INVALID_ARGUMENT", "File or directory name is invalid on Windows");
  }
  auto stem = wide.substr(0, wide.find(L'.'));
  while (!stem.empty() && stem.back() == L' ') stem.pop_back();
  for (auto& ch : stem) if (ch >= L'a' && ch <= L'z') ch -= L'a' - L'A';
  const bool numbered = stem.size() == 4 &&
      (stem.rfind(L"COM", 0) == 0 || stem.rfind(L"LPT", 0) == 0) &&
      ((stem[3] >= L'1' && stem[3] <= L'9') || stem[3] == L'\u00b9' ||
       stem[3] == L'\u00b2' || stem[3] == L'\u00b3');
  if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" || stem == L"NUL" ||
      stem == L"CONIN$" || stem == L"CONOUT$" || numbered) {
    throw StorageError("INVALID_ARGUMENT", "Reserved Windows device names are not allowed");
  }
}

std::vector<std::string> RelativeComponents(const std::string& value) {
  if (value.empty() || value.size() > 32760) {
    throw StorageError("INVALID_ARGUMENT", "Invalid relative media path");
  }
  std::vector<std::string> result;
  size_t start = 0;
  for (;;) {
    const auto slash = value.find('/', start);
    const auto part = value.substr(start, slash == std::string::npos ? slash : slash - start);
    ValidateSegment(part);
    result.push_back(part);
    if (slash == std::string::npos) return result;
    start = slash + 1;
  }
}

std::wstring LocalPath(const std::string& value) {
  auto path = Wide(value);
  // Deliberately exclude UNC, device namespaces, drive-relative paths and URIs.
  if (path.size() < 3 || path.size() > 32760 ||
      !((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) ||
      path[1] != L':' || (path[2] != L'\\' && path[2] != L'/')) {
    throw StorageError("INVALID_ARGUMENT", "A local absolute Windows path is required");
  }
  std::replace(path.begin(), path.end(), L'/', L'\\');
  if (path[0] >= L'a' && path[0] <= L'z') path[0] -= L'a' - L'A';
  if (path.size() > 3 && path.back() == L'\\') path.pop_back();
  size_t start = 3;
  while (start < path.size()) {
    const auto slash = path.find(L'\\', start);
    ValidateSegment(Utf8(path.substr(start, slash == std::wstring::npos ? slash : slash - start)));
    if (slash == std::wstring::npos) break;
    start = slash + 1;
  }
  return path;
}

bool ContainsPath(const std::wstring& root, const std::wstring& child) {
  if (root.empty() || child.size() < root.size()) return false;
  if (CompareStringOrdinal(root.data(), static_cast<int>(root.size()), child.data(),
                           static_cast<int>(root.size()), TRUE) != CSTR_EQUAL) return false;
  return child.size() == root.size() || root.back() == L'\\' || child[root.size()] == L'\\';
}

std::wstring JoinPath(const std::wstring& parent, const std::wstring& name) {
  return parent + (parent.back() == L'\\' ? L"" : L"\\") + name;
}

std::string AvailableName(const std::string& name, unsigned attempt) {
  if (!attempt) return name;
  const auto found = name.find_last_of('.');
  const auto dot = found == 0 || found == std::string::npos ? name.size() : found;
  return name.substr(0, dot) + " (" + std::to_string(attempt) + ")" + name.substr(dot);
}

std::string ReceivedName(const std::string& name) {
  auto value = Wide(name);
  // Components from peers are names, never paths. Preserve this boundary even
  // while adapting otherwise legitimate macOS names to Windows restrictions.
  if (value.empty() || value == L"." || value == L".." ||
      value.find_first_of(L"/\\") != std::wstring::npos ||
      std::any_of(value.begin(), value.end(), [](wchar_t ch) {
        return ch < 32 || (ch >= 127 && ch <= 159);
      })) throw StorageError("INVALID_ARGUMENT", "Invalid received media name");
  for (auto& ch : value) if (std::wstring(L"<>:\"|?*").find(ch) != std::wstring::npos) ch = L'_';
  while (!value.empty() && (value.back() == L'.' || value.back() == L' ')) value.pop_back();
  if (value.empty()) value = L"media";
  auto candidate = Utf8(value);
  try { ValidateSegment(candidate); }
  catch (const StorageError&) {
    // Prefix reserved DOS device names. Length failures remain errors below.
    candidate = "_" + candidate;
    ValidateSegment(candidate);
  }
  return candidate;
}

std::string MediaMime(const std::wstring& path) {
  const auto dot = path.find_last_of(L'.');
  if (dot == std::wstring::npos) return {};
  auto ext = path.substr(dot);
  for (auto& ch : ext) if (ch >= L'A' && ch <= L'Z') ch += L'a' - L'A';
  static const std::map<std::wstring, std::string> types = {
      {L".jpg", "image/jpeg"}, {L".jpeg", "image/jpeg"}, {L".jpe", "image/jpeg"},
      {L".png", "image/png"}, {L".gif", "image/gif"}, {L".bmp", "image/bmp"},
      {L".webp", "image/webp"}, {L".tif", "image/tiff"}, {L".tiff", "image/tiff"},
      {L".heic", "image/heic"}, {L".heif", "image/heif"}, {L".avif", "image/avif"},
      {L".dng", "image/x-adobe-dng"}, {L".cr2", "image/x-canon-cr2"},
      {L".nef", "image/x-nikon-nef"}, {L".arw", "image/x-sony-arw"},
      {L".mp4", "video/mp4"}, {L".m4v", "video/x-m4v"}, {L".mov", "video/quicktime"},
      {L".avi", "video/x-msvideo"}, {L".mkv", "video/x-matroska"},
      {L".webm", "video/webm"}, {L".wmv", "video/x-ms-wmv"},
      {L".mpeg", "video/mpeg"}, {L".mpg", "video/mpeg"}, {L".3gp", "video/3gpp"},
      {L".3g2", "video/3gpp2"}, {L".mts", "video/mp2t"}, {L".m2ts", "video/mp2t"}};
  const auto it = types.find(ext);
  return it == types.end() ? std::string() : it->second;
}

std::string StableMediaId(const std::string& folder_id, const std::string& relative_path) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) {
    throw StorageError("PLATFORM_ERROR", "Cannot initialize media identifier hashing");
  }
  struct AlgorithmGuard { BCRYPT_ALG_HANDLE value; ~AlgorithmGuard() { BCryptCloseAlgorithmProvider(value, 0); } } guard{algorithm};
  std::string input = folder_id;
  input.push_back('\0');
  input += relative_path;
  std::array<unsigned char, 32> digest{};
  if (BCryptHash(algorithm, nullptr, 0, reinterpret_cast<PUCHAR>(input.data()),
                 static_cast<ULONG>(input.size()), digest.data(),
                 static_cast<ULONG>(digest.size())) < 0) {
    throw StorageError("PLATFORM_ERROR", "Cannot hash media identifier");
  }
  constexpr char hex[] = "0123456789abcdef";
  std::string result;
  for (const auto byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  return result;
}

std::wstring PrivateDirectory(const std::wstring& name) {
  ValidateSegment(Utf8(name));
  PWSTR raw = nullptr;
  const auto status = SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &raw);
  if (FAILED(status)) throw StorageError("STAGING_UNAVAILABLE", "Windows LocalAppData is unavailable");
  std::wstring root(raw);
  CoTaskMemFree(raw);
  auto pinned = PinDirectory(root);
  AddDirectory(pinned, "Tamayura");
  AddDirectory(pinned, Utf8(name));
  return pinned.path;
}

Handle::~Handle() { reset(); }
Handle::Handle(Handle&& other) noexcept : value_(other.value_) { other.value_ = INVALID_HANDLE_VALUE; }
Handle& Handle::operator=(Handle&& other) noexcept {
  if (this != &other) { reset(); value_ = other.value_; other.value_ = INVALID_HANDLE_VALUE; }
  return *this;
}
void Handle::reset() {
  if (value_ != INVALID_HANDLE_VALUE && value_ != nullptr) CloseHandle(value_);
  value_ = INVALID_HANDLE_VALUE;
}

SafeFile SafeFile::Open(const std::wstring& path) {
  const auto normal = LocalPath(Utf8(path));
  if (normal.size() == 3) throw StorageError("INVALID_ARGUMENT", "A media file is required");
  const auto slash = normal.find_last_of(L'\\');
  auto parent = PinDirectory(normal.substr(0, slash == 2 ? 3 : slash));
  const auto canonical = JoinPath(parent.path, normal.substr(slash + 1));
  Handle handle(CreateFileW(NativePath(canonical).c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING,
                            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
  if (handle.get() == INVALID_HANDLE_VALUE) IoError("Cannot access media file");
  RequireOrdinary(handle.get(), false);
  return SafeFile(canonical, std::move(parent.handles), std::move(handle));
}

FileInfo SafeFile::info() const {
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(file_.get(), &info)) IoError("Cannot read media metadata");
  const uint64_t size = (static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
  if (size > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
    throw StorageError("INVALID_ARGUMENT", "The media file is too large");
  }
  return {static_cast<int64_t>(size), ModifiedMs(info.ftLastWriteTime)};
}

Bytes SafeFile::Read(int64_t offset, int64_t length, int64_t expected_size) const {
  if (offset < 0 || offset > expected_size || length < 0 || length > 256 * 1024) {
    throw StorageError("INVALID_ARGUMENT", "Invalid media range; maximum chunk is 256 KiB");
  }
  if (info().size != expected_size) throw StorageError("FILE_CHANGED", "Media size changed; refresh the album");
  const DWORD count = static_cast<DWORD>(std::min(length, expected_size - offset));
  Bytes bytes(count);
  LARGE_INTEGER position{};
  position.QuadPart = offset;
  if (!SetFilePointerEx(file_.get(), position, nullptr, FILE_BEGIN)) IoError("Cannot seek media file");
  DWORD read = 0;
  while (read < count) {
    DWORD amount = 0;
    if (!ReadFile(file_.get(), bytes.data() + read, count - read, &amount, nullptr)) {
      IoError("Cannot read media range");
    }
    if (!amount) throw StorageError("FILE_CHANGED", "Media ended before the expected range");
    read += amount;
  }
  return bytes;
}

uint64_t MediaCatalog::Clear() {
  std::lock_guard<std::mutex> lock(mutex_);
  RevokeLocked();
  return ticket_;
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
  return ++ticket_;
}

void MediaCatalog::RevokeLocked() {
  files_.clear();
  ++generation_;
  ++ticket_;
}

void MediaCatalog::AssertScan(uint64_t ticket) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (ticket != ticket_) throw StorageError("SCAN_CANCELLED", "Shared directories changed; scan again");
}

void MediaCatalog::AssertCurrent(const std::string& id, const MediaEntry& entry,
                                 uint64_t generation) const {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = files_.find(id);
  if (generation != generation_ || found == files_.end() || found->second.path != entry.path ||
      found->second.size != entry.size || found->second.modified_ms != entry.modified_ms) {
    throw StorageError("SCAN_CANCELLED", "Shared directories changed; scan again");
  }
}

void MediaCatalog::Validate(const std::string& uri,
                             const std::vector<std::string>& existing) const {
  auto candidate = PinDirectory(LocalPath(uri));
  for (const auto& value : existing) {
    auto previous = PinDirectory(LocalPath(value));
    if (ContainsPath(candidate.path, previous.path) || ContainsPath(previous.path, candidate.path)) {
      throw StorageError("DIR_OVERLAP", "Shared directories cannot repeat or contain each other");
    }
  }
}

std::vector<MediaEntry> MediaCatalog::Scan(const std::vector<SharedDirectory>& directories,
                                          uint64_t expected) try {
  AssertScan(expected);
  std::set<std::string> ids;
  std::vector<std::string> previous;
  for (const auto& directory : directories) {
    ValidateSegment(directory.id);
    ValidateSegment(directory.name);
    if (!ids.insert(directory.id).second) throw StorageError("INVALID_ARGUMENT", "Shared directory identifiers repeat");
    Validate(directory.uri, previous);
    previous.push_back(directory.uri);
  }
  std::vector<MediaEntry> metadata;
  for (const auto& directory : directories) {
    // The shared folder itself must be readable. Its pinned handles also keep
    // it from being renamed or removed while the scan skips unreadable children.
    auto root = PinDirectory(LocalPath(directory.uri));
    Enumerate(*this, directory, root.path, root.path, "", expected, metadata);
  }
  std::map<std::string, MediaEntry> next;
  for (const auto& entry : metadata) next.emplace(entry.id, entry);
  std::lock_guard<std::mutex> lock(mutex_);
  if (expected != ticket_) throw StorageError("SCAN_CANCELLED", "Shared directories changed; scan again");
  files_ = std::move(next);
  return metadata;
} catch (...) {
  // The publishing lock is released during unwinding, before this handler.
  std::lock_guard<std::mutex> lock(mutex_);
  if (expected == ticket_) RevokeLocked();
  throw;
}

Bytes MediaCatalog::WithMedia(const std::string& id,
    const std::function<Bytes(const MediaEntry&, const SafeFile&)>& operation) {
  MediaEntry entry;
  uint64_t expected = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = files_.find(id);
    if (found == files_.end()) throw StorageError("FILE_NOT_FOUND", "This file is no longer shared; refresh the album");
    entry = found->second;
    expected = generation_;
  }
  auto file = SafeFile::Open(entry.path);
  AssertCurrent(id, entry, expected);
  const auto info = file.info();
  if (info.size != entry.size || info.modified_ms != entry.modified_ms) {
    throw StorageError("FILE_CHANGED", "Media changed; refresh the album");
  }
  auto result = operation(entry, file);
  AssertCurrent(id, entry, expected);
  return result;
}

Bytes MediaCatalog::Thumbnail(const std::string& id,
    const std::function<Bytes(const MediaEntry&, const SafeFile&)>& generate) {
  MediaEntry entry;
  uint64_t expected = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = files_.find(id);
    if (found == files_.end()) throw StorageError("FILE_NOT_FOUND", "This file is no longer shared; refresh the album");
    entry = found->second;
    expected = generation_;
  }
  // Shared-folder access errors affect every file, not one preview.
  [[maybe_unused]] const auto root = PinDirectory(entry.root);
  AssertCurrent(id, entry, expected);
  Bytes result;
  try {
    auto file = SafeFile::Open(entry.path);
    const auto info = file.info();
    if (info.size == entry.size && info.modified_ms == entry.modified_ms) {
      result = generate(entry, file);
    }
  } catch (const StorageError& error) {
    // Permission, sharing and other I/O failures may recover; they must not be
    // cached by peers as an empty preview.
    if (error.code != "FILE_NOT_FOUND" && error.code != "FILE_CHANGED" &&
        error.code != "PREVIEW_FAILED") throw;
    result.clear();
  }
  AssertCurrent(id, entry, expected);
  return result;
}

Bytes MediaCatalog::Read(const std::string& id, int64_t offset, int64_t length) {
  return WithMedia(id, [=](const MediaEntry& entry, const SafeFile& file) {
    return file.Read(offset, length, entry.size);
  });
}

std::wstring ValidateDirectory(const std::string& path) {
  return PinDirectory(LocalPath(path)).path;
}

TransferSpaceInfo TransferSpace(const std::wstring& staging,
                                const std::string& destination) {
  const auto source = PinDirectory(staging);
  const auto target = PinDirectory(LocalPath(destination));
  auto available = [](const PinnedDirectory& directory) -> std::optional<int64_t> {
    ULARGE_INTEGER bytes{};
    if (!GetDiskFreeSpaceExW(NativePath(directory.path).c_str(), &bytes, nullptr, nullptr)) {
      return std::nullopt;
    }
    const auto maximum = static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
    return static_cast<int64_t>(std::min<uint64_t>(bytes.QuadPart, maximum));
  };
  TransferSpaceInfo result{available(source), available(target), std::nullopt};
  FILE_ID_INFO source_id{}, target_id{};
  if (GetFileInformationByHandleEx(source.handles.back().get(), FileIdInfo, &source_id,
                                   static_cast<DWORD>(sizeof(source_id))) &&
      GetFileInformationByHandleEx(target.handles.back().get(), FileIdInfo, &target_id,
                                   static_cast<DWORD>(sizeof(target_id)))) {
    result.same_volume = source_id.VolumeSerialNumber == target_id.VolumeSerialNumber;
  }
  return result;
}

std::wstring SaveDownload(const std::vector<std::string>& sources,
                           int64_t expected_size,
                           const std::vector<std::wstring>& allowed_roots,
                           const std::string& destination,
                           const std::vector<std::string>& directories,
                           const std::string& name) {
  const auto received_name = ReceivedName(name);
  for (const auto& value : directories) ValidateSegment(value);
  if (sources.empty() || expected_size < 0) {
    throw StorageError("INVALID_ARGUMENT", "Download requires parts and a non-negative expected size");
  }
  std::vector<SafeFile> inputs;
  inputs.reserve(sources.size());
  int64_t total = 0;
  for (const auto& source : sources) {
    // Keep every source and its parent chain pinned until export finishes.
    auto input = SafeFile::Open(LocalPath(source));
    bool allowed = false;
    for (const auto& root : allowed_roots) {
      auto pinned = PinDirectory(root);
      if (ContainsPath(pinned.path, input.path()) && input.path().size() > pinned.path.size()) {
        allowed = true;
        break;
      }
    }
    if (!allowed) {
      throw StorageError("INVALID_ARGUMENT", "Download source must be in the application's private storage");
    }
    const auto size = input.info().size;
    if (size > expected_size - total) {
      throw StorageError("FILE_CHANGED", "Download parts exceed the expected file size");
    }
    total += size;
    inputs.push_back(std::move(input));
  }
  if (total != expected_size) {
    throw StorageError("FILE_CHANGED", "Download parts do not match the expected file size");
  }
  auto parent = PinDirectory(LocalPath(destination));
  for (const auto& value : directories) AddDirectory(parent, value);
  Handle output;
  std::wstring path;
  for (unsigned attempt = 0; attempt <= 10000; ++attempt) {
    const auto available = AvailableName(received_name, attempt);
    ValidateSegment(available);
    path = JoinPath(parent.path, Wide(available));
    output = Handle(CreateFileW(NativePath(path).c_str(), GENERIC_WRITE | DELETE, 0,
                                nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL |
                                FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (output.get() != INVALID_HANDLE_VALUE) break;
    const auto error = GetLastError();
    if (error != ERROR_FILE_EXISTS && error != ERROR_ALREADY_EXISTS) IoError("Cannot create received media", error);
  }
  if (output.get() == INVALID_HANDLE_VALUE) throw StorageError("SAVE_FAILED", "Too many files have the same name");
  try {
    std::array<uint8_t, 256 * 1024> buffer{};
    int64_t copied = 0;
    for (const auto& input : inputs) {
      for (;;) {
        DWORD count = 0;
        if (!ReadFile(input.handle(), buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr)) {
          IoError("Cannot read download staging file");
        }
        if (!count) break;
        if (static_cast<int64_t>(count) > expected_size - copied) {
          throw StorageError("FILE_CHANGED", "Download parts grew during export");
        }
        DWORD written = 0;
        while (written < count) {
          DWORD amount = 0;
          if (!WriteFile(output.get(), buffer.data() + written, count - written, &amount, nullptr) || !amount) {
            IoError("Cannot save received media; check free disk space");
          }
          written += amount;
        }
        copied += count;
      }
    }
    if (copied != expected_size) {
      throw StorageError("FILE_CHANGED", "Download parts ended before the expected file size");
    }
    if (!FlushFileBuffers(output.get())) IoError("Cannot finish saving received media");
  } catch (...) {
    // Mark the exact open handle for deletion; never delete a replacement by path.
    FILE_DISPOSITION_INFO disposition{TRUE};
    SetFileInformationByHandle(output.get(), FileDispositionInfo, &disposition,
                               static_cast<DWORD>(sizeof(disposition)));
    throw;
  }
  return path;
}

void DeleteDownload(const std::string& uri) {
  const auto path = LocalPath(uri);
  if (path.size() == 3) throw StorageError("INVALID_ARGUMENT", "A media file is required");
  const auto slash = path.find_last_of(L'\\');
  PinnedDirectory parent;
  try {
    parent = PinDirectory(path.substr(0, slash == 2 ? 3 : slash));
  } catch (const StorageError& error) {
    // An absent parent means the saved file is already gone. Reparse points,
    // permission failures and sharing violations must keep the saved record.
    if (error.code == "FILE_NOT_FOUND") return;
    throw;
  }
  const auto canonical = JoinPath(parent.path, path.substr(slash + 1));
  Handle file(CreateFileW(NativePath(canonical).c_str(), DELETE | FILE_READ_ATTRIBUTES,
                          FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                          FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) {
    const auto error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return;
    IoError("Cannot access downloaded media for deletion", error);
  }
  RequireOrdinary(file.get(), false);
  // Delete the exact opened file while its parent handles remain pinned.
  FILE_DISPOSITION_INFO disposition{TRUE};
  if (!SetFileInformationByHandle(file.get(), FileDispositionInfo, &disposition,
                                  static_cast<DWORD>(sizeof(disposition)))) {
    IoError("Cannot delete downloaded media");
  }
}

Bytes JpegPreview(const SafeFile& file, unsigned maximum, bool video) {
  if (maximum < 1 || maximum > 2560) throw StorageError("INVALID_ARGUMENT", "Preview size must be 1..2560");
  ComScope com;
  ComPtr<IWICImagingFactory> factory;
  Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&factory)), "Cannot initialize image codecs");
  if (!video) {
    ComPtr<IWICBitmapDecoder> decoder;
    const auto decoded = factory->CreateDecoderFromFileHandle(
        reinterpret_cast<ULONG_PTR>(file.handle()), nullptr,
        WICDecodeMetadataCacheOnDemand, &decoder);
    if (SUCCEEDED(decoded)) {
      ComPtr<IWICBitmapFrameDecode> frame;
      Check(decoder->GetFrame(0, &frame), "Cannot decode image frame");
      auto oriented = OrientedFrame(factory.Get(), frame.Get());
      return EncodeJpeg(factory.Get(), oriented.Get(), maximum);
    }
    // Installed Shell providers can support extra image/RAW formats.
  }
  ComPtr<IShellItemImageFactory> shell;
  Check(SHCreateItemFromParsingName(file.path().c_str(), nullptr,
                                   IID_PPV_ARGS(&shell)), "Cannot load media thumbnail provider");
  HBITMAP bitmap = nullptr;
  const SIZE requested{static_cast<LONG>(maximum), static_cast<LONG>(maximum)};
  Check(shell->GetImage(requested,
                        static_cast<SIIGBF>(SIIGBF_THUMBNAILONLY | SIIGBF_RESIZETOFIT),
                        &bitmap), "No thumbnail codec is installed for this media");
  struct BitmapGuard { HBITMAP value; ~BitmapGuard() { if (value) DeleteObject(value); } } guard{bitmap};
  ComPtr<IWICBitmap> source;
  Check(factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha, &source),
        "Cannot convert media thumbnail");
  return EncodeJpeg(factory.Get(), source.Get(), maximum);
}

}  // namespace tamayura
