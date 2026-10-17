#include "storage_core.h"

#include <wincodec.h>
#include <winioctl.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <filesystem>
#include <functional>
#include <iostream>
#include <thread>

namespace {
using namespace tamayura;
using Microsoft::WRL::ComPtr;

void Expect(bool result, const char* message) {
  if (!result) throw std::runtime_error(message);
}

void Reject(const std::string& code, const std::function<void()>& body) {
  try { body(); }
  catch (const StorageError& error) {
    if (!code.empty()) Expect(error.code == code, ("Unexpected error: " + error.code + ": " + error.what()).c_str());
    return;
  }
  throw std::runtime_error("Expected the operation to fail");
}

void Write(const std::wstring& path, const Bytes& bytes) {
  Handle output(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr));
  Expect(output.get() != INVALID_HANDLE_VALUE, "Cannot write fixture");
  DWORD written = 0;
  Expect(WriteFile(output.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) &&
             written == bytes.size(), "Cannot write fixture bytes");
}

Bytes Read(const std::wstring& path) {
  auto file = SafeFile::Open(path);
  return file.Read(0, 256 * 1024, file.info().size);
}

// An in-memory BMP provides a deterministic real codec fixture without any
// external assets, encoder utilities or installed optional codecs.
Bytes Bitmap() {
  constexpr uint32_t width = 800, height = 400;
  constexpr uint32_t pixels = width * height * 3;
  BITMAPFILEHEADER header{};
  header.bfType = 0x4d42;
  header.bfSize = static_cast<DWORD>(sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER) + pixels);
  header.bfOffBits = static_cast<DWORD>(sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER));
  BITMAPINFOHEADER info{};
  info.biSize = static_cast<DWORD>(sizeof(info));
  info.biWidth = width;
  info.biHeight = height;
  info.biPlanes = 1;
  info.biBitCount = 24;
  info.biCompression = BI_RGB;
  info.biSizeImage = pixels;
  Bytes bytes(header.bfSize, 96);
  memcpy(bytes.data(), &header, sizeof(header));
  memcpy(bytes.data() + sizeof(header), &info, sizeof(info));
  return bytes;
}

void CheckJpeg(const Bytes& bytes, UINT width, UINT height) {
  Expect(bytes.size() > 2 && bytes[0] == 0xff && bytes[1] == 0xd8, "Expected JPEG data");
  ComPtr<IWICImagingFactory> factory;
  Expect(SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&factory))), "Cannot create test codec");
  ComPtr<IWICStream> stream;
  Expect(SUCCEEDED(factory->CreateStream(&stream)), "Cannot create test stream");
  Expect(SUCCEEDED(stream->InitializeFromMemory(const_cast<BYTE*>(bytes.data()),
                                               static_cast<DWORD>(bytes.size()))), "Cannot load JPEG bytes");
  ComPtr<IWICBitmapDecoder> decoder;
  Expect(SUCCEEDED(factory->CreateDecoderFromStream(stream.Get(), nullptr,
                                                   WICDecodeMetadataCacheOnLoad, &decoder)), "Cannot decode JPEG");
  ComPtr<IWICBitmapFrameDecode> frame;
  Expect(SUCCEEDED(decoder->GetFrame(0, &frame)), "Cannot read JPEG frame");
  UINT actual_width = 0, actual_height = 0;
  Expect(SUCCEEDED(frame->GetSize(&actual_width, &actual_height)), "Cannot read JPEG size");
  Expect(actual_width == width && actual_height == height, "Preview must preserve bounded aspect ratio");
}

// Junctions require no symbolic-link privilege, so the escape test runs on
// ordinary Windows accounts even when Developer Mode is disabled.
bool Junction(const std::wstring& link, const std::wstring& target) {
  if (!CreateDirectoryW(link.c_str(), nullptr)) return false;
  Handle directory(CreateFileW(link.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                               FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr));
  if (directory.get() == INVALID_HANDLE_VALUE) return false;
  const std::wstring substitute = L"\\??\\" + target;
  const size_t path_size = (substitute.size() + 1 + target.size() + 1) * sizeof(wchar_t);
  // Mount point header: tag, data length, reserved, four string offsets/lengths.
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
  return DeviceIoControl(directory.get(), FSCTL_SET_REPARSE_POINT, buffer.data(),
                         static_cast<DWORD>(buffer.size()), nullptr, 0, &returned, nullptr) != FALSE;
}

}  // namespace

