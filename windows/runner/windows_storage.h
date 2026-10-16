#ifndef TAMAYURA_WINDOWS_STORAGE_H_
#define TAMAYURA_WINDOWS_STORAGE_H_

#include <flutter/encodable_value.h>

#include "storage_core.h"

namespace tamayura {

class WindowsStorage {
 public:
  // Capture on the platform thread before queuing a scan. A later clear must
  // cancel both running scans and scans that have not started on a worker yet.
  uint64_t BeginScan() { return catalog_.Clear(); }
  flutter::EncodableValue Handle(const std::string& method,
                                 const flutter::EncodableMap& arguments,
                                 HWND window);

 private:
  MediaCatalog catalog_;
};

}  // namespace tamayura

using WindowsStorage = tamayura::WindowsStorage;
using StorageError = tamayura::StorageError;

#endif  // TAMAYURA_WINDOWS_STORAGE_H_
