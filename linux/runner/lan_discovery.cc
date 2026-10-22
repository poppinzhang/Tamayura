#include "lan_discovery.h"

#include <arpa/inet.h>
#include <avahi-client/client.h>
#include <avahi-client/lookup.h>
#include <avahi-client/publish.h>
#include <avahi-common/alternative.h>
#include <avahi-common/error.h>
#include <avahi-common/malloc.h>
#include <avahi-common/strlst.h>
#include <avahi-common/thread-watch.h>
#include <avahi-common/timeval.h>
#include <glib.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <map>
#include <set>

#include "app_text.h"
#include "discovery_core.h"
#include "main_dispatcher.h"
#include "storage_core.h"

namespace tamayura {
namespace {

using Clock = std::chrono::steady_clock;
constexpr char kServiceType[] = "_tamayura._tcp";
constexpr size_t kMaxPeers = 256;
constexpr unsigned kResolveAttempts = 3;

std::string TxtValue(AvahiStringList* txt, const char* key) {
  AvahiStringList* item = avahi_string_list_find(txt, key);
  if (!item) return {};
  char* found_key = nullptr;
  char* value = nullptr;
  size_t size = 0;
  if (avahi_string_list_get_pair(item, &found_key, &value, &size) < 0) return {};
  std::string result = value ? std::string(value, size) : std::string();
  avahi_free(found_key);
  avahi_free(value);
  return result;
}

}  // namespace

struct LanDiscovery::State : std::enable_shared_from_this<State> {
  struct Instance {
    AvahiServiceResolver* resolver = nullptr;
    unsigned failures = 0;
    Clock::time_point next_attempt{};
  };
  using Slot = std::pair<AvahiIfIndex, AvahiProtocol>;
  struct Peer {
    std::string name;
    std::string type;
    std::string domain;
    std::map<Slot, Instance> instances;
    PeerEndpoints endpoints;
  };

  std::shared_ptr<MainDispatcher> dispatcher;
  Listener listener;  // Only used on the main thread.
  std::atomic<bool> active{true};

  // Used by Avahi callbacks with the poll lock held, or before the poll
  // thread starts and after it stops.
  AvahiThreadedPoll* poll = nullptr;
  AvahiClient* client = nullptr;
  AvahiEntryGroup* group = nullptr;
  AvahiServiceBrowser* browser = nullptr;
  AvahiTimeout* sweep = nullptr;
  std::string id;
  std::string name;
  uint16_t port = 0;
  char* service_name = nullptr;
  bool daemon_reported = false;
  std::map<std::string, Peer> peers;
  std::map<AvahiServiceResolver*, std::pair<std::string, Slot>> resolvers;

  void Emit(DiscoveryEvent event) {
    std::weak_ptr<State> weak = shared_from_this();
    dispatcher->Post([weak, event = std::move(event)] {
      const auto state = weak.lock();
      if (state && state->active && state->listener) state->listener(event);
    });
  }

  void Error(const char* stage, int code) {
    DiscoveryEvent event;
    event.type = "error";
    event.stage = stage;
    event.code = code;
    event.message = app_text::Text(TextId::kDiscoveryFailed);
    Emit(std::move(event));
  }

  void Lost(Peer& peer) {
    if (auto event = peer.endpoints.Clear()) Emit(std::move(*event));
  }

  void FreeResolvers() {
    for (const auto& item : resolvers) avahi_service_resolver_free(item.first);
    resolvers.clear();
    for (auto& peer : peers) {
      for (auto& instance : peer.second.instances) instance.second.resolver = nullptr;
    }
  }

  // Frees every object of the client; the client itself stays.
  void Reset() {
    FreeResolvers();
    for (auto& peer : peers) Lost(peer.second);
    peers.clear();
    if (browser) avahi_service_browser_free(browser);
    browser = nullptr;
    if (group) avahi_entry_group_free(group);
    group = nullptr;
  }

