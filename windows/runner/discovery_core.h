#ifndef TAMAYURA_DISCOVERY_CORE_H_
#define TAMAYURA_DISCOVERY_CORE_H_

#include <cstddef>
#include <string>

namespace tamayura {
bool IsPeerId(const std::string& value);
bool IsWindowsId(const std::string& value);
bool IsPrivateIPv4(const std::string& value);
std::string LimitUtf8(const std::string& value, size_t maximum_bytes);
}  // namespace tamayura
#endif
