#include "windows_executor.h"

#include <atomic>
#include <chrono>
#include <future>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace {
using namespace std::chrono_literals;

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

struct Window {
  static constexpr UINT kProbe = WM_APP + 80;
  HWND handle;
  std::unique_ptr<tamayura::UiDispatcher> dispatcher;
  size_t completed = 0;
  size_t at_probe = 0;
  bool probed = false;

  Window() {
    handle = CreateWindowW(L"TamayuraExecutorTest", L"", 0, 0, 0, 0, 0,
                           HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), this);
    Require(handle != nullptr, "message window created");
    dispatcher = std::make_unique<tamayura::UiDispatcher>(handle);
  }
  ~Window() {
    dispatcher->Shutdown();
    DestroyWindow(handle);
  }
  static LRESULT CALLBACK Procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto self = reinterpret_cast<Window*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self && self->dispatcher) {
      if (message == tamayura::UiDispatcher::kMessage ||
          (message == WM_TIMER && wparam == tamayura::UiDispatcher::kTimer)) {
        self->dispatcher->Drain();
        return 0;
      }
      if (message == kProbe) {
        self->at_probe = self->completed;
        self->probed = true;
        return 0;
      }
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }
};

void TestDispatchBurst() {
  Window window;
  std::vector<std::thread> workers;
  const auto ui_thread = GetCurrentThreadId();
  bool wrong_thread = false;
  for (int worker = 0; worker < 4; ++worker) {
    workers.emplace_back([&] {
      for (int task = 0; task < 500; ++task) {
        window.dispatcher->Post([&] {
          if (GetCurrentThreadId() != ui_thread) wrong_thread = true;
          ++window.completed;
        });
      }
    });
  }
  for (auto& worker : workers) worker.join();
  MSG message{};
  unsigned wakes = 0;
  while (PeekMessageW(&message, window.handle, tamayura::UiDispatcher::kMessage,
                     tamayura::UiDispatcher::kMessage, PM_REMOVE)) ++wakes;
  Require(wakes == 1, "a 2000-response burst posts only one wake-up");
  window.dispatcher->Drain();
  Require(window.completed == tamayura::UiDispatcher::kBatchSize,
          "a single dispatch processes only a bounded batch");
  PostMessageW(window.handle, Window::kProbe, 0, 0);
  const auto deadline = std::chrono::steady_clock::now() + 5s;
  while (window.completed < 2000 && std::chrono::steady_clock::now() < deadline) {
    if (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    } else {
      MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
    }
  }
  Require(window.completed == 2000 && !wrong_thread, "all responses complete once on the UI thread");
  Require(window.probed && window.at_probe == tamayura::UiDispatcher::kBatchSize,
          "normal window messages run between completion batches");
}

void TestShutdownAndReentrancy() {
  Window window;
  bool late_called = false;
  bool nested_called = false;
  window.dispatcher->Post([&] {
    window.dispatcher->Post([&] { nested_called = true; });
    window.dispatcher->Drain();
    Require(!nested_called, "nested message pumps cannot recursively drain the queue");
    window.dispatcher->Shutdown();
  });
  window.dispatcher->Post([&] { late_called = true; });
  window.dispatcher->Drain();
  window.dispatcher->Post([&] { late_called = true; });
  window.dispatcher->Drain();
  Require(!late_called && !nested_called, "shutdown suppresses queued and already-batched responses");
}

void TestCallbackDestroysOwner() {
  Window window;
  struct Owner {
    std::shared_ptr<tamayura::UiDispatcher> dispatcher;
    ~Owner() { dispatcher->Shutdown(); }
    void Tick() {
      const auto current = dispatcher;
      current->Drain();
    }
  };
  auto owner = std::make_unique<Owner>();
  owner->dispatcher = std::make_shared<tamayura::UiDispatcher>(window.handle);
  std::weak_ptr<tamayura::UiDispatcher> lifetime = owner->dispatcher;
  bool survived_callback = false;
  bool late_called = false;
  owner->dispatcher->Post([&] {
    owner.reset();
    survived_callback = !lifetime.expired();
  });
  owner->dispatcher->Post([&] { late_called = true; });
  owner->Tick();
  Require(!owner && survived_callback && lifetime.expired() && !late_called,
          "a callback can destroy its owner without destroying an active dispatcher or replying afterward");
}

void TestPartialThreadCreationFailure() {
  std::atomic<unsigned> active{0};
  std::atomic<unsigned> exited{0};
  unsigned attempts = 0;
  bool threw = false;
  try {
    tamayura::WorkerPool pool(4, [&](std::function<void()> run) {
      if (++attempts == 3) throw std::runtime_error("simulated thread creation failure");
      return std::thread([&, run = std::move(run)] {
        ++active;
        run();
        --active;
        ++exited;
      });
    });
  } catch (const std::runtime_error& error) {
    threw = std::string(error.what()) == "simulated thread creation failure";
  }
  Require(threw && attempts == 3 && exited == 2 && active == 0,
          "partial construction joins every started thread and preserves the original error");
}

void TestPreviewIsolation() {
  tamayura::WorkerPool io(2);
  tamayura::WorkerPool previews(2);
  std::promise<void> release;
  auto gate = release.get_future().share();
  std::promise<void> entered_one;
  std::promise<void> entered_two;
  auto first = entered_one.get_future();
  auto second = entered_two.get_future();
  previews.Submit([&] { entered_one.set_value(); gate.wait(); });
  previews.Submit([&] { entered_two.set_value(); gate.wait(); });
  const bool both_running = first.wait_for(2s) == std::future_status::ready &&
      second.wait_for(2s) == std::future_status::ready;
  std::promise<void> read_done;
  auto read = read_done.get_future();
  io.Submit([&] { read_done.set_value(); });
  const bool io_completed = read.wait_for(2s) == std::future_status::ready;
  release.set_value();
  Require(both_running && io_completed, "blocked preview providers do not consume file-transfer workers");
  Require(tamayura::WorkerPool::ThreadCount() >= 2 &&
              tamayura::WorkerPool::ThreadCount() <= 8, "default I/O concurrency is bounded");
}

void TestStopDropsPending() {
  tamayura::WorkerPool pool(1);
  std::promise<void> entered;
  auto running = entered.get_future();
  std::promise<void> release;
  auto gate = release.get_future();
  std::atomic<unsigned> late{0};
  pool.Submit([&] { entered.set_value(); gate.wait(); });
  const bool started = running.wait_for(2s) == std::future_status::ready;
  pool.Submit([&] { ++late; });
  std::thread stopping([&] { pool.Stop(); });
  const auto deadline = std::chrono::steady_clock::now() + 2s;
  bool rejected = false;
  while (std::chrono::steady_clock::now() < deadline) {
    if (!pool.Submit([&] { ++late; })) { rejected = true; break; }
    std::this_thread::yield();
  }
  release.set_value();
  stopping.join();
  Require(started && rejected && late == 0, "stop preserves active work and discards pending work");
}
}  // namespace

int main() {
  try {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = Window::Procedure;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"TamayuraExecutorTest";
    Require(RegisterClassW(&window_class) != 0, "test window class registered");
    TestDispatchBurst();
    TestShutdownAndReentrancy();
    TestCallbackDestroysOwner();
    TestPreviewIsolation();
    TestStopDropsPending();
    TestPartialThreadCreationFailure();
    Require(UnregisterClassW(window_class.lpszClassName, window_class.hInstance),
            "test windows destroyed");
    std::cout << "Windows executor tests passed (6 groups)\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