  void Register(AvahiClient* owner) {
    if (!group) {
      group = avahi_entry_group_new(owner, GroupCallback, this);
      if (!group) {
        Error("register", avahi_client_errno(owner));
        return;
      }
    }
    if (!avahi_entry_group_is_empty(group)) return;
    AvahiStringList* txt = nullptr;
    txt = avahi_string_list_add_pair(txt, "id", id.c_str());
    txt = avahi_string_list_add_pair(txt, "name", LimitUtf8(name, 180).c_str());
    txt = avahi_string_list_add_pair(txt, "version", kProtocolVersion);
    for (unsigned attempt = 0; attempt < 12; ++attempt) {
      const int result = avahi_entry_group_add_service_strlst(
          group, AVAHI_IF_UNSPEC, AVAHI_PROTO_UNSPEC, static_cast<AvahiPublishFlags>(0),
          service_name, kServiceType, nullptr, nullptr, port, txt);
      if (result == AVAHI_ERR_COLLISION) {
        char* next = avahi_alternative_service_name(service_name);
        avahi_free(service_name);
        service_name = next;
        continue;
      }
      if (result < 0) {
        Error("register", result);
      } else if (const int commit = avahi_entry_group_commit(group); commit < 0) {
        Error("register", commit);
      }
      break;
    }
    avahi_string_list_free(txt);
  }

  void Browse(AvahiClient* owner) {
    if (browser) return;
    // Peers connect over IPv4 only; browse and resolve IPv4 records.
    browser = avahi_service_browser_new(owner, AVAHI_IF_UNSPEC, AVAHI_PROTO_INET,
                                        kServiceType, nullptr,
                                        static_cast<AvahiLookupFlags>(0),
                                        BrowseCallback, this);
    if (!browser) Error("discover", avahi_client_errno(owner));
  }

  void Resolve(const std::string& key, const Slot& slot) {
    auto& peer = peers.at(key);
    auto& instance = peer.instances.at(slot);
    if (instance.resolver || !client) return;
    instance.resolver = avahi_service_resolver_new(
        client, slot.first, slot.second, peer.name.c_str(), peer.type.c_str(),
        peer.domain.empty() ? nullptr : peer.domain.c_str(), AVAHI_PROTO_INET,
        static_cast<AvahiLookupFlags>(0), ResolveCallback, this);
    if (instance.resolver) {
      resolvers[instance.resolver] = {key, slot};
    } else {
      Failed(peer, slot, avahi_client_errno(client));
    }
  }

  void Failed(Peer& peer, const Slot& slot, int code) {
    auto& instance = peer.instances.at(slot);
    if (auto event = peer.endpoints.Remove(slot)) Emit(std::move(*event));
    ++instance.failures;
    instance.next_attempt = Clock::now() + (instance.failures < kResolveAttempts
                                                 ? std::chrono::seconds(1)
                                                 : std::chrono::seconds(30));
    if (instance.failures == kResolveAttempts && !peer.endpoints.found()) {
      Error("resolve", code);
    }
  }

  // Runs every second on the Avahi thread and retries failed resolutions.
  void Sweep() {
    const auto now = Clock::now();
    std::vector<std::pair<std::string, Slot>> due;
    for (const auto& peer : peers) {
      for (const auto& instance : peer.second.instances) {
        if (!instance.second.resolver && instance.second.next_attempt <= now) {
          due.emplace_back(peer.first, instance.first);
        }
      }
    }
    for (const auto& [key, slot] : due) Resolve(key, slot);
  }

