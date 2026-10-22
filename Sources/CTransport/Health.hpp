#pragma once
#include <algorithm>
#include <cstdint>
namespace meq {
constexpr uint64_t peerHealthNS = 1500000000, recoveryHealthNS = 2000000000;
// Deadlines are based on observed progress, never on retries or timeout completions.
inline uint64_t healthDeadline(uint64_t app, uint64_t recovery, uint64_t render) {
  return std::min({app + peerHealthNS, recovery + recoveryHealthNS, render + peerHealthNS});
}
}
