#include "windows_update.h"

#include <windows.h>
#include <objbase.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <regex>
#include <vector>

#include "storage_core.h"

namespace tamayura {
namespace {

std::wstring QuoteArgument(const std::wstring& value) {
  std::wstring quoted = L"\"";
  size_t slashes = 0;
  for (const auto character : value) {
    if (character == L'\\') {
      ++slashes;
    } else {
      quoted.append(slashes * (character == L'\"' ? 2 : 1), L'\\');
      if (character == L'\"') quoted += L'\\';
      quoted += character;
      slashes = 0;
    }
  }
  quoted.append(slashes * 2, L'\\');
  return quoted + L'\"';
}

std::filesystem::path ApplicationDirectory() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                         static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    throw StorageError("UPDATE_UNAVAILABLE", "Cannot locate the installed application.");
  }
  return std::filesystem::path(std::wstring(path.data(), length)).parent_path();
}

std::wstring UniqueName() {
  GUID identifier{};
  wchar_t value[40]{};
  if (FAILED(CoCreateGuid(&identifier)) || StringFromGUID2(identifier, value, 40) != 39) {
    throw StorageError("UPDATE_UNAVAILABLE", "Cannot create the update workspace.");
  }
  return std::wstring(value + 1, 36);
}

}

std::string WindowsUpdate::Directory() {
  return Utf8(PrivateDirectory(L"updates"));
}

WindowsUpdate::~WindowsUpdate() {
  if (helper_process_) CloseHandle(helper_process_);
}

bool WindowsUpdate::prepared() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return PreparedLocked();
}

bool WindowsUpdate::PreparedLocked() const {
  if (!prepared_) return false;
  std::error_code error;
  if (std::filesystem::exists(std::filesystem::path(prepared_workspace_) / L"error.txt", error) || error) {
    return false;
  }
  return helper_process_ && WaitForSingleObject(helper_process_, 0) == WAIT_TIMEOUT;
}

