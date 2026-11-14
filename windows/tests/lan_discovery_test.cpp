#include "dns_service_api.h"
#include "lan_discovery.h"

#include <atomic>
#include <chrono>
#include <deque>
#include <future>
#include <iostream>
#include <map>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
using namespace std::chrono_literals;
using tamayura::DiscoveryEvent;
std::vector<std::weak_ptr<const tamayura::DnsServiceApi>> lifetimes;

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

// A DNS call is allowed to race a completion on a different thread. Wait for
// that completion before returning to expose locks held across the OS boundary.
// Timeouts are failures, but let the caller unwind so the test never hangs.
struct FakeDns {
  std::shared_ptr<tamayura::DnsServiceApi> api =
      std::make_shared<tamayura::DnsServiceApi>();
  std::mutex mutex;
  std::vector<std::thread> callbacks;
  std::vector<std::function<void()>> deferred;
  std::map<PDNS_SERVICE_CANCEL, DNS_SERVICE_REGISTER_REQUEST> registrations;
  std::map<PDNS_SERVICE_CANCEL, DNS_SERVICE_BROWSE_REQUEST> browses;
  std::map<PDNS_SERVICE_CANCEL, DNS_SERVICE_RESOLVE_REQUEST> resolves;
  std::atomic<bool> blocked{false};
  bool register_immediately = false;
  bool resolve_immediately = false;
  bool registration_wins_cancellation = false;
  bool fail_start = false;
  bool defer_cancellations = false;
  std::atomic<int> deregistrations{0};
  std::atomic<int> resolve_cancellations{0};
  std::atomic<int> resolve_starts{0};
  std::function<void()> before_resolve_returns;

  FakeDns() {
    lifetimes.push_back(api);
    api->register_service = [this](auto request, auto cancel) {
      if (fail_start) return static_cast<DWORD>(ERROR_NOT_SUPPORTED);
      {
        std::lock_guard<std::mutex> lock(mutex);
        registrations[cancel] = *request;
      }
      if (register_immediately) {
        const auto copy = *request;
        Concurrent([copy] {
          copy.pRegisterCompletionCallback(ERROR_SUCCESS, copy.pQueryContext, nullptr);
        });
      }
      return static_cast<DWORD>(DNS_REQUEST_PENDING);
    };
    api->cancel_registration = [this](auto cancel) {
      DNS_SERVICE_REGISTER_REQUEST request;
      {
        std::lock_guard<std::mutex> lock(mutex);
        request = registrations.at(cancel);
      }
      const auto status = registration_wins_cancellation ? ERROR_SUCCESS : ERROR_CANCELLED;
      CompleteOrDefer([request, status] {
        request.pRegisterCompletionCallback(status, request.pQueryContext, nullptr);
      });
      return static_cast<DWORD>(ERROR_SUCCESS);
    };
    api->deregister_service = [this](auto request, auto) {
      ++deregistrations;
      const auto copy = *request;
      Concurrent([copy] {
        copy.pRegisterCompletionCallback(ERROR_SUCCESS, copy.pQueryContext, nullptr);
      });
      return static_cast<DWORD>(DNS_REQUEST_PENDING);
    };
    api->browse = [this](auto request, auto cancel) {
      if (fail_start) return static_cast<DWORD>(ERROR_NOT_SUPPORTED);
      {
        std::lock_guard<std::mutex> lock(mutex);
        browses[cancel] = *request;
      }
      const auto copy = *request;
      Concurrent([copy] {
        copy.pBrowseCallback(ERROR_SUCCESS, copy.pQueryContext, nullptr);
      });
      return static_cast<DWORD>(DNS_REQUEST_PENDING);
    };
    api->cancel_browse = [this](auto cancel) {
      DNS_SERVICE_BROWSE_REQUEST request;
      {
        std::lock_guard<std::mutex> lock(mutex);
        request = browses.at(cancel);
        browses.erase(cancel);
      }
      CompleteOrDefer([request] {
        request.pBrowseCallback(ERROR_CANCELLED, request.pQueryContext, nullptr);
      });
      return static_cast<DWORD>(ERROR_SUCCESS);
    };
    api->resolve = [this](auto request, auto cancel) {
      ++resolve_starts;
      {
        std::lock_guard<std::mutex> lock(mutex);
        resolves[cancel] = *request;
      }
      if (resolve_immediately) {
        const auto copy = *request;
        Concurrent([copy] {
          auto address = static_cast<IP4_ADDRESS>(0x0100000a);
          const wchar_t* keys[] = {L"id", L"name", L"version"};
          const wchar_t* values[] = {L"test-peer", L"Test peer", L"4"};
          auto instance = DnsServiceConstructInstance(
              L"Test._tamayura._tcp.local", L"test.local", &address, nullptr,
              50728, 0, 0, 3, keys, values);
          copy.pResolveCompletionCallback(ERROR_SUCCESS, copy.pQueryContext, instance);
        });
      }
      if (before_resolve_returns) before_resolve_returns();
      return static_cast<DWORD>(DNS_REQUEST_PENDING);
    };
    api->cancel_resolve = [this](auto cancel) {
      ++resolve_cancellations;
      DNS_SERVICE_RESOLVE_REQUEST request;
      {
        std::lock_guard<std::mutex> lock(mutex);
        request = resolves.at(cancel);
        resolves.erase(cancel);
      }
      CompleteOrDefer([request] {
        request.pResolveCompletionCallback(ERROR_CANCELLED, request.pQueryContext, nullptr);
      });
      return static_cast<DWORD>(ERROR_SUCCESS);
    };
  }

