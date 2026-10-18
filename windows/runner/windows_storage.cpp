#include "windows_storage.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <atomic>
#include <utility>

#include "app_text.h"

namespace tamayura {
namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

const EncodableValue& Argument(const EncodableMap& args, const char* key) {
  const auto found = args.find(EncodableValue(key));
  if (found == args.end()) throw StorageError("INVALID_ARGUMENT", std::string("Missing argument: ") + key);
  return found->second;
}

std::string String(const EncodableMap& args, const char* key) {
  const auto* value = std::get_if<std::string>(&Argument(args, key));
  if (!value || value->empty()) throw StorageError("INVALID_ARGUMENT", std::string("Invalid string: ") + key);
  return *value;
}

int64_t Integer(const EncodableMap& args, const char* key) {
  const auto& value = Argument(args, key);
  if (const auto* value32 = std::get_if<int32_t>(&value)) return *value32;
  if (const auto* value64 = std::get_if<int64_t>(&value)) return *value64;
  throw StorageError("INVALID_ARGUMENT", std::string("Invalid integer: ") + key);
}

std::vector<std::string> Strings(const EncodableMap& args, const char* key) {
  const auto* list = std::get_if<EncodableList>(&Argument(args, key));
  if (!list) throw StorageError("INVALID_ARGUMENT", std::string("Invalid list: ") + key);
  std::vector<std::string> result;
  for (const auto& item : *list) {
    const auto* value = std::get_if<std::string>(&item);
    if (!value) throw StorageError("INVALID_ARGUMENT", std::string("Invalid string list: ") + key);
    result.push_back(*value);
  }
  return result;
}

std::vector<SharedDirectory> SharedDirectories(const EncodableMap& arguments) {
  const auto* values = std::get_if<EncodableList>(&Argument(arguments, "directories"));
  if (!values) throw StorageError("INVALID_ARGUMENT", "Invalid shared directory list");
  std::vector<SharedDirectory> directories;
  for (const auto& value : *values) {
    const auto* folder = std::get_if<EncodableMap>(&value);
    if (!folder) throw StorageError("INVALID_ARGUMENT", "Invalid shared directory configuration");
    directories.push_back({String(*folder, "id"), String(*folder, "uri"), String(*folder, "name")});
  }
  return directories;
}

void ShellCheck(HRESULT result, const char* message) {
  if (FAILED(result)) throw StorageError("PLATFORM_ERROR", std::string(message) + " (HRESULT " + std::to_string(result) + ")");
}

EncodableValue PickDirectory(HWND window) {
  if (!window || !IsWindow(window)) throw StorageError("INVALID_ARGUMENT", "Open the application window first");
  static std::atomic<bool> picker_open{false};
  if (picker_open.exchange(true)) throw StorageError("INVALID_ARGUMENT", "The directory picker is already open");
  struct PickerGuard { std::atomic<bool>& value; ~PickerGuard() { value.store(false); } } guard{picker_open};
  ComPtr<IFileOpenDialog> picker;
  ShellCheck(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                               IID_PPV_ARGS(&picker)), "Cannot create directory picker");
  FILEOPENDIALOGOPTIONS options{};
  ShellCheck(picker->GetOptions(&options), "Cannot read directory picker options");
  ShellCheck(picker->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                                FOS_PATHMUSTEXIST | FOS_DONTADDTORECENT | FOS_NOCHANGEDIR),
              "Cannot configure directory picker");
  picker->SetTitle(app_text::Text(TextId::kChooseFolder));
  const HRESULT shown = picker->Show(window);
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return EncodableValue();
  ShellCheck(shown, "Cannot show directory picker");
  ComPtr<IShellItem> selected;
  ShellCheck(picker->GetResult(&selected), "Cannot read selected directory");
  PWSTR raw = nullptr;
  ShellCheck(selected->GetDisplayName(SIGDN_FILESYSPATH, &raw), "Select a local directory");
  std::wstring selected_path(raw);
  CoTaskMemFree(raw);
  const auto path = ValidateDirectory(Utf8(selected_path));
  auto name = path.size() == 3 ? path.substr(0, 1) : path.substr(path.find_last_of(L'\\') + 1);
  return EncodableValue(EncodableMap{{EncodableValue("uri"), EncodableValue(Utf8(path))},
                                    {EncodableValue("name"), EncodableValue(Utf8(name))}});
}

void Launch(const std::string& uri, HWND window, bool reveal) {
  const auto path = LocalPath(uri);
  if (MediaMime(path).empty()) throw StorageError("INVALID_ARGUMENT", "Only supported media files may be opened");
  // Hold every component against reparse/rename replacement until Shell receives
  // the request. Windows media applications then manage their own file access.
  auto file = SafeFile::Open(path);
  if (reveal) {
    PIDLIST_ABSOLUTE item = nullptr;
    ShellCheck(SHParseDisplayName(file.path().c_str(), nullptr, &item, 0, nullptr),
                "Cannot locate media in File Explorer");
    struct PidlGuard { PIDLIST_ABSOLUTE value; ~PidlGuard() { CoTaskMemFree(value); } } item_guard{item};
    PIDLIST_ABSOLUTE parent = ILCloneFull(item);
    if (!parent) throw StorageError("PLATFORM_ERROR", "Cannot allocate Explorer selection");
    PidlGuard parent_guard{parent};
    if (!ILRemoveLastID(parent)) throw StorageError("INVALID_ARGUMENT", "Cannot locate media parent directory");
    PCUITEMID_CHILD child = ILFindLastID(item);
    ShellCheck(SHOpenFolderAndSelectItems(parent, 1, &child, 0),
                "Cannot reveal media in File Explorer");
    return;
  }
  SHELLEXECUTEINFOW request{};
  request.cbSize = static_cast<DWORD>(sizeof(request));
  request.fMask = SEE_MASK_FLAG_NO_UI;
  request.hwnd = window;
  request.lpVerb = L"open";
  request.lpFile = file.path().c_str();
  request.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&request)) {
    throw StorageError("OPEN_FAILED", "Cannot open media with the default application (Windows " +
                                          std::to_string(GetLastError()) + ")");
  }
}

