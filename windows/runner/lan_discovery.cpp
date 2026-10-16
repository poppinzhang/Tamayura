#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <windns.h>

#include "lan_discovery.h"

#include <algorithm>
#include <chrono>
#include <cwctype>
#include <map>
#include <mutex>
#include <set>
#include <utility>
#include <vector>

#include "discovery_core.h"
#include "storage_core.h"
#include "windows_platform.h"

namespace tamayura {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Clock = std::chrono::steady_clock;
constexpr wchar_t kServiceType[] = L"_tamayura._tcp.local";

std::wstring ComputerName() {
  wchar_t value[256]{};
  DWORD length = 256;
  if (GetComputerNameExW(ComputerNameDnsHostname, value, &length) && length > 0) return value;
  return L"Windows";
}

std::wstring ServiceKey(const wchar_t* name) {
  if (!name) return {};
  std::wstring key(name);
  while (!key.empty() && key.back() == L'.') key.pop_back();
  std::transform(key.begin(), key.end(), key.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  const std::wstring suffix = L"." + std::wstring(kServiceType);
  if (key.size() <= suffix.size() || key.size() > 255 ||
      key.compare(key.size() - suffix.size(), suffix.size(), suffix) != 0) return {};
  return key;
}

std::string AddressText(IP4_ADDRESS address) {
  IN_ADDR value{};
  value.S_un.S_addr = address;
  char text[INET_ADDRSTRLEN]{};
  if (!InetNtopA(AF_INET, &value, text, sizeof(text))) return {};
  return IsPrivateIPv4(text) ? text : std::string();
}

Map ErrorEvent(const char* stage, DWORD status) {
  return {{Value("type"), Value("error")}, {Value("stage"), Value(stage)},
          {Value("code"), Value(static_cast<int64_t>(status))},
          {Value("message"), Value("局域网发现失败，请检查专用网络、防火墙与 DNS Client 服务；也可使用手动连接")}};
}
}  // namespace

struct LanDiscovery::State : std::enable_shared_from_this<State> {
  struct Peer {
    Map event;
    Clock::time_point expires;
    Clock::time_point next_resolve;
    unsigned failures = 0;
  };
  std::recursive_mutex mutex;
  bool active = true;
  std::string id;
  std::shared_ptr<UiDispatcher> dispatcher;
  Event emit_event;
  std::shared_ptr<Browse> browse;
  std::shared_ptr<Registration> registration;
  std::map<std::wstring, Peer> peers;
  std::map<std::wstring, std::shared_ptr<Resolve>> resolves;

  void Emit(Map value) {
    std::weak_ptr<State> weak = shared_from_this();
    dispatcher->Post([weak, value = std::move(value)] {
      if (auto state = weak.lock()) {
        std::lock_guard<std::recursive_mutex> lock(state->mutex);
        if (state->active && state->emit_event) state->emit_event(value);
      }
    });
  }
  void Error(const char* stage, DWORD status) { Emit(ErrorEvent(stage, status)); }
  void Lost(Peer& peer) {
    if (peer.event.empty()) return;
    Map event = peer.event;
    event[Value("type")] = Value("lost");
    peer.event.clear();
    Emit(std::move(event));
  }
  void ResolvePeer(const std::wstring& key);
};

// Each asynchronous operation keeps its own context alive until the final OS
// callback. State references are weak, so stop/restart cannot deliver stale
// events or keep the Flutter window alive. Never free a context merely because
// a cancel call returned: the cancellation callback may still be in flight.
struct LanDiscovery::Resolve : std::enable_shared_from_this<Resolve> {
  std::weak_ptr<State> state;
  std::shared_ptr<Resolve> pending_lifetime;
  std::wstring key;
  DNS_SERVICE_RESOLVE_REQUEST request{};
  DNS_SERVICE_CANCEL cancel{};