  static void ClientCallback(AvahiClient* owner, AvahiClientState value, void* data) {
    auto* state = static_cast<State*>(data);
    // Also called from inside avahi_client_new(), before it returns.
    state->client = owner;
    switch (value) {
      case AVAHI_CLIENT_S_RUNNING:
        state->daemon_reported = false;
        state->Register(owner);
        state->Browse(owner);
        break;
      case AVAHI_CLIENT_S_COLLISION:
      case AVAHI_CLIENT_S_REGISTERING:
        // The host name changes; register again once it is running.
        if (state->group) avahi_entry_group_reset(state->group);
        break;
      case AVAHI_CLIENT_CONNECTING:
        if (!state->daemon_reported) {
          state->daemon_reported = true;
          state->Error("discover", AVAHI_ERR_NO_DAEMON);
        }
        break;
      case AVAHI_CLIENT_FAILURE: {
        const int error = avahi_client_errno(owner);
        if (error != AVAHI_ERR_DISCONNECTED) {
          state->Error("discover", error);
          break;
        }
        // The daemon restarted: as avahi-browse does, replace the client.
        state->Reset();
        avahi_client_free(owner);
        state->client = nullptr;
        int created = 0;
        avahi_client_new(avahi_threaded_poll_get(state->poll), AVAHI_CLIENT_NO_FAIL,
                         ClientCallback, state, &created);
        if (!state->client) state->Error("discover", created);
        break;
      }
    }
  }

  static void GroupCallback(AvahiEntryGroup* group, AvahiEntryGroupState value, void* data) {
    auto* state = static_cast<State*>(data);
    if (value == AVAHI_ENTRY_GROUP_COLLISION) {
      char* next = avahi_alternative_service_name(state->service_name);
      avahi_free(state->service_name);
      state->service_name = next;
      avahi_entry_group_reset(group);
      state->Register(avahi_entry_group_get_client(group));
    } else if (value == AVAHI_ENTRY_GROUP_FAILURE) {
      state->Error("register", avahi_client_errno(avahi_entry_group_get_client(group)));
    }
  }

  static void BrowseCallback(AvahiServiceBrowser* browser, AvahiIfIndex interface,
                             AvahiProtocol protocol, AvahiBrowserEvent event,
                             const char* name, const char* type, const char* domain,
                             AvahiLookupResultFlags, void* data) {
    auto* state = static_cast<State*>(data);
    if (event == AVAHI_BROWSER_FAILURE) {
      state->Error("discover", avahi_client_errno(avahi_service_browser_get_client(browser)));
      return;
    }
    if (event != AVAHI_BROWSER_NEW && event != AVAHI_BROWSER_REMOVE) return;
    if (!name || !type) return;
    const std::string key = std::string(name) + "\n" + (domain ? domain : "");
    const Slot slot{interface, protocol};
    auto peer = state->peers.find(key);
    if (event == AVAHI_BROWSER_NEW) {
      if (peer == state->peers.end()) {
        if (state->peers.size() >= kMaxPeers) return;
        peer = state->peers.emplace(key, Peer{name, type, domain ? domain : "", {}, {}}).first;
      }
      peer->second.instances.emplace(slot, Instance{});
      state->Resolve(key, slot);
      return;
    }
    if (peer == state->peers.end()) return;
    const auto instance = peer->second.instances.find(slot);
    if (instance != peer->second.instances.end()) {
      if (instance->second.resolver) {
        state->resolvers.erase(instance->second.resolver);
        avahi_service_resolver_free(instance->second.resolver);
      }
      peer->second.instances.erase(instance);
    }
    if (auto event = peer->second.endpoints.Remove(slot)) state->Emit(std::move(*event));
    if (peer->second.instances.empty()) {
      state->peers.erase(peer);
    }
  }

