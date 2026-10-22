#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
namespace meq {
// Zero means no safe supported increase. A larger existing value is never reduced.
inline uint32_t bufferRequest(uint32_t current, double minimum, double maximum, uint32_t desired=512) {
  if(!current||current>4096||!std::isfinite(minimum)||!std::isfinite(maximum)||minimum<1||maximum<minimum)return 0;
  const double candidate=std::max(std::ceil(minimum),std::min(double(desired),std::floor(maximum)));
  return candidate>current&&candidate<=4096?uint32_t(candidate):0;
}
}
