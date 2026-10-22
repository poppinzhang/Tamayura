#include "discovery_core.h"

#include <algorithm>
#include <array>

namespace tamayura {
bool IsPeerId(const std::string& value) {
  return !value.empty() && value.size() <= 128 &&
         std::all_of(value.begin(), value.end(), [](unsigned char c) {
           return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '-';
         });
}

bool IsCompatibleVersion(const std::string& value) {
  return value == kProtocolVersion;
}

bool IsLinuxId(const std::string& value) {
  constexpr char kPrefix[] = "linux-";
  constexpr size_t kPrefixLength = sizeof(kPrefix) - 1;
  if (value.size() != kPrefixLength + 36 ||
      value.compare(0, kPrefixLength, kPrefix) != 0) {
    return false;
  }
  for (size_t i = kPrefixLength; i < value.size(); ++i) {
    const size_t offset = i - kPrefixLength;
    if (offset == 8 || offset == 13 || offset == 18 || offset == 23) {
      if (value[i] != '-') return false;
    } else if (!((value[i] >= '0' && value[i] <= '9') ||
                 (value[i] >= 'a' && value[i] <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool IsPrivateIPv4(const std::string& value) {
  std::array<unsigned, 4> octets{};
  size_t cursor = 0;
  for (size_t i = 0; i < octets.size(); ++i) {
    const size_t start = cursor;
    while (cursor < value.size() && value[cursor] >= '0' &&
           value[cursor] <= '9') {
      octets[i] = octets[i] * 10 + static_cast<unsigned>(value[cursor++] - '0');
      if (octets[i] > 255 || cursor - start > 3) return false;
    }
    if (cursor == start || (cursor - start > 1 && value[start] == '0')) {
      return false;
    }
    if (i < 3 && (cursor == value.size() || value[cursor++] != '.')) {
      return false;
    }
  }
  if (cursor != value.size()) return false;
  return octets[0] == 10 ||
         (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
         (octets[0] == 192 && octets[1] == 168) ||
         (octets[0] == 169 && octets[1] == 254);
}

std::string LimitUtf8(const std::string& value, size_t maximum_bytes) {
  if (value.size() <= maximum_bytes) return value;
  size_t end = maximum_bytes;
  while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xc0) == 0x80) {
    --end;
  }
  return value.substr(0, end);
}
}  // namespace tamayura