int main() {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com)) { std::cerr << "COM initialization failed\n"; return 1; }
  struct ComGuard { ~ComGuard() { CoUninitialize(); } } com_guard;
  wchar_t temp[MAX_PATH + 1]{};
  if (!GetTempPathW(MAX_PATH, temp)) { std::cerr << "Temporary directory unavailable\n"; return 1; }
  const auto base = JoinPath(temp, L"tamayura-storage-test-" + std::to_wstring(GetCurrentProcessId()) +
                                    L"-" + std::to_wstring(GetTickCount64()));
  std::filesystem::create_directories(base);
  struct Cleanup { std::wstring path; ~Cleanup() { std::error_code ignored; std::filesystem::remove_all(path, ignored); } } cleanup{base};
  unsigned passed = 0;
  auto test = [&](const char* name, const std::function<void()>& body) {
    body(); ++passed; std::cout << "PASS " << name << '\n';
  };
  try {
    const auto root = JoinPath(base, L"photos");
    const auto nested = JoinPath(root, L"旅行");
    const auto destination = JoinPath(base, L"received");
    const auto staging = JoinPath(base, L"staging");
    for (const auto& directory : {nested, destination, staging}) std::filesystem::create_directories(directory);
    const auto photo = JoinPath(nested, L"a.jpg");
    Bytes bytes(1000);
    for (size_t index = 0; index < bytes.size(); ++index) bytes[index] = static_cast<uint8_t>(index % 251);
    Write(photo, bytes);
    Write(JoinPath(root, L"ignore.txt"), Bytes{1, 2});
    MediaCatalog catalog;
    const SharedDirectory shared{"folder-one", Utf8(root), "照片"};
    std::string id;

    test("reject traversal, ADS, DOS devices and nonlocal paths", [&] {
      for (const auto& name : {"", ".", "..", "a/b", "a\\b", "a:b", "x\n", "NUL", "Con.jpg", "LPT1", "COM9.png", "a.", "a "}) {
        Reject("INVALID_ARGUMENT", [&] { ValidateSegment(name); });
      }
      for (const auto& path : {"../a", "/a", "a//b", "a/../b", "C:a", "a/"}) {
        Reject("INVALID_ARGUMENT", [&] { RelativeComponents(path); });
      }
      for (const auto& path : {"C:a", "\\\\server\\share", "\\\\?\\C:\\a", "file:///C:/a", "C:\\..\\a", "C:\\a::$DATA"}) {
        Reject("INVALID_ARGUMENT", [&] { LocalPath(path); });
      }
      ValidateSegment("旅行 图片.jpg");
      Expect(LocalPath("c:/photos/") == L"C:\\photos", "Normalize drive, slashes and trailing separator");
    });
    test("compare root components with Windows case rules", [&] {
      Expect(ContainsPath(L"C:\\Photos", L"c:\\photos\\2026"), "Case-insensitive descendant");
      Expect(!ContainsPath(L"C:\\photos", L"C:\\photos-old"), "Sibling must not overlap");
      Reject("DIR_OVERLAP", [&] { catalog.Validate(Utf8(nested), {Utf8(root)}); });
      Reject("DIR_OVERLAP", [&] { catalog.Validate(Utf8(root), {Utf8(nested)}); });
      Reject("DIR_OVERLAP", [&] { catalog.Validate(Utf8(root), {Utf8(root)}); });
    });
    test("recursive metadata has stable SHA256 IDs and millisecond mtime", [&] {
      const auto entries = catalog.Scan({shared}, catalog.Clear());
      Expect(entries.size() == 1, "Only image and video files are catalogued");
      const auto& entry = entries[0];
      id = entry.id;
      Expect(id.size() == 64 && entry.relative_path == "旅行/a.jpg", "Stable opaque ID and relative hierarchy");
      Expect(entry.size == 1000 && entry.mime_type == "image/jpeg", "Size and MIME type");
      Expect(entry.shared_folder_name == "照片" && entry.modified_ms > 1600000000000LL,
             "Folder label and millisecond timestamp");
      Expect(catalog.Scan({shared}, catalog.Clear())[0].id == id, "Unchanged scan retains ID");
      Expect(StableMediaId("a", "bc") != StableMediaId("ab", "c"), "ID input is delimited");
      Reject("INVALID_ARGUMENT", [&] { catalog.Scan({shared, shared}, catalog.Clear()); });
      catalog.Scan({shared}, catalog.Clear());
    });
    test("range bytes, tails, EOF, invalid bounds and changed files", [&] {
      Expect(catalog.Read(id, 10, 20) == Bytes(bytes.begin() + 10, bytes.begin() + 30), "Range bytes");
      Expect(catalog.Read(id, 990, 20) == Bytes(bytes.begin() + 990, bytes.end()), "Partial tail");
      Expect(catalog.Read(id, 1000, 1).empty(), "EOF is empty");
      Reject("INVALID_ARGUMENT", [&] { catalog.Read(id, -1, 1); });
      Reject("INVALID_ARGUMENT", [&] { catalog.Read(id, 1001, 0); });
      Reject("INVALID_ARGUMENT", [&] { catalog.Read(id, 0, 262145); });
      Reject("FILE_NOT_FOUND", [&] { catalog.Read("unknown", 0, 1); });
      Write(photo, Bytes{0});
      Reject("FILE_CHANGED", [&] { catalog.Read(id, 0, 1); });
      Write(photo, bytes);
      catalog.Scan({shared}, catalog.Clear());
    });
    test("clear cancels queued/running scans and in-flight reads", [&] {
      const auto ticket = catalog.Clear();
      catalog.Clear();
      Reject("SCAN_CANCELLED", [&] { catalog.Scan({shared}, ticket); });
      catalog.Scan({shared}, catalog.Clear());
      Reject("SCAN_CANCELLED", [&] {
        catalog.WithMedia(id, [&](const MediaEntry&, const SafeFile&) { catalog.Clear(); return Bytes{}; });
      });
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(id, 0, 1); });
      const auto invalid = SharedDirectory{"bad", Utf8(JoinPath(base, L"missing")), "missing"};
      Reject("FILE_NOT_FOUND", [&] { catalog.Scan({invalid}, catalog.Clear()); });
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(id, 0, 1); });
    });
    test("rescan keeps serving retained folders and a failed rescan revokes them", [&] {
      catalog.Scan({shared}, catalog.Clear());
      const auto ticket = catalog.BeginScan({shared.id});
      Expect(catalog.Read(id, 0, 10) == Bytes(bytes.begin(), bytes.begin() + 10), "Read during rescan");
      const auto spanning = catalog.WithMedia(id, [&](const MediaEntry&, const SafeFile&) {
        catalog.Scan({shared}, ticket);
        return Bytes{1};
      });
      Expect(spanning == Bytes{1}, "Read across an unchanged republication");
      const auto stale = catalog.BeginScan({shared.id});
      catalog.BeginScan({shared.id});
      Reject("SCAN_CANCELLED", [&] { catalog.Scan({shared}, stale); });
      Expect(catalog.Read(id, 0, 1) == Bytes{bytes[0]}, "Superseded scan keeps serving");
      const auto invalid = SharedDirectory{"bad", Utf8(JoinPath(base, L"missing")), "missing"};
      Reject("FILE_NOT_FOUND", [&] { catalog.Scan({invalid}, catalog.BeginScan({shared.id, invalid.id})); });
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(id, 0, 1); });
      catalog.Scan({shared}, catalog.Clear());
      catalog.BeginScan({});
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(id, 0, 1); });
      catalog.Scan({shared}, catalog.Clear());
    });
    test("individual thumbnails fall back to empty without weakening reads", [&] {
      catalog.Scan({shared}, catalog.Clear());
      const auto usable = [](const MediaEntry&, const SafeFile&) { return Bytes{3, 4}; };
      const auto unexpected = [](const MediaEntry&, const SafeFile&) -> Bytes {
        throw std::runtime_error("A missing or changed file reached the decoder");
      };
      Expect(catalog.Thumbnail(id, usable) == Bytes({3, 4}), "Usable previews are returned");
      Expect(catalog.Thumbnail(id, [](const MediaEntry&, const SafeFile& file) {
        return JpegPreview(file, 256, false);
      }).empty(), "An undecodable image has an empty preview");
      Write(photo, Bytes{0});
      Expect(catalog.Thumbnail(id, unexpected).empty(), "A changed file has an empty preview");
      Reject("FILE_CHANGED", [&] { catalog.Read(id, 0, 1); });
      Expect(DeleteFileW(photo.c_str()) != FALSE, "Delete media fixture");
      Expect(catalog.Thumbnail(id, unexpected).empty(), "A deleted file has an empty preview");
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(id, 0, 1); });
      Write(photo, bytes);
      catalog.Scan({shared}, catalog.Clear());
    });
    test("thumbnail fallback preserves sharing, I/O, root and catalog errors", [&] {
      catalog.Scan({shared}, catalog.Clear());
      const auto usable = [](const MediaEntry&, const SafeFile&) { return Bytes{1}; };
      for (const auto* code : {"PERMISSION_LOST", "IO_ERROR", "INVALID_ARGUMENT", "SCAN_CANCELLED"}) {
        Reject(code, [&] {
          catalog.Thumbnail(id, [&](const MediaEntry&, const SafeFile&) -> Bytes {
            throw StorageError(code, code);
          });
        });
      }
      {
        Handle writer(CreateFileW(photo.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                                  FILE_ATTRIBUTE_NORMAL, nullptr));
        Expect(writer.get() != INVALID_HANDLE_VALUE, "Lock media fixture");
        Reject("PERMISSION_LOST", [&] { catalog.Thumbnail(id, usable); });
      }
      Reject("FILE_NOT_FOUND", [&] { catalog.Thumbnail("unknown", usable); });
      Reject("SCAN_CANCELLED", [&] {
        catalog.Thumbnail(id, [&](const MediaEntry&, const SafeFile&) -> Bytes {
          catalog.Clear();
          throw StorageError("PREVIEW_FAILED", "Undecodable image");
        });
      });
      catalog.Scan({shared}, catalog.Clear());
      const auto moved = JoinPath(base, L"photos-moved");
      Expect(MoveFileExW(root.c_str(), moved.c_str(), 0) != FALSE, "Move shared folder");
      Reject("FILE_NOT_FOUND", [&] { catalog.Thumbnail(id, usable); });
      Expect(MoveFileExW(moved.c_str(), root.c_str(), 0) != FALSE, "Restore shared folder");
      catalog.Scan({shared}, catalog.Clear());
    });
    test("scan skips locked files, unreadable subfolders and invalid names", [&] {
      const auto locked = JoinPath(root, L"locked.jpg");
      const auto blocked = JoinPath(root, L"blocked");
      const auto trailing = L"\\\\?\\" + JoinPath(root, L"trailing.");
      Write(locked, bytes);
      std::filesystem::create_directories(blocked);
      Write(JoinPath(blocked, L"inside.jpg"), bytes);
      Expect(CreateDirectoryW(trailing.c_str(), nullptr) != FALSE, "Create folder with a trailing dot");
      Write(JoinPath(trailing, L"hidden.jpg"), bytes);
      {
        Handle file_lock(CreateFileW(locked.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING,
                                     FILE_ATTRIBUTE_NORMAL, nullptr));
        Handle folder_lock(CreateFileW(blocked.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING,
                                       FILE_FLAG_BACKUP_SEMANTICS, nullptr));
        Expect(file_lock.get() != INVALID_HANDLE_VALUE && folder_lock.get() != INVALID_HANDLE_VALUE,
               "Lock scan fixtures");
        const auto entries = catalog.Scan({shared}, catalog.Clear());
        Expect(entries.size() == 1 && entries[0].id == id, "Only readable media is shared");
        Expect(catalog.Read(id, 0, 10) == Bytes(bytes.begin(), bytes.begin() + 10),
               "Readable media is served");
      }
      Expect(catalog.Scan({shared}, catalog.Clear()).size() == 3,
             "Released files and folders are shared by the next scan");
      Expect(DeleteFileW(locked.c_str()) != FALSE, "Remove locked fixture");
      std::filesystem::remove_all(blocked);
      Expect(DeleteFileW(JoinPath(trailing, L"hidden.jpg").c_str()) != FALSE &&
             RemoveDirectoryW(trailing.c_str()) != FALSE, "Remove trailing-dot fixture");
      Expect(catalog.Scan({shared}, catalog.Clear()).size() == 1, "Fixtures removed");
    });
    test("deleted media cannot be read and refresh removes its metadata", [&] {
      catalog.Scan({shared}, catalog.Clear());
      Expect(DeleteFileW(photo.c_str()) != FALSE, "Delete media fixture");
      Reject("FILE_NOT_FOUND", [&] { catalog.Read(id, 0, 1); });
      Expect(catalog.Scan({shared}, catalog.Clear()).empty(), "Refresh removes deleted media");
      Write(photo, bytes);
      Expect(catalog.Scan({shared}, catalog.Clear()).size() == 1, "Refresh finds newly added media");
    });
    test("scan, read and save reject junction escapes", [&] {
      const auto link = JoinPath(root, L"linked-directory");
      Expect(Junction(link, staging), "Cannot create test junction");
      Write(JoinPath(staging, L"outside.jpg"), bytes);
      Expect(catalog.Scan({shared}, catalog.Clear()).size() == 1, "Scanner skips junctions");
      Reject("INVALID_ARGUMENT", [&] { SafeFile::Open(JoinPath(link, L"outside.jpg")); });
      Reject("INVALID_ARGUMENT", [&] { catalog.Validate(Utf8(link), {}); });
      const auto source = JoinPath(staging, L"complete.part");
      Write(source, bytes);
      const auto escape = JoinPath(destination, L"escape");
      Expect(Junction(escape, root), "Cannot create save junction");
      Reject("INVALID_ARGUMENT", [&] { SaveDownload({Utf8(source)}, static_cast<int64_t>(bytes.size()), {staging}, Utf8(destination), {"escape"}, "a.jpg"); });
      Expect(!std::filesystem::exists(JoinPath(root, L"a.jpg")), "Outside destination is unchanged");
      Expect(RemoveDirectoryW(link.c_str()) && RemoveDirectoryW(escape.c_str()), "Remove test junctions");
    });
    test("pinned handles deny file mutation and parent replacement", [&] {
      auto file = SafeFile::Open(photo);
      Expect(!MoveFileExW(nested.c_str(), JoinPath(root, L"moved").c_str(), 0), "Pinned parent cannot be renamed");
      Handle writer(CreateFileW(photo.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
      Expect(writer.get() == INVALID_HANDLE_VALUE, "Pinned file cannot be mutated");
      Expect(!DeleteFileW(photo.c_str()), "Pinned file cannot be deleted");
    });
    const auto source = JoinPath(staging, L"complete.part");
    Write(source, bytes);
    test("download saves nested paths, preserves bytes and never overwrites", [&] {
      const auto other_source = JoinPath(staging, L"other.part");
      const Bytes other_bytes(bytes.rbegin(), bytes.rend());
      Write(other_source, other_bytes);
      const auto first = SaveDownload({Utf8(source)}, static_cast<int64_t>(bytes.size()), {staging}, Utf8(destination), {"Peer", "Album", "旅行"}, "a.jpg");
      const auto next = SaveDownload({Utf8(other_source)}, static_cast<int64_t>(other_bytes.size()), {staging}, Utf8(destination), {"Peer", "Album", "旅行"}, "a.jpg");
      // Saving resolves DOS short names and path casing; the temporary directory
      // may use another spelling of the same location. Check the complete paths
      // against file identity without relaxing hierarchy or collision checks.
      Expect(std::filesystem::equivalent(first, JoinPath(destination, L"Peer\\Album\\旅行\\a.jpg")), "Preserve hierarchy");
      Expect(std::filesystem::equivalent(next, JoinPath(destination, L"Peer\\Album\\旅行\\a (1).jpg")), "Collision suffix");
      Expect(!std::filesystem::equivalent(first, next), "Collision creates a distinct file");
      Expect(Read(first) == bytes && Read(next) == other_bytes, "Saved bytes without overwriting");
      Reject("INVALID_ARGUMENT", [&] { SaveDownload({Utf8(source)}, static_cast<int64_t>(bytes.size()), {staging}, Utf8(destination), {".."}, "a.jpg"); });
      Reject("INVALID_ARGUMENT", [&] { SaveDownload({Utf8(photo)}, static_cast<int64_t>(bytes.size()), {staging}, Utf8(destination), {}, "a.jpg"); });
    });
    test("download resolves equivalent destination path spellings", [&] {
      auto alternate_destination = LocalPath(Utf8(destination));
      alternate_destination[0] += L'a' - L'A';
      const auto saved = SaveDownload({Utf8(source)}, static_cast<int64_t>(bytes.size()), {staging},
                                      Utf8(alternate_destination), {"alternate", "旅行"}, "a.jpg");
      const auto expected = JoinPath(alternate_destination, L"alternate\\旅行\\a.jpg");
      Expect(saved != expected, "Fixture uses different path spellings");
      Expect(std::filesystem::equivalent(saved, expected), "Equivalent paths identify the saved file");
      Expect(Read(expected) == bytes, "Saved bytes remain accessible through the original spelling");
    });
    test("delete removes one saved file, preserves siblings and tolerates absent files", [&] {
      const auto saved = SaveDownload({Utf8(source)}, static_cast<int64_t>(bytes.size()), {staging},
                                      Utf8(destination), {"delete", "旅行"}, "saved.jpg");
      const auto sibling = JoinPath(destination, L"delete\\旅行\\keep.mp4");
      Write(sibling, bytes);
      DeleteDownload(Utf8(saved));
      Expect(!std::filesystem::exists(saved), "Downloaded file removed");
      Expect(Read(sibling) == bytes && Read(photo) == bytes, "Sibling download and source remain");
      DeleteDownload(Utf8(saved));
      DeleteDownload(Utf8(JoinPath(destination, L"missing-parent\\saved.jpg")));
      Reject("", [&] { DeleteDownload(Utf8(JoinPath(destination, L"delete"))); });
      Reject("INVALID_ARGUMENT", [&] { DeleteDownload(Utf8(destination) + "\\..\\outside.jpg"); });
      Expect(std::filesystem::is_directory(JoinPath(destination, L"delete")), "Download directory preserved");
    });
    test("delete rejects junctions and preserves locked or read-only downloads", [&] {
      const auto linked = JoinPath(destination, L"delete-junction");
      Expect(Junction(linked, nested), "Create deletion junction");
      Reject("INVALID_ARGUMENT", [&] { DeleteDownload(Utf8(JoinPath(linked, L"a.jpg"))); });
      Reject("INVALID_ARGUMENT", [&] { DeleteDownload(Utf8(linked)); });
      Expect(Read(photo) == bytes, "Junction target unchanged");
      Expect(RemoveDirectoryW(linked.c_str()) != FALSE, "Remove deletion junction");
      const auto saved = JoinPath(destination, L"delete-locked.jpg");
      Write(saved, bytes);
      {
        auto reader = SafeFile::Open(saved);
        Reject("PERMISSION_LOST", [&] { DeleteDownload(Utf8(saved)); });
      }
      Expect(Read(saved) == bytes, "Locked download is preserved");
      Expect(SetFileAttributesW(saved.c_str(), FILE_ATTRIBUTE_READONLY) != FALSE, "Make download read-only");
      Reject("PERMISSION_LOST", [&] { DeleteDownload(Utf8(saved)); });
      Expect(Read(saved) == bytes, "Read-only download is preserved");
      Expect(SetFileAttributesW(saved.c_str(), FILE_ATTRIBUTE_NORMAL) != FALSE, "Restore download permissions");
      DeleteDownload(Utf8(saved));
      Expect(!std::filesystem::exists(saved), "Unlocked download can be removed");
    });
    test("ordered download parts stream directly to one destination and remain resumable", [&] {
      std::vector<std::string> parts;
      for (unsigned index = 0; index < 4; ++index) {
        const auto part = JoinPath(staging, std::to_wstring(index) + L".part");
        const auto start = bytes.begin() + index * 250;
        Write(part, Bytes(start, start + 250));
        parts.push_back(Utf8(part));
      }
      const auto saved = SaveDownload(parts, static_cast<int64_t>(bytes.size()), {staging},
                                      Utf8(destination), {}, "four-parts.jpg");
      Expect(Read(saved) == bytes, "Export preserves the order across every part boundary");
      for (const auto& part : parts) {
        Expect(Read(LocalPath(part)).size() == 250, "Export leaves original parts available until commit");
      }
      Expect(!std::filesystem::exists(JoinPath(staging, L"complete.partial")), "Export creates no merged staging copy");
      Reject("FILE_CHANGED", [&] {
        SaveDownload(parts, 999, {staging}, Utf8(destination), {}, "wrong-size.jpg");
      });
      Reject("FILE_CHANGED", [&] {
        SaveDownload(parts, 1001, {staging}, Utf8(destination), {}, "wrong-size.jpg");
      });
      Expect(!std::filesystem::exists(JoinPath(destination, L"wrong-size.jpg")), "Size mismatch creates no destination");
      parts[3] = Utf8(JoinPath(staging, L"missing.part"));
      Reject("FILE_NOT_FOUND", [&] {
        SaveDownload(parts, 1000, {staging}, Utf8(destination), {}, "missing-part.jpg");
      });
      Expect(!std::filesystem::exists(JoinPath(destination, L"missing-part.jpg")), "A missing later part creates no destination");
      parts[3] = Utf8(photo);
      Reject("INVALID_ARGUMENT", [&] {
        SaveDownload(parts, 1750, {staging}, Utf8(destination), {}, "outside-part.jpg");
      });
      Expect(!std::filesystem::exists(JoinPath(destination, L"outside-part.jpg")), "Every source must remain in private storage");
    });
    test("empty files export but empty source lists and negative sizes are rejected", [&] {
      const auto empty = JoinPath(staging, L"empty.part");
      Write(empty, {});
      const auto saved = SaveDownload({Utf8(empty)}, 0, {staging}, Utf8(destination), {}, "empty.jpg");
      Expect(SafeFile::Open(saved).info().size == 0, "Empty media produces an empty file");
      Reject("INVALID_ARGUMENT", [&] {
        SaveDownload({}, 0, {staging}, Utf8(destination), {}, "invalid.jpg");
      });
      Reject("INVALID_ARGUMENT", [&] {
        SaveDownload({Utf8(empty)}, -1, {staging}, Utf8(destination), {}, "invalid.jpg");
      });
    });
    test("transfer capacity identifies the shared volume and available bytes", [&] {
      const auto capacity = TransferSpace(staging, Utf8(destination));
      Expect(capacity.staging_available_bytes.has_value() && *capacity.staging_available_bytes >= 0,
             "Staging capacity is available");
      Expect(capacity.destination_available_bytes.has_value() && *capacity.destination_available_bytes >= 0,
             "Destination capacity is available");
      Expect(capacity.same_volume.has_value() && *capacity.same_volume, "Sibling directories share one volume");
      Reject("FILE_NOT_FOUND", [&] { TransferSpace(staging, Utf8(JoinPath(destination, L"missing"))); });
    });
    test("foreign media names adapt to Windows without accepting traversal", [&] {
      Expect(ReceivedName("CON.jpg") == "_CON.jpg", "Reserved names are prefixed");
      Expect(ReceivedName("NUL") == "_NUL", "Bare device name");
      Expect(ReceivedName("photo.jpg. ") == "photo.jpg", "Trim trailing dots and spaces");
      Expect(ReceivedName("12:30.jpg") == "12_30.jpg", "Replace foreign filename punctuation");
      Reject("INVALID_ARGUMENT", [&] { ReceivedName("../outside.jpg"); });
      Reject("INVALID_ARGUMENT", [&] { ReceivedName("a\\b.jpg"); });
      const auto saved = SaveDownload({Utf8(source)}, static_cast<int64_t>(bytes.size()), {staging}, Utf8(destination), {}, "CON.jpg");
      Expect(std::filesystem::equivalent(saved, JoinPath(destination, L"_CON.jpg")), "Save normalized reserved name");
      Expect(Read(saved) == bytes, "Reserved name conversion preserves saved bytes");
    });
    test("concurrent saves allocate unique names atomically", [&] {
      std::vector<std::wstring> saved(8);
      std::atomic<bool> failed{false};
      std::vector<std::thread> threads;
      for (size_t index = 0; index < saved.size(); ++index) {
        threads.emplace_back([&, index] {
          try { saved[index] = SaveDownload({Utf8(source)}, static_cast<int64_t>(bytes.size()), {staging}, Utf8(destination), {"parallel"}, "same.jpg"); }
          catch (...) { failed.store(true); }
        });
      }
      for (auto& thread : threads) thread.join();
      Expect(!failed.load(), "Concurrent saves succeed");
      std::sort(saved.begin(), saved.end());
      Expect(std::adjacent_find(saved.begin(), saved.end()) == saved.end(), "Each save has a distinct name");
      for (const auto& path : saved) Expect(Read(path) == bytes, "Every concurrent file is complete");
    });
    test("real WIC image preview is a bounded JPEG", [&] {
      const auto bitmap = JoinPath(root, L"real.bmp");
      Write(bitmap, Bitmap());
      auto file = SafeFile::Open(bitmap);
      CheckJpeg(JpegPreview(file, 256, false), 256, 128);
      Reject("INVALID_ARGUMENT", [&] { JpegPreview(file, 3000, false); });
      auto invalid = SafeFile::Open(photo);
      Reject("PREVIEW_FAILED", [&] { JpegPreview(invalid, 256, false); });
    });
    test("EXIF phone orientation is applied before preview scaling", [&] {
      const auto bitmap = JoinPath(root, L"real.bmp");
      auto file = SafeFile::Open(bitmap);
      const auto jpeg = JpegPreview(file, 800, false);
      // APP1 Exif TIFF with one SHORT Orientation=6 (90 degrees clockwise).
      const Bytes exif = {0xff, 0xe1, 0x00, 0x22, 'E', 'x', 'i', 'f', 0, 0,
                          'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0,
                          0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0};
      Bytes oriented(jpeg.begin(), jpeg.begin() + 2);
      oriented.insert(oriented.end(), exif.begin(), exif.end());
      oriented.insert(oriented.end(), jpeg.begin() + 2, jpeg.end());
      const auto rotated = JoinPath(root, L"portrait.jpg");
      Write(rotated, oriented);
      auto portrait = SafeFile::Open(rotated);
      CheckJpeg(JpegPreview(portrait, 256, false), 128, 256);
    });
    std::cout << passed << " Windows native storage tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL after " << passed << " tests: " << error.what() << '\n';
    return 1;
  }
}
