#ifndef TAMAYURA_CATALOG_WATCHER_H_
#define TAMAYURA_CATALOG_WATCHER_H_

#include "storage_core.h"

#include <functional>
#include <memory>

namespace tamayura {

struct CatalogWatchEvent {
  enum class Type { kChanged, kOverflow, kError };
  Type type = Type::kChanged;
  int64_t generation = 0;
  std::vector<CatalogChange> changes;
  DWORD error = ERROR_SUCCESS;
};

// Decode a single Windows notification buffer. Invalid/truncated notifications
// require a full scan; never treat an incomplete buffer as a complete change set.
CatalogWatchEvent DecodeCatalogNotifications(const uint8_t* bytes, size_t size,
                                             const std::string& folder_id,
                                             int64_t generation);

// A process-owned watcher, with one IOCP thread shared by every configured root.
// Start/Stop are serialized by the caller. Emit runs on the worker and must not
// synchronously call Start/Stop. Stop drains canceled I/O before freeing buffers.
class CatalogWatcher {
 public:
  using Emit = std::function<void(CatalogWatchEvent)>;
  CatalogWatcher();
  ~CatalogWatcher();
  CatalogWatcher(const CatalogWatcher&) = delete;
  CatalogWatcher& operator=(const CatalogWatcher&) = delete;
  void Start(const std::vector<SharedDirectory>& directories,
             int64_t generation, Emit emit);
  void Stop();

 private:
  struct State;
  std::unique_ptr<State> state_;
};

}  // namespace tamayura
#endif