  static void WINAPI Complete(DWORD status, void* context, DNS_SERVICE_INSTANCE* instance) {
    auto operation = static_cast<Resolve*>(context)->shared_from_this();
    std::unique_ptr<DNS_SERVICE_INSTANCE, decltype(&DnsServiceFreeInstance)> owned(instance, DnsServiceFreeInstance);
    try {
      if (auto owner = operation->state.lock()) {
        std::lock_guard<std::recursive_mutex> lock(owner->mutex);
        auto pending = owner->resolves.find(operation->key);
        if (pending != owner->resolves.end() && pending->second == operation) {
          owner->resolves.erase(pending);
          const auto found = owner->peers.find(operation->key);
          if (owner->active && found != owner->peers.end()) {
            auto& peer = found->second;
            bool accepted = false;
            if (status == ERROR_SUCCESS && instance && instance->ip4Address && instance->wPort > 0) {
              std::string id, name, version;
              if (instance->keys && instance->values && instance->dwPropertyCount <= 64) {
                for (DWORD i = 0; i < instance->dwPropertyCount; ++i) {
                  if (!instance->keys[i] || !instance->values[i]) continue;
                  const std::wstring record_key(instance->keys[i]);
                  if (record_key == L"id") id = Utf8(instance->values[i]);
                  if (record_key == L"name") name = Utf8(instance->values[i]);
                  if (record_key == L"version") version = Utf8(instance->values[i]);
                }
              }
              const auto host = AddressText(*instance->ip4Address);
              if (IsPeerId(id) && id != owner->id && !host.empty() && version == "3") {
                if (name.empty()) name = id;
                Map event{{Value("type"), Value("found")}, {Value("id"), Value(id)},
                    {Value("name"), Value(LimitUtf8(name, 512))}, {Value("host"), Value(host)},
                    {Value("port"), Value(static_cast<int32_t>(instance->wPort))}};
                if (peer.event != event) {
                  peer.event = event;
                  owner->Emit(std::move(event));
                }
                accepted = true;
              }
            }
            if (accepted) {
              peer.failures = 0;
              peer.next_resolve = Clock::now() + std::chrono::seconds(30);
              peer.expires = std::max(peer.expires, peer.next_resolve);
            } else if (status != ERROR_CANCELLED) {
              ++peer.failures;
              peer.next_resolve = Clock::now() + (peer.failures < 3
                  ? std::chrono::seconds(1) : std::chrono::seconds(30));
              if (peer.failures == 3) {
                owner->Lost(peer);
                if (status != ERROR_SUCCESS) owner->Error("resolve", status);
              }
            }
          }
        }
      }
    } catch (...) {
      // A malformed remote record must not unwind across a Win32 callback.
    }
    operation->pending_lifetime.reset();
  }
};

void LanDiscovery::State::ResolvePeer(const std::wstring& key) {
  if (!active || resolves.count(key) || resolves.size() >= 64) return;
  auto operation = std::make_shared<Resolve>();
  operation->state = shared_from_this();
  operation->key = key;
  operation->request.Version = DNS_QUERY_REQUEST_VERSION1;
  operation->request.QueryName = operation->key.data();
  operation->request.pResolveCompletionCallback = Resolve::Complete;
  operation->request.pQueryContext = operation.get();
  operation->pending_lifetime = operation;
  resolves[key] = operation;
  const DWORD status = DnsServiceResolve(&operation->request, &operation->cancel);
  if (status != DNS_REQUEST_PENDING) {
    resolves.erase(key);
    operation->pending_lifetime.reset();
    auto found = peers.find(key);
    if (found != peers.end()) {
      auto& peer = found->second;
      ++peer.failures;
      peer.next_resolve = Clock::now() + (peer.failures < 3
          ? std::chrono::seconds(1) : std::chrono::seconds(30));
      if (peer.failures == 3) Lost(peer);
    }
    Error("resolve", status);
  }
}

struct LanDiscovery::Browse : std::enable_shared_from_this<Browse> {
  std::weak_ptr<State> state;
  std::shared_ptr<Browse> pending_lifetime;
  DNS_SERVICE_BROWSE_REQUEST request{};
  DNS_SERVICE_CANCEL cancel{};

