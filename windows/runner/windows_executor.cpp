#include "windows_executor.h"

#include <objbase.h>

#include <algorithm>
#include <utility>

namespace tamayura {
void UiDispatcher::Post(std::function<void()> action) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!window_) return;
  pending_.push_back(std::move(action));
  if (!wake_pending_) wake_pending_ = PostMessageW(window_, kMessage, 0, 0) != FALSE;
  // Keep responses when the Windows message queue is temporarily full. The
  // platform's regular maintenance timer also drains this queue.
}

void UiDispatcher::Drain() {
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!window_ || draining_) return;
    draining_ = true;
    KillTimer(window_, kTimer);
    wake_pending_ = true;
    for (size_t i = 0; i < kBatchSize && !pending_.empty(); ++i) {
      tasks.push_back(std::move(pending_.front()));
      pending_.pop_front();
    }
  }
  for (auto& task : tasks) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!window_) return;
    }
    task();
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!window_) return;
    draining_ = false;
    wake_pending_ = false;
    if (!pending_.empty()) {
      wake_pending_ = SetTimer(window_, kTimer, 1, nullptr) != 0;
      if (!wake_pending_) wake_pending_ = PostMessageW(window_, kMessage, 0, 0) != FALSE;
    }
  }
}

void UiDispatcher::Shutdown() {
  std::deque<std::function<void()>> abandoned;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (window_) KillTimer(window_, kTimer);
    window_ = nullptr;
    wake_pending_ = false;
    abandoned.swap(pending_);
  }
}

unsigned WorkerPool::ThreadCount() {
  const unsigned hardware = std::thread::hardware_concurrency();
  return hardware == 0 ? 4 : std::clamp(hardware, 2u, 8u);
}

WorkerPool::WorkerPool(unsigned count, ThreadFactory create_thread) {
  // Allocate before starting threads: allocation failure must not destroy a
  // newly created, joinable temporary thread and terminate the whole process.
  workers_.reserve(std::max(1u, count));
  try {
    for (unsigned i = 0; i < std::max(1u, count); ++i) {
      auto run = [this] {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        for (;;) {
          std::function<void()> task;
          {
            std::unique_lock<std::mutex> lock(mutex_);
            ready_.wait(lock, [this] { return stopped_ || !pending_.empty(); });
            if (stopped_) break;
            task = std::move(pending_.front());
            pending_.pop_front();
          }
          task();
        }
        if (SUCCEEDED(com)) CoUninitialize();
      };
      workers_.push_back(create_thread ? create_thread(std::move(run))
                                       : std::thread(std::move(run)));
    }
  } catch (...) {
    // The destructor does not run when construction fails. Stop and join any
    // workers already started before propagating the original creation error.
    Stop();
    throw;
  }
}

WorkerPool::~WorkerPool() { Stop(); }

bool WorkerPool::Submit(std::function<void()> work) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) return false;
    pending_.push_back(std::move(work));
  }
  ready_.notify_one();
  return true;
}

void WorkerPool::Stop() {
  std::deque<std::function<void()>> abandoned;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopped_ = true;
    abandoned.swap(pending_);
  }
  ready_.notify_all();
  for (auto& worker : workers_) if (worker.joinable()) worker.join();
  workers_.clear();
}
}  // namespace tamayura
