#ifndef TAMAYURA_LAN_DISCOVERY_H_
#define TAMAYURA_LAN_DISCOVERY_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace tamayura {
class MainDispatcher;

struct DiscoveryEvent {
  std::string type;  // "found", "lost" or "error".
  std::string id;
  std::string name;
  std::string host;
  int port = 0;
  std::string stage;  // Errors: "register", "discover" or "resolve".
  int64_t code = 0;
  std::string message;
  bool operator==(const DiscoveryEvent& other) const {
    return type == other.type && id == other.id && name == other.name &&
           host == other.host && port == other.port;
  }
};

struct LocalNetwork {
  std::string name;
  std::vector<std::string> addresses;
};

// DNS-SD on the local link through the Avahi daemon, which desktop Linux
// distributions run for printing and file sharing. Registration and browsing
// use _tamayura._tcp with the same TXT keys as the other platforms. Without
// a running daemon one error is reported and manual connections still work;
// discovery starts once the daemon appears.
class LanDiscovery {
 public:
  // Called on the GTK main thread.
  using Listener = std::function<void(const DiscoveryEvent&)>;
  LanDiscovery(std::shared_ptr<MainDispatcher> dispatcher, Listener listener);
  ~LanDiscovery();
  LanDiscovery(const LanDiscovery&) = delete;
  LanDiscovery& operator=(const LanDiscovery&) = delete;

  void Start(const std::string& id, const std::string& name, uint16_t port);
  void Stop();
  // Sends the currently found peers again, for a new event listener.
  void Replay();

  static LocalNetwork Local();
  // The pretty host name from /etc/machine-info, else the host name.
  static std::string DeviceName(const std::string& machine_info,
                                const std::string& host_name);

 private:
  struct State;
  std::shared_ptr<MainDispatcher> dispatcher_;
  Listener listener_;
  std::shared_ptr<State> state_;
};

}  // namespace tamayura

#endif  // TAMAYURA_LAN_DISCOVERY_H_