  static void WINAPI Complete(DWORD status, void* context, DNS_RECORD* records) {
    auto operation = static_cast<Browse*>(context)->shared_from_this();
    auto free_records = [](DNS_RECORD* value) { if (value) DnsRecordListFree(value, DnsFreeRecordList); };
    std::unique_ptr<DNS_RECORD, decltype(free_records)> owned(records, free_records);
    try {
      if (auto owner = operation->state.lock()) {
        std::lock_guard<std::recursive_mutex> lock(owner->mutex);
        if (owner->active) {
          if (status != ERROR_SUCCESS && status != ERROR_CANCELLED) owner->Error("discover", status);
          if (status == ERROR_SUCCESS) {
            for (auto* record = records; record; record = record->pNext) {
              if (record->wType != DNS_TYPE_PTR) continue;
              const auto record_key = ServiceKey(record->Data.PTR.pNameHost);
              if (record_key.empty()) continue;
              auto peer = owner->peers.find(record_key);
              if (record->dwTtl == 0) {
                if (peer != owner->peers.end()) {
                  owner->Lost(peer->second);
                  owner->peers.erase(peer);
                }
                auto pending = owner->resolves.find(record_key);
                if (pending != owner->resolves.end()) {
                  auto resolving = pending->second;
                  owner->resolves.erase(pending);
                  DnsServiceResolveCancel(&resolving->cancel);
                }
              } else {
                if (peer == owner->peers.end()) {
                  if (owner->peers.size() >= 256) continue;
                  peer = owner->peers.emplace(record_key, State::Peer{}).first;
                }
                peer->second.expires = Clock::now() + std::chrono::seconds(
                    std::min<DWORD>(record->dwTtl, 4500));
                if (peer->second.next_resolve <= Clock::now()) owner->ResolvePeer(record_key);
              }
            }
          }
        }
      }
    } catch (...) {
      // OS callbacks must not propagate C++ exceptions.
    }
    if (status == ERROR_CANCELLED) operation->pending_lifetime.reset();
  }
};

struct LanDiscovery::Registration : std::enable_shared_from_this<Registration> {
  std::recursive_mutex mutex;
  std::weak_ptr<State> state;
  std::shared_ptr<Registration> pending_lifetime;
  DNS_SERVICE_REGISTER_REQUEST request{};
  DNS_SERVICE_CANCEL cancel{};
  bool stopped = false;
  bool registering = true;
  bool registered = false;
  bool deregistering = false;

  ~Registration() {
    if (request.pServiceInstance) DnsServiceFreeInstance(request.pServiceInstance);
  }

  void Deregister() {
    if (!registered || deregistering) return;
    deregistering = true;
    const DWORD status = DnsServiceDeRegister(&request, nullptr);
    if (status != DNS_REQUEST_PENDING) {
      // Registration is also tied to the process lifetime by Windows.
      pending_lifetime.reset();
    }
  }

  void Stop() {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    stopped = true;
    if (registered) Deregister();
    else if (registering) DnsServiceRegisterCancel(&cancel);
  }

