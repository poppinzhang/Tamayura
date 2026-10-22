#ifndef TAMAYURA_MAIN_DISPATCHER_H_
#define TAMAYURA_MAIN_DISPATCHER_H_

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace tamayura {

// Flutter's Linux messenger and FlValue must only be used on the GTK main
// thread. Workers and the Avahi thread post their results here.
class MainDispatcher {
 public:
  MainDispatcher();
  // Thread-safe. Runs `action` from the default GLib main context, never
  // synchronously, unless the dispatcher has been shut down.
  void Post(std::function<void()> action);
  // Drops queued actions; later posts are ignored.
  void Shutdown();

  // Shared with the pending GLib idle source.
  struct Queue;

 private:
  std::shared_ptr<Queue> queue_;
};

class WorkerPool {
 public:
  WorkerPool();
  ~WorkerPool();
  WorkerPool(const WorkerPool&) = delete;
  WorkerPool& operator=(const WorkerPool&) = delete;
  void Submit(std::function<void()> work);
  void Stop();
  // One worker per hardware thread; four when the count cannot be determined.
  static unsigned ThreadCount();

 private:
  std::mutex mutex_;
  std::condition_variable ready_;
  bool stopped_ = false;
  std::deque<std::function<void()>> pending_;
  std::vector<std::thread> workers_;
};

}  // namespace tamayura

#endif  // TAMAYURA_MAIN_DISPATCHER_H_
