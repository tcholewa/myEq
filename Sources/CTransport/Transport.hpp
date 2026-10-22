#pragma once
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <new>
#include <time.h>
#include <unistd.h>

namespace meq {
constexpr uint32_t protocol = 2, capacity = 16384, magic = 0x4d455131;
constexpr const char *deviceUID = "com.tc.myEq.output";
constexpr const char *bridgeService = "com.tc.myEq.bridge";
constexpr const char *recoveryService = "com.tc.myEq.recovery";
inline uint64_t now() { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);

// Each side owns one cursor. A full writer drops the incoming block, never the reader's data.
// Control fields are atomic; immutable format fields are validated before the RT pointer is set.
struct alignas(128) Shared {
  uint32_t tag = magic, version = protocol, bytes = sizeof(Shared), channels = 2;
  uint32_t frames = capacity, reserved = 0;
  uint64_t generation = 0;
  double rate = 48000;
  alignas(128) std::atomic<uint64_t> written{0};
  std::atomic<uint64_t> overruns{0}, discontinuities{0}, lastHostTime{0};
  std::atomic<uint32_t> sourceRunning{0};
  alignas(128) std::atomic<uint64_t> read{0};
  std::atomic<uint64_t> rendered{0}, underruns{0}, invalidSamples{0};
  alignas(128) std::atomic<uint64_t> deadline{0};
  std::atomic<uint32_t> active{0};
  std::atomic<uint32_t> volumeSupported{0}, muteSupported{0}, muted{0};
  std::atomic<float> volume{1};
  std::atomic<uint64_t> volumeRequest{0};
  alignas(128) float samples[capacity * 2]{};
};
inline size_t mappingBytes() {
  const size_t page=size_t(getpagesize());return ((sizeof(Shared)+page-1)/page)*page;
}
inline bool valid(const Shared *s, size_t size) {
  return s && size == mappingBytes() && s->tag == magic && s->version == protocol
    && s->bytes == sizeof(Shared) && s->channels == 2 && s->frames == capacity && s->generation
    && std::isfinite(s->rate) && s->rate >= 32000 && s->rate <= 192000;
}
inline uint32_t available(const Shared *s) {
  const auto r = s->read.load(std::memory_order_relaxed);
  const auto w = s->written.load(std::memory_order_acquire);
  return w >= r && w-r <= capacity ? uint32_t(w-r) : 0;
}
inline bool write(Shared *s, const float *input, uint32_t n, uint64_t hostTime) {
  const auto w = s->written.load(std::memory_order_relaxed);
  const auto r = s->read.load(std::memory_order_acquire);
  if (!input || n > capacity || w < r || w-r > capacity || n > capacity-(w-r)) {
    s->overruns.fetch_add(1, std::memory_order_relaxed);
    s->discontinuities.fetch_add(1, std::memory_order_release);
    return false;
  }
  const auto first = std::min(n, capacity-uint32_t(w%capacity));
  memcpy(s->samples+(w%capacity)*2, input, first*2*sizeof(float));
  if (first<n) memcpy(s->samples, input+first*2, (n-first)*2*sizeof(float));
  s->lastHostTime.store(hostTime, std::memory_order_relaxed);
  s->written.store(w+n, std::memory_order_release);
  return true;
}
inline uint32_t read(Shared *s, float *out, uint32_t n) {
  const auto r = s->read.load(std::memory_order_relaxed);
  const auto count = std::min(n, available(s));
  const auto first = std::min(count, capacity-uint32_t(r%capacity));
  memcpy(out, s->samples+(r%capacity)*2, first*2*sizeof(float));
  if (first<count) memcpy(out+first*2, s->samples, (count-first)*2*sizeof(float));
  for(uint32_t i=0;i<count*2;i++) if(!std::isfinite(out[i])) {
    out[i]=0; s->invalidSamples.fetch_add(1,std::memory_order_relaxed);
  }
  if(count<n) memset(out+count*2,0,(n-count)*2*sizeof(float));
  s->read.store(r+count,std::memory_order_release);
  return count;
}
inline void discard(Shared *s) {
  s->read.store(s->written.load(std::memory_order_acquire),std::memory_order_release);
}
// Slow PI correction: no block dropping/duplicating to compensate ordinary device drift.
struct Drift {
  double integral=0, ratio=1;
  double update(double errorFrames, double rate, double elapsed) {
    const double error=errorFrames/rate;
    integral=std::clamp(integral+error*elapsed*0.01,-0.001,0.001);
    const double desired=1+std::clamp(error*0.04+integral,-0.002,0.002);
    ratio += std::clamp(desired-ratio,-elapsed*0.0002,elapsed*0.0002);
    return ratio;
  }
};
}