  static void ResolveCallback(AvahiServiceResolver* resolver, AvahiIfIndex, AvahiProtocol,
                              AvahiResolverEvent event, const char* name, const char*,
                              const char*, const char*, const AvahiAddress* address,
                              uint16_t service_port, AvahiStringList* txt,
                              AvahiLookupResultFlags, void* data) {
    auto* state = static_cast<State*>(data);
    const auto where = state->resolvers.find(resolver);
    if (where == state->resolvers.end()) return;
    // Ordinary local copies can be captured by the invalidation lambda in
    // C++17; capturing a structured binding would require C++20.
    const auto key = where->second.first;
    const auto slot = where->second.second;
    auto peer = state->peers.find(key);
    if (peer == state->peers.end()) return;
    auto instance = peer->second.instances.find(slot);
    if (instance == peer->second.instances.end()) return;
    if (event != AVAHI_RESOLVER_FOUND) {
      state->resolvers.erase(where);
      avahi_service_resolver_free(resolver);
      instance->second.resolver = nullptr;
      state->Failed(peer->second, slot, avahi_client_errno(state->client));
      return;
    }
    // Invalid updates withdraw this interface's previous endpoint without
    // treating another app's service as a discovery error.
    instance->second.failures = 0;
    const auto invalidate = [&] {
      if (auto event = peer->second.endpoints.Remove(slot)) state->Emit(std::move(*event));
    };
    if (!address || address->proto != AVAHI_PROTO_INET || service_port == 0) {
      invalidate();
      return;
    }
    char host[AVAHI_ADDRESS_STR_MAX] = {};
    avahi_address_snprint(host, sizeof(host), address);
    const auto id = TxtValue(txt, "id");
    if (!IsPeerId(id) || id == state->id || !IsPrivateIPv4(host) ||
        !IsCompatibleVersion(TxtValue(txt, "version"))) {
      invalidate();
      return;
    }
    auto label = TxtValue(txt, "name");
    if (label.empty() || !IsUtf8(label)) label = name && IsUtf8(name) ? name : id;
    DiscoveryEvent found;
    found.type = "found";
    found.id = id;
    found.name = LimitUtf8(label, 512);
    found.host = host;
    found.port = service_port;
    if (auto event = peer->second.endpoints.Resolve(slot, std::move(found))) {
      state->Emit(std::move(*event));
    }
  }

