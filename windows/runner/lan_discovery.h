#ifndef TAMAYURA_LAN_DISCOVERY_H_
#define TAMAYURA_LAN_DISCOVERY_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace tamayura {
struct DnsServiceApi;

struct DiscoveryEvent {
  std::string type;
  std::string id;
  std::string name;
  std::string host;
  uint16_t port = 0;
  std::string stage;
  uint32_t code = 0;
  std::string message;
  bool operator==(const DiscoveryEvent& other) const;
};

struct LocalNetworkInfo {
  std::string name;
  std::vector<std::string> addresses;
};

class LanDiscovery {
 public:
  using Dispatch = std::function<void(std::function<void()>)>;
  using Event = std::function<void(const DiscoveryEvent&)>;
  LanDiscovery(Dispatch dispatch, Event event,
               std::shared_ptr<const DnsServiceApi> api = nullptr);
  ~LanDiscovery();
  void Start(const std::string& id, const std::string& name, uint16_t port);
  void Stop();
  void Replay();
  void Sweep();
  static LocalNetworkInfo LocalInfo();

 private:
  struct State;
  struct Browse;
  struct Resolve;
  struct Registration;
  Dispatch dispatch_;
  Event event_;
  std::shared_ptr<const DnsServiceApi> api_;
  std::shared_ptr<State> state_;
};
}  // namespace tamayura
#endif
