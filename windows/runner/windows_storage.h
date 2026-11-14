#ifndef TAMAYURA_WINDOWS_STORAGE_H_
#define TAMAYURA_WINDOWS_STORAGE_H_

#include <flutter/encodable_value.h>

#include "storage_core.h"
#include "catalog_watcher.h"

namespace tamayura {

class WindowsStorage {
 public:
  // Capture on the platform thread before queuing a scan or cache restore. A
  // later operation or clear cancels work running or still waiting on a worker.
  // Retained folders keep serving peers until the new scan publishes.
  uint64_t BeginScan(const flutter::EncodableMap& arguments);
  // Start/Stop are called only on the platform's single catalog worker, except
  // final teardown after that worker has been joined. Clear only revokes media.
  void StartWatching(const flutter::EncodableMap& arguments, CatalogWatcher::Emit emit);
  void StopWatching();
  flutter::EncodableValue Handle(const std::string& method,
                                 const flutter::EncodableMap& arguments,
                                 HWND window);

 private:
  MediaCatalog catalog_;
  CatalogWatcher watcher_;
};

}  // namespace tamayura

using WindowsStorage = tamayura::WindowsStorage;
using StorageError = tamayura::StorageError;

#endif  // TAMAYURA_WINDOWS_STORAGE_H_