EncodableValue Metadata(const MediaEntry& entry) {
  return EncodableValue(EncodableMap{
      {EncodableValue("id"), EncodableValue(entry.id)},
      {EncodableValue("name"), EncodableValue(entry.name)},
      {EncodableValue("mimeType"), EncodableValue(entry.mime_type)},
      {EncodableValue("size"), EncodableValue(entry.size)},
      {EncodableValue("modifiedMs"), EncodableValue(entry.modified_ms)},
      {EncodableValue("sharedFolderId"), EncodableValue(entry.shared_folder_id)},
      {EncodableValue("sharedFolderName"), EncodableValue(entry.shared_folder_name)},
      {EncodableValue("relativePath"), EncodableValue(entry.relative_path)}});
}

}  // namespace

uint64_t WindowsStorage::BeginScan(const EncodableMap& arguments) {
  std::set<std::string> ids;
  for (const auto& directory : SharedDirectories(arguments)) ids.insert(directory.id);
  return catalog_.BeginScan(ids);
}

EncodableValue WindowsStorage::Handle(const std::string& method,
                                      const EncodableMap& arguments, HWND window) {
  if (method == "pickDirectory") return PickDirectory(window);
  if (method == "validateSharedDirectory") {
    catalog_.Validate(String(arguments, "uri"), Strings(arguments, "existingUris"));
  } else if (method == "scanDirectoriesMetadata") {
    const auto ticket = arguments.find(EncodableValue("__generation"));
    const auto expected = ticket == arguments.end() ? BeginScan(arguments) :
        static_cast<uint64_t>(Integer(arguments, "__generation"));
    const auto directories = SharedDirectories(arguments);
    EncodableList result;
    for (const auto& entry : catalog_.Scan(directories, expected)) result.push_back(Metadata(entry));
    return EncodableValue(std::move(result));
  } else if (method == "clearSharedDirectory") {
    catalog_.Clear();
  } else if (method == "readRange") {
    return EncodableValue(catalog_.Read(String(arguments, "id"),
                                        Integer(arguments, "offset"), Integer(arguments, "length")));
  } else if (method == "thumbnail") {
    // Metadata remains available without an installed codec or a readable file.
    return EncodableValue(catalog_.Thumbnail(String(arguments, "id"),
        [](const MediaEntry& entry, const SafeFile& file) {
          return JpegPreview(file, 256, entry.mime_type.rfind("video/", 0) == 0);
        }));
  } else if (method == "readPreview") {
    const auto maximum = Integer(arguments, "maxDimension");
    if (maximum < 1 || maximum > 2560) throw StorageError("INVALID_ARGUMENT", "Preview size must be 1..2560");
    const auto path = LocalPath(String(arguments, "uri"));
    const auto mime = MediaMime(path);
    if (mime.empty()) throw StorageError("INVALID_ARGUMENT", "Unsupported media file");
    auto file = SafeFile::Open(path);
    return EncodableValue(JpegPreview(file, static_cast<unsigned>(maximum), mime.rfind("video/", 0) == 0));
  } else if (method == "saveDownload") {
    const auto saved = SaveDownload(Strings(arguments, "sourcePaths"), Integer(arguments, "expectedSize"),
        {PrivateDirectory(L"cache"), PrivateDirectory(L"transfers")},
        String(arguments, "directoryUri"), Strings(arguments, "directories"),
        String(arguments, "name"));
    return EncodableValue(Utf8(saved));
  } else if (method == "deleteDownload") {
    DeleteDownload(String(arguments, "uri"));
  } else if (method == "transferSpace") {
    const auto space = TransferSpace(PrivateDirectory(L"transfers"), String(arguments, "directoryUri"));
    EncodableMap result;
    if (space.staging_available_bytes) {
      result[EncodableValue("stagingAvailableBytes")] = EncodableValue(*space.staging_available_bytes);
    }
    if (space.destination_available_bytes) {
      result[EncodableValue("destinationAvailableBytes")] = EncodableValue(*space.destination_available_bytes);
    }
    if (space.same_volume) {
      result[EncodableValue("sameVolume")] = EncodableValue(*space.same_volume);
    }
    return EncodableValue(std::move(result));
  } else if (method == "temporaryDirectory") {
    return EncodableValue(Utf8(PrivateDirectory(L"cache")));
  } else if (method == "transferDirectory") {
    return EncodableValue(Utf8(PrivateDirectory(L"transfers")));
  } else if (method == "databaseDirectory") {
    return EncodableValue(Utf8(PrivateDirectory(L"databases")));
  } else if (method == "open" || method == "share") {
    Launch(String(arguments, "uri"), window, method == "share");
  } else {
    throw StorageError("NOT_IMPLEMENTED", "Unknown storage method: " + method);
  }
  return EncodableValue();
}

}  // namespace tamayura
