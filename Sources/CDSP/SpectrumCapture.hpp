#pragma once
#include "CDSP.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <time.h>

namespace myeq {
constexpr uint32_t spectrumMaximumFrames=32768;
// Audio owns history. A slot is immutable from Ready until the single consumer releases it.
// There is no allocation, waiting, FFT, reference-count operation or unbounded retry in capture().
struct SpectrumCapture {
  enum : uint32_t { Free, Writing, Ready, Reading };
  struct Slot {
    std::atomic<uint32_t> state{Free};
    MEQSpectrumSnapshot info{};
    std::array<float,spectrumMaximumFrames*2> samples{};
  };
  const double rate;
  const uint32_t frames;
  std::atomic<uint64_t> epoch{0},requested{0};
  std::atomic<uint64_t> blocks{0},published{0},dropped{0};
  std::array<Slot,3> slots;
  std::array<float,spectrumMaximumFrames*2> history{};
  uint64_t producerEpoch=0,sequence=0;
  uint32_t cursor=0,filled=0;
  explicit SpectrumCapture(double sampleRate):rate(sampleRate),frames(uint32_t(1u<<std::clamp(int(std::round(std::log2(sampleRate*.171))),12,15))){}
  void enable(bool enabled){
    const auto old=epoch.load(std::memory_order_relaxed);
    if(bool(old&1)!=enabled){requested.store(0,std::memory_order_relaxed);epoch.store(old+1,std::memory_order_release);}
  }
  void request(){const auto e=epoch.load(std::memory_order_acquire);if(e&1)requested.store(e,std::memory_order_release);}
  bool beginBlock(){
    const auto e=epoch.load(std::memory_order_acquire);
    if(!(e&1))return false;
    if(e!=producerEpoch){producerEpoch=e;cursor=filled=0;}
    blocks.fetch_add(1,std::memory_order_relaxed);
    return true;
  }
  void append(float left,float right){
    history[cursor*2]=left;history[cursor*2+1]=right;
    if(++cursor==frames)cursor=0;filled=std::min(frames,filled+1);
  }
  // Block helper for native capture-state tests.
  void capture(const float *input,uint32_t count){
    if(!count||!beginBlock())return;
    for(uint32_t i=0;i<count;i++)append(input[i*2],input[i*2+1]);
    endBlock();
  }
  void endBlock(){
    const auto e=producerEpoch;
    if(filled<frames||requested.exchange(0,std::memory_order_acq_rel)!=e)return;
    for(auto &slot:slots){
      uint32_t expected=Free;
      if(!slot.state.compare_exchange_strong(expected,Writing,std::memory_order_acquire))continue;
      const auto first=frames-cursor;
      std::memcpy(slot.samples.data(),history.data()+cursor*2,first*2*sizeof(float));
      if(cursor)std::memcpy(slot.samples.data()+first*2,history.data(),cursor*2*sizeof(float));
      slot.info={frames,rate,e,++sequence,clock_gettime_nsec_np(CLOCK_UPTIME_RAW)};
      slot.state.store(Ready,std::memory_order_release);published.fetch_add(1,std::memory_order_relaxed);return;
    }
    dropped.fetch_add(1,std::memory_order_relaxed);
  }
  bool take(float *output,uint32_t capacity,MEQSpectrumSnapshot &info){
    const auto e=epoch.load(std::memory_order_acquire);
    int newest=-1;
    for(int i=0;i<3;i++){
      auto &slot=slots[i];
      if(slot.state.load(std::memory_order_acquire)==Ready&&(e&1)&&slot.info.epoch==e&&
         (newest<0||slot.info.sequence>slots[newest].info.sequence))newest=i;
    }
    for(int i=0;i<3;i++)if(i!=newest){uint32_t expected=Ready;slots[i].state.compare_exchange_strong(expected,Free,std::memory_order_release);}
    if(newest<0||capacity<frames)return false;
    auto &slot=slots[newest];
    uint32_t expected=Ready;
    if(!slot.state.compare_exchange_strong(expected,Reading,std::memory_order_acquire))return false;
    info=slot.info;std::memcpy(output,slot.samples.data(),info.frames*2*sizeof(float));
    slot.state.store(Free,std::memory_order_release);
    return epoch.load(std::memory_order_acquire)==info.epoch;
  }
};
}
struct MEQSpectrumReader {std::shared_ptr<myeq::SpectrumCapture> capture;};
