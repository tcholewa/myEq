#include "../../Sources/CDSP/SpectrumCapture.hpp"
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>

using myeq::SpectrumCapture;

static void snapshotTests() {
  SpectrumCapture capture(48000);
  assert(capture.frames == 8192);
  std::vector<float> input(capture.frames * 2), output(capture.frames * 2);
  for (uint32_t i=0;i<capture.frames;i++) { input[i*2]=float(i); input[i*2+1]=-float(i); }
  MEQSpectrumSnapshot info{};
  capture.request(); capture.capture(input.data(),capture.frames);
  assert(capture.blocks==0 && capture.published==0 && !capture.take(output.data(),capture.frames,info));
  capture.enable(true);
  // Fill/wrap history in non-dividing blocks. The snapshot must be chronological and stereo exact.
  constexpr uint32_t block=317;
  std::vector<float> chunk(block*2);
  uint32_t produced=0;
  capture.request();
  while(produced<capture.frames+block) {
    for(uint32_t i=0;i<block;i++) { chunk[i*2]=float(produced+i);chunk[i*2+1]=-float(produced+i); }
    capture.capture(chunk.data(),block);produced+=block;
  }
  assert(capture.take(output.data(),capture.frames,info));
  const auto publishedAt=((capture.frames+block-1)/block)*block;
  assert(info.frames==8192 && info.sampleRate==48000 && (info.epoch&1) && info.sequence==1 && info.capturedNS>0);
  for(uint32_t i=0;i<capture.frames;i++) {
    assert(output[i*2]==float(publishedAt-capture.frames+i));
    assert(output[i*2+1]==-output[i*2]);
  }
  assert(!capture.take(output.data(),capture.frames,info));
  // A stalled consumer fills three slots, then the callback drops snapshots without waiting.
  for(int i=0;i<6;i++){capture.request();capture.capture(input.data(),capture.frames);}
  assert(capture.published==4 && capture.dropped==3);
  assert(!capture.take(output.data(),capture.frames-1,info));
  assert(capture.take(output.data(),capture.frames,info) && info.sequence==4);
  assert(output==input);
  // A rapid hide/show invalidates pending requests, old Ready slots, and partially filled history.
  capture.request();capture.capture(input.data(),capture.frames);
  const auto oldEpoch=info.epoch;
  capture.enable(false);capture.enable(true);
  assert(!capture.take(output.data(),capture.frames,info));
  capture.request();capture.capture(input.data(),1);
  assert(!capture.take(output.data(),capture.frames,info));
  capture.capture(input.data(),capture.frames);
  assert(capture.take(output.data(),capture.frames,info) && info.epoch!=oldEpoch);
  capture.enable(false);
  const auto blocks=capture.blocks.load(), published=capture.published.load();
  for(int i=0;i<100;i++){capture.request();capture.capture(input.data(),capture.frames);}
  assert(capture.blocks==blocks && capture.published==published);
}

static void concurrentTests() {
  SpectrumCapture capture(32000);
  capture.enable(true);capture.request();
  std::atomic<bool> done{false},received{false};
  std::thread producer([&]{
    constexpr uint32_t block=257;
    float input[block*2];uint32_t position=0;
    for(int k=0;k<30000;k++){
      for(uint32_t i=0;i<block;i++) {input[i*2]=float(position+i);input[i*2+1]=-input[i*2];}
      position+=block;
      if(capture.beginBlock()) {
        for(uint32_t i=0;i<block;i++)capture.append(input[i*2],input[i*2+1],input[i*2]*2,input[i*2+1]*3);
        capture.endBlock();
      }
      if(k%32==0)std::this_thread::yield();
    }
    done.store(true,std::memory_order_release);
  });
  std::thread control([&]{
    while(!received.load(std::memory_order_acquire)&&!done.load(std::memory_order_acquire))std::this_thread::yield();
    while(!done.load(std::memory_order_acquire)) {
      capture.enable(true);for(int i=0;i<32;i++)std::this_thread::yield();
      capture.enable(false);std::this_thread::yield();
    }
  });
  std::vector<float> output(capture.frames*2), source(capture.frames*2);MEQSpectrumSnapshot info{};
  uint64_t sequence=0;
  do {
    capture.request();
    if(capture.take(output.data(),capture.frames,info,source.data())){
      assert(info.sequence>sequence);sequence=info.sequence;
      received.store(true,std::memory_order_release);
      for(uint32_t i=0;i<capture.frames;i++) {
        assert(output[i*2+1]==-output[i*2]);
        assert(source[i*2]==output[i*2]*2 && source[i*2+1]==output[i*2+1]*3);
        if(i)assert(output[i*2]==output[(i-1)*2]+1);
      }
    }
    std::this_thread::yield();
  } while(!done.load(std::memory_order_acquire));
  producer.join();control.join();
  assert(sequence>0);
  // Final capture also proves the state machine remains usable after control churn.
  capture.enable(false);capture.enable(true);
  capture.take(output.data(),capture.frames,info);
  capture.request();capture.capture(output.data(),capture.frames);
  assert(capture.take(output.data(),capture.frames,info));
}

int main(){
  for(auto rate:{32000.,44100.,48000.,96000.,192000.}){
    SpectrumCapture capture(rate);assert(capture.frames>=4096&&capture.frames<=32768);
  }
  snapshotTests();concurrentTests();
  std::cout<<"PASS: spectrum wrap, bounded drops, visibility epochs, stereo integrity and concurrent lifetime.\n";
}
