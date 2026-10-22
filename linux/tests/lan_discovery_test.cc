#include "lan_discovery.h"

#include <avahi-client/client.h>
#include <avahi-common/simple-watch.h>
#include <glib.h>

#include <chrono>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "discovery_core.h"
#include "main_dispatcher.h"
#include "storage_core.h"

namespace {
using namespace tamayura;

void Expect(bool value, const std::string& message) {
  if (!value) throw std::runtime_error(message);
}

bool Wait(const std::function<bool()>& ready, int milliseconds) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
  while (!ready()) {
    if (std::chrono::steady_clock::now() > deadline) return false;
    g_main_context_iteration(nullptr, FALSE);
    g_usleep(2000);
  }
  return true;
}

void TestDeviceNames() {
  Expect(LanDiscovery::DeviceName("PRETTY_HOSTNAME=\"Poppin's Laptop\"\n", "host") ==
             "Poppin's Laptop",
         "quoted pretty name");
  Expect(LanDiscovery::DeviceName("CHASSIS=laptop\nPRETTY_HOSTNAME='工作站 2'\n", "host") ==
             "工作站 2",
         "single-quoted Unicode name");
  Expect(LanDiscovery::DeviceName("PRETTY_HOSTNAME=Studio\\ PC", "host") == "Studio PC",
         "escaped unquoted name");
  Expect(LanDiscovery::DeviceName("PRETTY_HOSTNAME=\n", "fallback-host") == "fallback-host",
         "empty pretty name");
  Expect(LanDiscovery::DeviceName("PRETTY_HOSTNAME=\"unterminated", "fallback") == "fallback",
         "malformed pretty name");
  Expect(LanDiscovery::DeviceName("", std::string("bad\xff")) == "Linux", "invalid host name");
  Expect(LanDiscovery::DeviceName("", "") == "Linux", "no names");
  const auto limited = LanDiscovery::DeviceName("PRETTY_HOSTNAME=" + std::string(300, 'a'), "");
  Expect(limited.size() == 128, "name length bounded");
}

void TestLocalNetwork() {
  const auto local = LanDiscovery::Local();
  Expect(!local.name.empty(), "local name");
  for (const auto& address : local.addresses) {
    Expect(IsPrivateIPv4(address), "only LAN IPv4 addresses: " + address);
  }
}

void TestArguments() {
  LanDiscovery discovery(std::make_shared<MainDispatcher>(), nullptr);
  for (const auto& id : {"", "bad id", "peer/1"}) {
    bool rejected = false;
    try {
      discovery.Start(id, "name", 50728);
    } catch (const StorageError& error) {
      rejected = error.code == "INVALID_ARGUMENT";
    }
    Expect(rejected, "invalid discovery identity rejected");
  }
  bool rejected = false;
  try {
    discovery.Start("linux-a", "name", 0);
  } catch (const StorageError& error) {
    rejected = error.code == "INVALID_ARGUMENT";
  }
  Expect(rejected, "port zero rejected");
}

// A client without AVAHI_CLIENT_NO_FAIL fails at once when no daemon runs.
bool DaemonAvailable() {
  AvahiSimplePoll* poll = avahi_simple_poll_new();
  int error = 0;
  AvahiClient* client = avahi_client_new(
      avahi_simple_poll_get(poll), static_cast<AvahiClientFlags>(0),
      [](AvahiClient*, AvahiClientState, void*) {}, nullptr, &error);
  const bool available = client != nullptr;
  if (client) avahi_client_free(client);
  avahi_simple_poll_free(poll);
  return available;
}

// Two instances in one process register and browse through the running
// daemon, as two devices on a network would.
int TestPeers() {
  if (!DaemonAvailable()) {
    std::cout << "avahi-daemon is not running; skipping registration and browsing\n";
    return 77;
  }
  const std::string first_id = "linux-11111111-1111-4111-8111-111111111111";
  const std::string second_id = "linux-22222222-2222-4222-8222-222222222222";
  auto dispatcher = std::make_shared<MainDispatcher>();
  std::vector<DiscoveryEvent> first_events, second_events;
  LanDiscovery first(dispatcher, [&](const DiscoveryEvent& event) {
    first_events.push_back(event);
  });
  auto second = std::make_unique<LanDiscovery>(dispatcher, [&](const DiscoveryEvent& event) {
    second_events.push_back(event);
  });
  first.Start(first_id, "第一台", 50801);
  second->Start(second_id, "Second desk", 50802);
  const auto found = [](const std::vector<DiscoveryEvent>& events, const std::string& id) {
    for (const auto& event : events) {
      if (event.type == "found" && event.id == id) return &event;
    }
    return static_cast<const DiscoveryEvent*>(nullptr);
  };
  Expect(Wait([&] { return found(first_events, second_id) && found(second_events, first_id); },
              15000),
         "each instance finds the other");
  const auto* peer = found(first_events, second_id);
  Expect(peer->name == "Second desk" && peer->port == 50802 && IsPrivateIPv4(peer->host),
         "resolved peer details: " + peer->name + " " + peer->host);
  Expect(found(second_events, first_id)->name == "第一台", "Unicode TXT name");
  Expect(!found(first_events, first_id) && !found(second_events, second_id),
         "an instance never reports itself");
  for (const auto& event : first_events) {
    Expect(event.type != "error", "no discovery errors: " + event.stage);
  }
  // A new listener receives the peers already found.
  const auto before = first_events.size();
  first.Replay();
  Expect(Wait([&] { return first_events.size() > before; }, 2000) &&
             first_events.back().id == second_id,
         "replay sends found peers");
  // Stopping withdraws the service, so the other instance sees it leave.
  second->Stop();
  Expect(Wait(
             [&] {
               for (const auto& event : first_events) {
                 if (event.type == "lost" && event.id == second_id) return true;
               }
               return false;
             },
             15000),
         "a stopped peer is lost");
  second.reset();
  first.Stop();
  const auto after = first_events.size();
  Wait([] { return false; }, 300);
  Expect(first_events.size() == after, "no events after stopping");
  return 0;
}

}  // namespace

int main() {
  try {
    TestDeviceNames();
    TestLocalNetwork();
    TestArguments();
    const int peers = TestPeers();
    std::cout << "Linux discovery tests passed" << (peers == 77 ? " (daemon tests skipped)" : "")
              << '\n';
    return peers;
  } catch (const std::exception& error) {
    std::cerr << "[FAIL] discovery: " << error.what() << '\n';
    return 1;
  }
}
