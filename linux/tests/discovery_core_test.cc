#include "discovery_core.h"

#include <iostream>
#include <stdexcept>
#include <string>

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

namespace {
using tamayura::DiscoveryEvent;
using tamayura::PeerEndpoints;

DiscoveryEvent Found(const char* host) {
  DiscoveryEvent result;
  result.type = "found";
  result.id = "linux-peer";
  result.name = "Peer";
  result.host = host;
  result.port = 50728;
  return result;
}

void RequireEvent(const std::optional<DiscoveryEvent>& event, const char* type,
                  const char* host, const char* message) {
  Require(event && event->type == type && event->host == host &&
              event->id == "linux-peer",
          message);
}

void TestInterfaceRemoval() {
  PeerEndpoints endpoints;
  const PeerEndpoints::Slot wifi{1, 0}, ethernet{2, 0};
  RequireEvent(endpoints.Resolve(wifi, Found("192.168.1.2")), "found", "192.168.1.2",
               "first interface announces the device");
  Require(!endpoints.Resolve(ethernet, Found("192.168.2.2")),
          "a second interface keeps the valid current address");
  Require(!endpoints.Resolve(wifi, Found("192.168.1.2")),
          "duplicate resolutions do not reannounce");
  RequireEvent(endpoints.Remove(wifi), "found", "192.168.2.2",
               "removing the active interface announces a surviving address");
  Require(endpoints.found() && endpoints.found()->host == "192.168.2.2",
          "replay uses the surviving address");
  Require(!endpoints.Remove(wifi), "repeated removal does not produce another edge");
  RequireEvent(endpoints.Remove(ethernet), "lost", "192.168.2.2",
               "removing the last interface loses the device once");
  Require(!endpoints.found() && !endpoints.Remove(ethernet),
          "a fully removed device has no stale replay result");
  RequireEvent(endpoints.Resolve(wifi, Found("192.168.1.3")), "found", "192.168.1.3",
               "a returned interface announces a new online edge");
}

void TestInterfaceFailuresAndUpdates() {
  PeerEndpoints endpoints;
  const PeerEndpoints::Slot wifi{1, 0}, ethernet{2, 0};
  endpoints.Resolve(wifi, Found("192.168.1.2"));
  endpoints.Resolve(ethernet, Found("192.168.2.2"));
  // Removal, resolution failure and invalid TXT/address updates all withdraw
  // only the affected interface through the same operation.
  for (int attempt = 0; attempt < 3; ++attempt) {
    Require(!endpoints.Remove(ethernet),
            "repeated backup-interface failures do not lose the healthy device");
  }
  Require(endpoints.found() && endpoints.found()->host == "192.168.1.2",
          "the current address survives failure of a different interface");
  Require(!endpoints.Resolve(ethernet, Found("192.168.2.3")),
          "a recovered backup interface does not replace the healthy current one");
  auto changed = Found("192.168.1.3");
  changed.name = "Renamed peer";
  changed.port = 50729;
  const auto updated = endpoints.Resolve(wifi, changed);
  RequireEvent(updated, "found", "192.168.1.3", "the current interface's update is announced");
  Require(updated->name == changed.name && updated->port == changed.port,
          "updated name and port are retained");
  Require(!endpoints.Resolve(wifi, changed), "a repeated endpoint update is suppressed");
  RequireEvent(endpoints.Remove(wifi), "found", "192.168.2.3",
               "failure or invalidation of the current endpoint uses the recovered backup");
  RequireEvent(endpoints.Clear(), "lost", "192.168.2.3",
               "reset withdraws the currently advertised address");
  Require(!endpoints.found() && !endpoints.Clear(), "reset emits lost only once");
}

void TestSameEndpointOnTwoInterfaces() {
  PeerEndpoints endpoints;
  const PeerEndpoints::Slot wifi{1, 0}, ethernet{2, 0};
  endpoints.Resolve(wifi, Found("192.168.1.2"));
  Require(!endpoints.Resolve(ethernet, Found("192.168.1.2")),
          "identical endpoints on two interfaces are announced once");
  Require(!endpoints.Remove(wifi), "switching to an identical surviving endpoint is silent");
  RequireEvent(endpoints.Remove(ethernet), "lost", "192.168.1.2",
               "the identical endpoint is lost only after both interfaces disappear");
}
}  // namespace

int main() {
  using namespace tamayura;
  try {
    Require(IsPeerId("android-peer_123"), "valid peer ID");
    Require(IsCompatibleVersion("4"), "current protocol version");
    for (const auto& version : {"", "3", "5", "4 ", "04"}) {
      Require(!IsCompatibleVersion(version), "other protocol versions rejected");
    }
    for (const auto& id : {"", "peer.local", "peer/name", "设备", "peer\n"}) {
      Require(!IsPeerId(id), "invalid peer ID rejected");
    }
    Require(!IsPeerId(std::string(129, 'a')), "ID length bounded");
    Require(IsLinuxId("linux-12345678-1234-1234-1234-123456789abc"), "Linux ID");
    Require(!IsLinuxId("linux-12345678-1234-1234-1234-123456789abC"), "canonical UUID");
    Require(!IsLinuxId("linux-12345678-1234-1234-1234-123456789ab"), "UUID length");
    Require(!IsLinuxId("linux-123456781-234-1234-1234-123456789abc"), "UUID groups");
    Require(!IsLinuxId("windows-12345678-1234-1234-1234-123456789abc"), "Linux prefix");
    Require(IsPeerId("linux-12345678-1234-1234-1234-123456789abc"), "Linux ID is a peer ID");
    for (const auto& host : {"10.0.0.1", "172.16.0.1", "172.31.255.254",
                             "192.168.0.1", "169.254.1.2"}) {
      Require(IsPrivateIPv4(host), "LAN IPv4 allowed");
    }
    for (const auto& host : {"8.8.8.8", "127.0.0.1", "0.0.0.0", "172.15.0.1",
                             "172.32.0.1", "192.168.1.256", "192.168.1", "10.0.0.01",
                             "10.0.0.1:80", "10.0.0.1.", "::1", ""}) {
      Require(!IsPrivateIPv4(host), "non-LAN/malformed IPv4 rejected");
    }
    Require(LimitUtf8("ab你好", 4) == "ab", "UTF-8 partial codepoint excluded");
    Require(LimitUtf8("ab你好", 5) == "ab你", "UTF-8 codepoint boundary");
    Require(LimitUtf8("你好", 0).empty(), "empty UTF-8 budget");
    TestInterfaceRemoval();
    TestInterfaceFailuresAndUpdates();
    TestSameEndpointOnTwoInterfaces();
    std::cout << "Discovery validation tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