  static void SweepCallback(AvahiTimeout* timeout, void* data) {
    auto* state = static_cast<State*>(data);
    state->Sweep();
    struct timeval next {};
    avahi_elapse_time(&next, 1000, 0);
    avahi_threaded_poll_get(state->poll)->timeout_update(timeout, &next);
  }
};

LanDiscovery::LanDiscovery(std::shared_ptr<MainDispatcher> dispatcher, Listener listener)
    : dispatcher_(std::move(dispatcher)), listener_(std::move(listener)) {}

LanDiscovery::~LanDiscovery() { Stop(); }

void LanDiscovery::Start(const std::string& id, const std::string& name, uint16_t port) {
  if (!IsPeerId(id) || port == 0) {
    throw StorageError("INVALID_ARGUMENT", TextId::kInvalidDiscoveryArguments);
  }
  Stop();
  auto state = std::make_shared<State>();
  state->dispatcher = dispatcher_;
  state->listener = listener_;
  state->id = id;
  state->name = name;
  state->port = port;
  state->service_name = avahi_strdup(("Tamayura-" + id.substr(0, 54)).c_str());
  state->poll = avahi_threaded_poll_new();
  if (!state->poll || !state->service_name) {
    if (state->poll) avahi_threaded_poll_free(state->poll);
    avahi_free(state->service_name);
    throw StorageError("DISCOVERY_FAILED", TextId::kDiscoveryFailed);
  }
  int error = 0;
  avahi_client_new(avahi_threaded_poll_get(state->poll), AVAHI_CLIENT_NO_FAIL,
                   State::ClientCallback, state.get(), &error);
  // Without a system bus the client cannot even wait for the daemon.
  if (!state->client) state->Error("discover", error);
  const AvahiPoll* api = avahi_threaded_poll_get(state->poll);
  struct timeval first {};
  avahi_elapse_time(&first, 1000, 0);
  state->sweep = api->timeout_new(api, &first, State::SweepCallback, state.get());
  if (avahi_threaded_poll_start(state->poll) < 0) {
    if (state->sweep) api->timeout_free(state->sweep);
    state->Reset();
    if (state->client) avahi_client_free(state->client);
    avahi_threaded_poll_free(state->poll);
    avahi_free(state->service_name);
    throw StorageError("DISCOVERY_FAILED", TextId::kDiscoveryFailed);
  }
  state_ = std::move(state);
}

void LanDiscovery::Stop() {
  auto state = std::move(state_);
  if (!state) return;
  state->active = false;
  // Joins the Avahi thread; no callback runs after this returns.
  avahi_threaded_poll_stop(state->poll);
  const AvahiPoll* api = avahi_threaded_poll_get(state->poll);
  if (state->sweep) api->timeout_free(state->sweep);
  state->sweep = nullptr;
  state->FreeResolvers();
  state->peers.clear();
  if (state->browser) avahi_service_browser_free(state->browser);
  state->browser = nullptr;
  // Withdraws the service, so peers see it leave at once.
  if (state->group) avahi_entry_group_free(state->group);
  state->group = nullptr;
  if (state->client) avahi_client_free(state->client);
  state->client = nullptr;
  avahi_threaded_poll_free(state->poll);
  state->poll = nullptr;
  avahi_free(state->service_name);
  state->service_name = nullptr;
}

void LanDiscovery::Replay() {
  const auto state = state_;
  if (!state) return;
  std::vector<DiscoveryEvent> events;
  avahi_threaded_poll_lock(state->poll);
  for (const auto& peer : state->peers) {
    if (peer.second.endpoints.found()) events.push_back(*peer.second.endpoints.found());
  }
  avahi_threaded_poll_unlock(state->poll);
  for (auto& event : events) state->Emit(std::move(event));
}

std::string LanDiscovery::DeviceName(const std::string& machine_info,
                                     const std::string& host_name) {
  // systemd-hostnamed stores the name chosen in desktop settings here.
  size_t start = 0;
  while (start < machine_info.size()) {
    auto end = machine_info.find('\n', start);
    if (end == std::string::npos) end = machine_info.size();
    std::string line = machine_info.substr(start, end - start);
    start = end + 1;
    constexpr char kKey[] = "PRETTY_HOSTNAME=";
    if (line.rfind(kKey, 0) != 0) continue;
    gchar* value = g_shell_unquote(line.c_str() + sizeof(kKey) - 1, nullptr);
    std::string pretty = value ? value : "";
    g_free(value);
    if (!pretty.empty() && IsUtf8(pretty)) return LimitUtf8(pretty, 128);
  }
  if (!host_name.empty() && IsUtf8(host_name)) return LimitUtf8(host_name, 128);
  return "Linux";
}

LocalNetwork LanDiscovery::Local() {
  std::string machine_info;
  gchar* contents = nullptr;
  if (g_file_get_contents("/etc/machine-info", &contents, nullptr, nullptr)) {
    machine_info = contents;
    g_free(contents);
  }
  char host[256] = {};
  if (gethostname(host, sizeof(host) - 1) != 0) host[0] = '\0';
  LocalNetwork result;
  result.name = DeviceName(machine_info, host);
  ifaddrs* interfaces = nullptr;
  if (getifaddrs(&interfaces) != 0) {
    throw StorageError("NETWORK_UNAVAILABLE", TextId::kNetworkInterfacesUnavailable);
  }
  std::set<std::string> hosts;
  for (const ifaddrs* item = interfaces; item; item = item->ifa_next) {
    // Bridges without a connected container or VM have no carrier.
    if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET ||
        !(item->ifa_flags & IFF_UP) || !(item->ifa_flags & IFF_RUNNING) ||
        (item->ifa_flags & IFF_LOOPBACK)) {
      continue;
    }
    char text[INET_ADDRSTRLEN] = {};
    const auto* address = reinterpret_cast<const sockaddr_in*>(item->ifa_addr);
    if (inet_ntop(AF_INET, &address->sin_addr, text, sizeof(text)) && IsPrivateIPv4(text)) {
      hosts.insert(text);
    }
  }
  freeifaddrs(interfaces);
  result.addresses.assign(hosts.begin(), hosts.end());
  return result;
}

}  // namespace tamayura
