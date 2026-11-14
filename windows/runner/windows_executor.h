#ifndef TAMAYURA_WINDOWS_EXECUTOR_H_
#define TAMAYURA_WINDOWS_EXECUTOR_H_

#include <windows.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace tamayura {
// One wake-up per queue, with bounded batches. A timer between batches lets
// Windows dispatch input and paint before another burst of native completions.
class UiDispatcher {
 public:
  static constexpr UINT kMessage = WM_APP + 77;
  static constexpr UINT_PTR kTimer = 0x544d77;
  static constexpr size_t kBatchSize = 32;
  explicit UiDispatcher(HWND window) : window_(window) {}
  void Post(std::function<void()> action);
  void Drain();
  void Shutdown();

 private:
  std::mutex mutex_;
  HWND window_;
  bool wake_pending_ = false;
  bool draining_ = false;
  std::deque<std::function<void()>> pending_;
};

class WorkerPool {
 public:
  using ThreadFactory = std::function<std::thread(std::function<void()>)>;
  explicit WorkerPool(unsigned count = ThreadCount(), ThreadFactory create_thread = {});
  ~WorkerPool();
  bool Submit(std::function<void()> work);
  void Stop();
  static unsigned ThreadCount();

 private:
  std::mutex mutex_;
  std::condition_variable ready_;
  bool stopped_ = false;
  std::deque<std::function<void()>> pending_;
  std::vector<std::thread> workers_;
};
}  // namespace tamayura
#endif