  static void WINAPI Complete(DWORD status, void* context, DNS_SERVICE_INSTANCE* instance) {
    auto operation = static_cast<Registration*>(context)->shared_from_this();
    bool report_error = false;
    {
      std::lock_guard<std::recursive_mutex> lock(operation->mutex);
      if (operation->deregistering) {
        if (instance && instance != operation->request.pServiceInstance) DnsServiceFreeInstance(instance);
        operation->registered = false;
        operation->pending_lifetime.reset();
      } else {
        operation->registering = false;
        if (status == ERROR_SUCCESS) {
          operation->registered = true;
          if (instance && instance != operation->request.pServiceInstance) {
            DnsServiceFreeInstance(operation->request.pServiceInstance);
            operation->request.pServiceInstance = instance;
          }
          if (operation->stopped) operation->Deregister();
        } else {
          if (instance && instance != operation->request.pServiceInstance) DnsServiceFreeInstance(instance);
          report_error = !operation->stopped && status != ERROR_CANCELLED;
          operation->pending_lifetime.reset();
        }
      }
    }
    if (report_error) {
      if (auto owner = operation->state.lock()) {
        std::lock_guard<std::recursive_mutex> lock(owner->mutex);
        if (owner->active) owner->Error("register", status);
      }
    }
  }
};

LanDiscovery::LanDiscovery(std::shared_ptr<UiDispatcher> dispatcher, Event event)
    : dispatcher_(std::move(dispatcher)), event_(std::move(event)) {}
LanDiscovery::~LanDiscovery() { Stop(); }

void LanDiscovery::Start(const std::string& id, const std::string& name, uint16_t port) {
  if (!IsPeerId(id) || port == 0) throw StorageError("INVALID_ARGUMENT", "无效的设备 ID 或服务端口");
  Stop();
  auto state = std::make_shared<State>();
  state->id = id;
  state->dispatcher = dispatcher_;
  state->emit_event = event_;
  state_ = state;
  std::lock_guard<std::recursive_mutex> lock(state->mutex);
  const std::wstring instance_name = L"Tamayura-" + Wide(id.substr(0, 54)) + L"." + kServiceType;
  const auto host = ComputerName() + L".local";
  const auto wide_id = Wide(id);
  const auto wide_name = Wide(LimitUtf8(name, 180));
  const wchar_t* keys[] = {L"id", L"name", L"version"};
  const wchar_t* values[] = {wide_id.c_str(), wide_name.c_str(), L"3"};
  auto registration = std::make_shared<Registration>();
  registration->state = state;
  registration->request.Version = DNS_QUERY_REQUEST_VERSION1;
  registration->request.pServiceInstance = DnsServiceConstructInstance(instance_name.c_str(),
      host.c_str(), nullptr, nullptr, port, 0, 0, 3, keys, values);
  if (!registration->request.pServiceInstance) {
    Stop();
    throw StorageError("DISCOVERY_FAILED", "无法创建 Windows DNS-SD 服务");
  }
  registration->request.pRegisterCompletionCallback = Registration::Complete;
  registration->request.pQueryContext = registration.get();
  registration->request.unicastEnabled = FALSE;
  registration->pending_lifetime = registration;
  state->registration = registration;
  {
    std::lock_guard<std::recursive_mutex> registration_lock(registration->mutex);
    const DWORD status = DnsServiceRegister(&registration->request, &registration->cancel);
    if (status != DNS_REQUEST_PENDING) {
      registration->registering = false;
      registration->pending_lifetime.reset();
      state->Error("register", status);
    }
  }

  auto browse = std::make_shared<Browse>();
  browse->state = state;
  browse->request.Version = DNS_QUERY_REQUEST_VERSION1;
  browse->request.QueryName = kServiceType;
  browse->request.pBrowseCallback = Browse::Complete;
  browse->request.pQueryContext = browse.get();
  browse->pending_lifetime = browse;
  state->browse = browse;
  const DWORD status = DnsServiceBrowse(&browse->request, &browse->cancel);
  if (status != DNS_REQUEST_PENDING) {
    browse->pending_lifetime.reset();
    state->browse.reset();
    state->Error("discover", status);
  }
}

void LanDiscovery::Stop() {
  auto state = std::move(state_);
  if (!state) return;
  std::lock_guard<std::recursive_mutex> lock(state->mutex);
  state->active = false;
  state->emit_event = nullptr;
  if (state->browse) DnsServiceBrowseCancel(&state->browse->cancel);
  if (state->registration) state->registration->Stop();
  auto pending_resolves = std::move(state->resolves);
  for (const auto& pending : pending_resolves) DnsServiceResolveCancel(&pending.second->cancel);
  state->peers.clear();
}

void LanDiscovery::Replay() {
  auto state = state_;
  if (!state) return;
  std::lock_guard<std::recursive_mutex> lock(state->mutex);
  for (const auto& peer : state->peers) if (!peer.second.event.empty()) state->Emit(peer.second.event);
}

void LanDiscovery::Sweep() {
  auto state = state_;
  if (!state) return;
  std::lock_guard<std::recursive_mutex> lock(state->mutex);
  const auto now = Clock::now();
  for (auto peer = state->peers.begin(); peer != state->peers.end();) {
    if (peer->second.expires < now && peer->second.failures >= 3) {
      state->Lost(peer->second);
      peer = state->peers.erase(peer);
    } else {
      if (peer->second.next_resolve <= now) state->ResolvePeer(peer->first);
      ++peer;
    }
  }
}

Map LanDiscovery::LocalInfo() {
  ULONG length = 16 * 1024;
  std::vector<unsigned char> buffer(length);
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3 && status == ERROR_BUFFER_OVERFLOW; ++attempt) {
    buffer.resize(length);
    status = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
        GAA_FLAG_SKIP_DNS_SERVER, nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &length);
  }
  if (status != ERROR_SUCCESS && status != ERROR_NO_DATA) {
    throw StorageError("NETWORK_UNAVAILABLE", "无法读取 Windows 网络接口");
  }
  std::set<std::string> hosts;
  if (status == ERROR_SUCCESS) {
    for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()); adapter; adapter = adapter->Next) {
      if (adapter->OperStatus != IfOperStatusUp || adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
      for (auto* entry = adapter->FirstUnicastAddress; entry; entry = entry->Next) {
        const auto* address = entry->Address.lpSockaddr;
        if (!address || address->sa_family != AF_INET) continue;
        const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(address);
        const auto host = AddressText(ipv4->sin_addr.S_un.S_addr);
        if (!host.empty()) hosts.insert(host);
      }
    }
  }
  flutter::EncodableList addresses;
  for (const auto& host : hosts) addresses.emplace_back(host);
  return {{Value("name"), Value(Utf8(ComputerName()))}, {Value("addresses"), Value(addresses)}};
}
}  // namespace tamayura
