#ifndef TAMAYURA_LAN_DISCOVERY_H_
#define TAMAYURA_LAN_DISCOVERY_H_

#include <flutter/encodable_value.h>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace tamayura {
class UiDispatcher;

class LanDiscovery {
 public:
  using Event = std::function<void(const flutter::EncodableMap&)>;
  LanDiscovery(std::shared_ptr<UiDispatcher> dispatcher, Event event);
  ~LanDiscovery();
  void Start(const std::string& id, const std::string& name, uint16_t port);
  void Stop();
  void Replay();
  void Sweep();
  static flutter::EncodableMap LocalInfo();

 private:
  struct State;
  struct Browse;
  struct Resolve;
  struct Registration;
  std::shared_ptr<UiDispatcher> dispatcher_;
  Event event_;
  std::shared_ptr<State> state_;
};
}  // namespace tamayura
#endif