  ~FakeDns() { Join(); }

  void CompleteOrDefer(std::function<void()> callback) {
    if (defer_cancellations) {
      std::lock_guard<std::mutex> lock(mutex);
      deferred.push_back(std::move(callback));
    } else {
      Concurrent(std::move(callback));
    }
  }

  void CompleteDeferred() {
    std::vector<std::function<void()>> pending;
    {
      std::lock_guard<std::mutex> lock(mutex);
      pending.swap(deferred);
    }
    for (auto& callback : pending) Concurrent(std::move(callback));
  }

  void Concurrent(std::function<void()> callback) {
    std::packaged_task<void()> task(std::move(callback));
    auto completed = task.get_future();
    std::thread thread(std::move(task));
    if (completed.wait_for(2s) != std::future_status::ready) blocked = true;
    std::lock_guard<std::mutex> lock(mutex);
    callbacks.push_back(std::move(thread));
  }

  void Join() {
    for (;;) {
      std::vector<std::thread> pending;
      {
        std::lock_guard<std::mutex> lock(mutex);
        pending.swap(callbacks);
      }
      if (pending.empty()) break;
      for (auto& thread : pending) thread.join();
    }
  }

  void Announce(DWORD ttl = 120, bool duplicate = false) {
    DNS_SERVICE_BROWSE_REQUEST request;
    {
      std::lock_guard<std::mutex> lock(mutex);
      Require(browses.size() == 1, "one active browse");
      request = browses.begin()->second;
    }
    wchar_t service[] = L"Test._tamayura._tcp.local";
    wchar_t type[] = L"_tamayura._tcp.local";
    DNS_RECORD record{};
    record.pName = type;
    record.wType = DNS_TYPE_PTR;
    record.wDataLength = sizeof(DNS_PTR_DATA);
    record.dwTtl = ttl;
    record.Data.PTR.pNameHost = service;
    auto copy = DnsRecordCopyEx(&record, DnsCharSetUnicode, DnsCharSetUnicode);
    Require(copy != nullptr, "allocate DNS record");
    if (duplicate) {
      copy->pNext = DnsRecordCopyEx(&record, DnsCharSetUnicode, DnsCharSetUnicode);
      Require(copy->pNext != nullptr, "allocate duplicate DNS record");
    }
    request.pBrowseCallback(ERROR_SUCCESS, request.pQueryContext, copy);
  }
};

struct Fixture {
  FakeDns dns;
  std::mutex mutex;
  std::deque<std::function<void()>> queued;
  std::vector<DiscoveryEvent> events;
  tamayura::LanDiscovery discovery{
      [this](auto callback) {
        std::lock_guard<std::mutex> lock(mutex);
        queued.push_back(std::move(callback));
      },
      [this](const auto& event) { events.push_back(event); }, dns.api};

  void Start() { discovery.Start("windows-test", "Test", 50728); }
  void Drain() {
    std::deque<std::function<void()>> callbacks;
    {
      std::lock_guard<std::mutex> lock(mutex);
      callbacks.swap(queued);
    }
    for (auto& callback : callbacks) callback();
  }
};

void TestEarlyCallbacksAndDeregister() {
  Fixture fixture;
  fixture.dns.register_immediately = true;
  fixture.dns.resolve_immediately = true;
  fixture.Start();
  fixture.dns.Announce(120, true);
  fixture.Drain();
  Require(fixture.events.size() == 1 && fixture.events[0].type == "found" &&
              fixture.events[0].id == "test-peer" && fixture.events[0].port == 50728,
          "an early resolve callback delivers the peer");
  fixture.dns.Announce();
  fixture.Drain();
  Require(fixture.events.size() == 1, "repeated broadcasts are deduplicated");
  Require(fixture.dns.resolve_starts == 1, "duplicate PTR records cannot bypass resolve backoff");
  fixture.discovery.Replay();
  fixture.discovery.Stop();
  fixture.Drain();
  Require(fixture.events.size() == 1, "stop drops already queued old events");
  Require(fixture.dns.deregistrations == 1, "registered service deregisters once");
  Require(!fixture.dns.blocked, "early callbacks and deregistration never wait for a held lock");
}