void WindowsUpdate::Prepare(const std::string& archive, const std::string& sha256,
                            const std::string& version, int64_t build_number) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (prepared_ && !PreparedLocked()) {
      CloseHandle(helper_process_);
      helper_process_ = nullptr;
      prepared_ = false;
      busy_ = false;
    }
    if (busy_) {
      throw StorageError("UPDATE_BUSY", "An update is already being prepared.");
    }
    busy_ = true;
  }
  try {
    if (!std::regex_match(sha256, std::regex("[a-fA-F0-9]{64}")) ||
        !std::regex_match(version, std::regex("[0-9]+\\.[0-9]+\\.[0-9]+")) ||
        build_number < 1 || build_number > 65535) {
      throw StorageError("INVALID_ARGUMENT", "Invalid update version or checksum.");
    }
    const auto cache = PrivateDirectory(L"updates");
    const auto archive_path = LocalPath(archive);
    if (!ContainsPath(cache, archive_path)) {
      throw StorageError("INVALID_ARGUMENT", "The update must be downloaded to the update cache.");
    }
    const auto pinned_archive = SafeFile::Open(archive_path);
    const auto target = ApplicationDirectory();
    const auto script = target / L"tamayura-update.ps1";
    const auto pinned_script = SafeFile::Open(script.wstring());
    const auto workspace = std::filesystem::path(cache) / UniqueName();
    std::filesystem::create_directory(workspace);
    std::filesystem::copy_file(script, workspace / L"tamayura-update.ps1");
    wchar_t system_directory[MAX_PATH]{};
    if (GetSystemDirectoryW(system_directory, MAX_PATH) == 0) {
      throw StorageError("UPDATE_UNAVAILABLE", "Cannot locate Windows PowerShell.");
    }
    const auto powershell = std::filesystem::path(system_directory) /
        L"WindowsPowerShell\\v1.0\\powershell.exe";
    const std::vector<std::wstring> arguments{
        powershell.wstring(), L"-NoLogo", L"-NoProfile", L"-NonInteractive",
        L"-ExecutionPolicy", L"Bypass", L"-File",
        (workspace / L"tamayura-update.ps1").wstring(), L"-Mode", L"Prepare",
        L"-Archive", archive_path, L"-Sha256", Wide(sha256),
        L"-Version", Wide(version), L"-BuildNumber", std::to_wstring(build_number),
        L"-Target", target.wstring(), L"-ParentProcessId", std::to_wstring(GetCurrentProcessId()),
        L"-Workspace", workspace.wstring()};
    std::wstring command;
    for (const auto& argument : arguments) {
      if (!command.empty()) command += L' ';
      command += QuoteArgument(argument);
    }
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    Handle job(CreateJobObjectW(nullptr, nullptr));
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job.get() || !SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation,
                                               &limits, sizeof(limits))) {
      throw StorageError("UPDATE_UNAVAILABLE", "Cannot supervise the Windows update installer.");
    }
    if (!CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, workspace.c_str(), &startup, &process)) {
      throw StorageError("UPDATE_UNAVAILABLE", "Cannot start Windows PowerShell. Check system policy and retry.");
    }
    Handle thread(process.hThread);
    Handle child(process.hProcess);
    if (!AssignProcessToJobObject(job.get(), child.get()) ||
        ResumeThread(thread.get()) == static_cast<DWORD>(-1)) {
      TerminateProcess(child.get(), 1);
      WaitForSingleObject(child.get(), 10000);
      throw StorageError("UPDATE_UNAVAILABLE", "Cannot supervise the Windows update installer. Check system policy and retry.");
    }
    DWORD exit_code = 1;
    if (WaitForSingleObject(child.get(), 600000) != WAIT_OBJECT_0) {
      TerminateJobObject(job.get(), 1);
      WaitForSingleObject(child.get(), 10000);
      throw StorageError("UPDATE_TIMEOUT", "Update preparation exceeded ten minutes. Close programs using the application, check free space, and retry.");
    }
    if (!GetExitCodeProcess(child.get(), &exit_code) || exit_code != 0) {
      std::ifstream error(workspace / L"error.txt", std::ios::binary);
      std::string message((std::istreambuf_iterator<char>(error)), {});
      if (message.empty() || message.size() > 8192) {
        message = "Update preparation failed. Check free space, write permissions and system policy, then retry.";
      }
      throw StorageError("UPDATE_PREPARE_FAILED", message);
    }
    std::ifstream ready(workspace / L"ready");
    DWORD helper_id = 0;
    ready >> helper_id;
    if (!ready || helper_id == 0) {
      throw StorageError("UPDATE_UNAVAILABLE", "The update installer did not become ready.");
    }
    Handle helper(OpenProcess(SYNCHRONIZE, FALSE, helper_id));
    if (!helper.get() || WaitForSingleObject(helper.get(), 0) != WAIT_TIMEOUT) {
      throw StorageError("UPDATE_UNAVAILABLE", "The update installer stopped unexpectedly. Retry the update.");
    }
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (!DuplicateHandle(GetCurrentProcess(), helper.get(), GetCurrentProcess(),
                           &helper_process_, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
        throw StorageError("UPDATE_UNAVAILABLE", "Cannot monitor the Windows update installer.");
      }
      prepared_workspace_ = workspace.wstring();
      limits.BasicLimitInformation.LimitFlags = 0;
      if (!SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation,
                                   &limits, sizeof(limits))) {
        throw StorageError("UPDATE_UNAVAILABLE", "Cannot hand off to the Windows update installer.");
      }
      prepared_ = true;
    }
  } catch (const StorageError&) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (helper_process_) CloseHandle(helper_process_);
    helper_process_ = nullptr;
    busy_ = false;
    prepared_ = false;
    throw;
  } catch (...) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (helper_process_) CloseHandle(helper_process_);
    helper_process_ = nullptr;
    busy_ = false;
    prepared_ = false;
    throw StorageError("UPDATE_PREPARE_FAILED", "Cannot prepare the update. Check free space and file permissions, then retry.");
  }
}

}
