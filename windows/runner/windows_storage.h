#ifndef TAMAYURA_WINDOWS_STORAGE_H_
#define TAMAYURA_WINDOWS_STORAGE_H_

#include <flutter/encodable_value.h>

#include "storage_core.h"

namespace tamayura {

class WindowsStorage {
 public:
  // Capture on the platform thread before queuing a scan. A later scan or
  // clear must cancel both running scans and scans not yet on a worker.
  // Retained folders keep serving peers until the new scan publishes.
  uint64_t BeginScan(const flutter::EncodableMap& arguments);
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
