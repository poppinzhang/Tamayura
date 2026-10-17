#ifndef TAMAYURA_WINDOWS_UPDATE_H_
#define TAMAYURA_WINDOWS_UPDATE_H_

#include <windows.h>

#include <cstdint>
#include <mutex>
#include <string>

namespace tamayura {

class WindowsUpdate {
 public:
  ~WindowsUpdate();
  static std::string Directory();
  void Prepare(const std::string& archive, const std::string& sha256,
               const std::string& version, int64_t build_number);
  bool prepared() const;

 private:
  bool PreparedLocked() const;
  mutable std::mutex state_mutex_;
  bool busy_ = false;
  bool prepared_ = false;
  HANDLE helper_process_ = nullptr;
  std::wstring prepared_workspace_;
};

}
#endif