void TestStopPendingOperations() {
  Fixture fixture;
  fixture.Start();
  fixture.dns.Announce();
  fixture.discovery.Stop();
  fixture.discovery.Stop();
  fixture.Drain();
  Require(fixture.events.empty(), "cancellation does not emit stale events");
  Require(fixture.dns.resolve_cancellations == 1, "pending resolve cancels once");
  Require(!fixture.dns.blocked, "cancellation callbacks can acquire their state locks");
}

void TestGoodbyeCancellation() {
  Fixture fixture;
  fixture.Start();
  fixture.dns.Announce();
  fixture.dns.Announce(0);
  fixture.discovery.Stop();
  Require(fixture.dns.resolve_cancellations == 1, "goodbye cancels its pending resolve");
  Require(!fixture.dns.blocked, "goodbye releases the browse state before cancelling");
}

void TestRegistrationWinsCancellation() {
  Fixture fixture;
  fixture.dns.registration_wins_cancellation = true;
  fixture.Start();
  fixture.discovery.Stop();
  Require(fixture.dns.deregistrations == 1, "late successful registration is deregistered");
  Require(!fixture.dns.blocked, "registration/cancellation/deregistration callbacks do not deadlock");
}

void TestStopDuringResolveStart() {
  Fixture fixture;
  std::promise<void> entered;
  std::promise<void> release;
  auto entered_future = entered.get_future();
  auto released = release.get_future();
  fixture.dns.before_resolve_returns = [&] {
    entered.set_value();
    released.wait();
  };
  fixture.Start();
  std::thread announcement([&] { fixture.dns.Announce(); });
  const bool started = entered_future.wait_for(2s) == std::future_status::ready;
  if (started) fixture.discovery.Stop();
  const bool cancelled_early = fixture.dns.resolve_cancellations != 0;
  release.set_value();
  announcement.join();
  Require(started, "resolve started on callback thread");
  Require(!cancelled_early, "never cancel a DNS handle before its start call returns");
  Require(fixture.dns.resolve_cancellations == 1, "deferred cancellation runs after start returns");
  fixture.Drain();
  Require(fixture.events.empty() && !fixture.dns.blocked, "stop suppresses concurrent resolve events");
}

void TestFailuresAndRestarts() {
  Fixture fixture;
  fixture.dns.fail_start = true;
  fixture.Start();
  fixture.Drain();
  Require(fixture.events.size() == 2 && fixture.events[0].type == "error" &&
              fixture.events[1].type == "error", "start errors remain visible");
  fixture.discovery.Stop();
  fixture.dns.fail_start = false;
  for (int i = 0; i < 40; ++i) {
    fixture.Start();
    fixture.dns.Announce();
    fixture.discovery.Stop();
    fixture.dns.Join();
  }
  Require(fixture.dns.resolve_cancellations == 40, "restart cancels every pending resolve");
  Require(!fixture.dns.blocked, "repeated lifecycle transitions do not block");
}

void TestLateCancellationCallbacks() {
  Fixture fixture;
  fixture.dns.defer_cancellations = true;
  fixture.Start();
  fixture.dns.Announce();
  fixture.discovery.Stop();
  Require(fixture.dns.deferred.size() == 3,
          "all cancellation contexts survive until their final callbacks");
  fixture.dns.CompleteDeferred();
  fixture.Drain();
  Require(fixture.events.empty() && !fixture.dns.blocked,
          "callbacks after state destruction remain safe and silent");
}

void CheckReleased() {
  for (const auto& lifetime : lifetimes) {
    Require(lifetime.expired(), "completed DNS contexts do not retain their own lifetime");
  }
  lifetimes.clear();
}
}  // namespace

int main() {
  WSADATA sockets{};
  if (WSAStartup(MAKEWORD(2, 2), &sockets) != 0) return 1;
  try {
    TestEarlyCallbacksAndDeregister();
    CheckReleased();
    TestStopPendingOperations();
    CheckReleased();
    TestGoodbyeCancellation();
    CheckReleased();
    TestRegistrationWinsCancellation();
    CheckReleased();
    TestStopDuringResolveStart();
    CheckReleased();
    TestFailuresAndRestarts();
    CheckReleased();
    TestLateCancellationCallbacks();
    CheckReleased();
    WSACleanup();
    std::cout << "DNS lifecycle tests passed (7 groups)\n";
    return 0;
  } catch (const std::exception& error) {
    WSACleanup();
    std::cerr << error.what() << '\n';
    return 1;
  }
}
