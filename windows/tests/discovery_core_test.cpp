#include "discovery_core.h"

#include <iostream>
#include <stdexcept>

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

int main() {
  using namespace tamayura;
  try {
    Require(IsPeerId("android-peer_123"), "valid peer ID");
    for (const auto& id : {"", "peer.local", "peer/name", "设备", "peer\n"}) {
      Require(!IsPeerId(id), "invalid peer ID rejected");
    }
    Require(!IsPeerId(std::string(129, 'a')), "ID length bounded");
    Require(IsWindowsId("windows-12345678-1234-1234-1234-123456789abc"), "Windows ID");
    Require(!IsWindowsId("windows-12345678-1234-1234-1234-123456789abC"), "canonical UUID");
    Require(!IsWindowsId("macos-12345678-1234-1234-1234-123456789abc"), "Windows prefix");
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
    std::cout << "Discovery validation tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
