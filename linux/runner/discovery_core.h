#ifndef TAMAYURA_DISCOVERY_CORE_H_
#define TAMAYURA_DISCOVERY_CORE_H_

#include <cstddef>
#include <string>

namespace tamayura {
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
