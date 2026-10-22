#ifndef TAMAYURA_DISCOVERY_CORE_H_
#define TAMAYURA_DISCOVERY_CORE_H_

#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>

namespace tamayura {
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

// A service can be resolved on several interfaces. Keep each result so an
// interface disappearing or failing can switch to a surviving address. The
// current interface stays selected while valid, avoiding announcement churn.
class PeerEndpoints {
 public:
  using Slot = std::pair<int, int>;  // Interface index and address protocol.
  std::optional<DiscoveryEvent> Resolve(Slot slot, DiscoveryEvent event);
  // Used for removal, resolution failure and invalidated TXT/address records.
  std::optional<DiscoveryEvent> Remove(Slot slot);
  std::optional<DiscoveryEvent> Clear();
  const std::optional<DiscoveryEvent>& found() const { return found_; }

 private:
  std::optional<DiscoveryEvent> Select();
  std::map<Slot, DiscoveryEvent> instances_;
  std::optional<Slot> selected_;
  std::optional<DiscoveryEvent> found_;
};

bool IsPeerId(const std::string& value);
// "linux-" followed by a lowercase UUID, as LinuxBridge.isValidDeviceId.
bool IsLinuxId(const std::string& value);
bool IsPrivateIPv4(const std::string& value);
std::string LimitUtf8(const std::string& value, size_t maximum_bytes);
// The DNS-SD TXT "version" matches mediaProtocolVersion in media_rpc.dart.
inline constexpr char kProtocolVersion[] = "4";
bool IsCompatibleVersion(const std::string& value);
}  // namespace tamayura
#endif
