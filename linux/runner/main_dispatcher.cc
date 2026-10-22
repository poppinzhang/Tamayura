#include "main_dispatcher.h"

#include <glib.h>

namespace tamayura {

struct MainDispatcher::Queue {
  std::mutex mutex;
  bool active = true;
  bool scheduled = false;
  std::deque<std::function<void()>> pending;
};

namespace {

gboolean Drain(gpointer data) {
  const auto queue = *static_cast<std::shared_ptr<MainDispatcher::Queue>*>(data);
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(queue->mutex);
    queue->scheduled = false;
    if (!queue->active) return G_SOURCE_REMOVE;
    tasks.swap(queue->pending);
  }
  for (auto& task : tasks) {
    {
      // An action may shut the dispatcher down; drop the rest of the batch.
      std::lock_guard<std::mutex> lock(queue->mutex);
      if (!queue->active) break;
    }
    task();
  }
  return G_SOURCE_REMOVE;
}

void Release(gpointer data) {
  delete static_cast<std::shared_ptr<MainDispatcher::Queue>*>(data);
}

}  // namespace

MainDispatcher::MainDispatcher() : queue_(std::make_shared<Queue>()) {}

void MainDispatcher::Post(std::function<void()> action) {
  std::lock_guard<std::mutex> lock(queue_->mutex);
  if (!queue_->active) return;
  queue_->pending.push_back(std::move(action));
  if (queue_->scheduled) return;
  queue_->scheduled = true;
  g_idle_add_full(G_PRIORITY_DEFAULT, Drain, new std::shared_ptr<Queue>(queue_),
                  Release);
}

void MainDispatcher::Shutdown() {
  std::lock_guard<std::mutex> lock(queue_->mutex);
  queue_->active = false;
  queue_->pending.clear();
}

unsigned WorkerPool::ThreadCount() {
  const unsigned hardware = std::thread::hardware_concurrency();
  return hardware == 0 ? 4 : hardware;
}

// Scans, thumbnails, peer reads and saves share this pool. Sizing it to the
// machine keeps one slow folder or a long save from queueing every request.
WorkerPool::WorkerPool() {
  const unsigned count = ThreadCount();
  for (unsigned i = 0; i < count; ++i) {
    workers_.emplace_back([this] {
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
    });
  }
}

WorkerPool::~WorkerPool() { Stop(); }

void WorkerPool::Submit(std::function<void()> work) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) return;
    pending_.push_back(std::move(work));
  }
  ready_.notify_one();
}

void WorkerPool::Stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopped_ = true;
    pending_.clear();
  }
  ready_.notify_all();
  for (auto& worker : workers_) {
    if (worker.joinable()) worker.join();
  }
  workers_.clear();
}

}  // namespace tamayura
