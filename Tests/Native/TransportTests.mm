#include "../../Sources/CTransport/Client.mm"
#include <cassert>
#include <thread>
#include <iostream>
#include <limits>

static void ringTests(){
  auto memory=std::make_shared<Mapping>();assert(memory->create(48000,123));auto s=memory->s;
  assert(valid(s,memory->size));assert(!valid(s,memory->size-1));
  Mapping other;assert(other.map(memory->object));assert(other.s!=s);
  s->deadline=42;assert(other.s->deadline.load()==42);
  assert(isMessage(message("hello")));
  assert(!isMessage(xpc_dictionary_create(nullptr,nullptr,0)));
  s->version++;assert(!valid(s,memory->size));s->version--;
  std::vector<float> input(capacity*2,0.25f),output(capacity*2);
  assert(write(s,input.data(),capacity,1));assert(!write(s,input.data(),1,2));
  assert(s->overruns==1);assert(meq::read(s,output.data(),capacity)==capacity);assert(input==output);
  s->written=capacity-3;s->read=capacity-3;
  input[0]=std::numeric_limits<float>::quiet_NaN();assert(write(s,input.data(),7,3));
  assert(meq::read(s,output.data(),10)==7);assert(output[0]==0&&s->invalidSamples==1&&output[19]==0);
  discard(s);assert(available(s)==0);
  // Concurrent wraparound with exact sequence checking, including producer backpressure.
  constexpr uint32_t blocks=20000,block=31;s->read=0;s->written=0;
  std::thread producer([&]{float b[block*2];for(uint32_t k=0;k<blocks;k++){
    while(capacity-available(s)<block)std::this_thread::yield();
    for(uint32_t i=0;i<block;i++){b[i*2]=float(k*block+i);b[i*2+1]=-b[i*2];}
    assert(write(s,b,block,k));
  }});
  for(uint32_t k=0;k<blocks;k++){
    while(available(s)<block)std::this_thread::yield();
    assert(meq::read(s,output.data(),block)==block);
    for(uint32_t i=0;i<block;i++)assert(output[i*2]==float(k*block+i)&&output[i*2+1]==-output[i*2]);
  }producer.join();assert(available(s)==0);
}
static void renderTests(double driftPPM, double sampleRate=48000, bool planar=false, bool swapped=false){
  MEQConnection connection;connection.memory=std::make_shared<Mapping>();assert(connection.memory->create(sampleRate,123));
  auto s=connection.memory->s;s->active=1;s->sourceRunning=1;s->deadline=UINT64_MAX;
  auto dsp=meq_create();MEQBand bands[8]{};
  for(auto &band:bands){band.frequency=1000;band.width=1;}
  assert(meq_prepare(dsp,sampleRate,bands,8,0));
  MEQChannel left=planar?MEQChannel{0,0,1}:MEQChannel{0,0,2};
  MEQChannel right=planar?MEQChannel{1,0,1}:MEQChannel{0,1,2};
  if(swapped)std::swap(left,right);
  char error[512]{};auto r=meq_renderer_create(&connection,dsp,sampleRate,256,256,left,right,error,sizeof(error));
  if(!r){std::cerr<<error<<"\n";abort();}
  float source[2048],out[512];double phase=0;
  auto produce=[&](uint32_t n){for(uint32_t i=0;i<n;i++){source[i*2]=float(.25*sin(phase));source[i*2+1]=0;phase+=2*M_PI*440/sampleRate;}assert(write(s,source,n,0));};
  produce(512);
  struct {UInt32 count;AudioBuffer buffers[2];} storage;
  if(planar)storage={2,{{1,256*4,out},{1,256*4,out+256}}};
  else storage={1,{{2,sizeof(out),out},{}}};
  auto buffers=reinterpret_cast<AudioBufferList*>(&storage);
  float microphone[512];for(float &v:microphone)v=std::numeric_limits<float>::quiet_NaN();
  AudioBufferList input{1,{{2,sizeof(microphone),microphone}}};
  auto sample=[&](MEQChannel c,int i){return static_cast<float*>(buffers->mBuffers[c.buffer].mData)[i*c.stride+c.channel];};
  AudioTimeStamp ts{};ts.mFlags=kAudioTimeStampSampleTimeValid;
  double fractional=0,energy=0;
  for(int k=0;k<12000;k++){
    fractional+=256*(1+driftPPM/1e6);auto n=uint32_t(fractional);fractional-=n;produce(n);
    ts.mSampleTime=k*256;
    assert(meq_output_callback(0,&ts,&input,&ts,buffers,&ts,r)==noErr);
    for(int i=0;i<256;i++){auto l=sample(left,i);assert(std::isfinite(l)&&fabs(l)<=.945);assert(sample(right,i)==0);energy+=l*l;}
  }
  auto timing=meq_render_timing(r);
  if(r->timingEnabled){assert(timing.callbacks==12000&&timing.maximumNS>0);
    std::cout<<"render timing maxNS="<<timing.maximumNS<<" overHalf="<<timing.overHalfPeriod<<" overPeriod="<<timing.overPeriod<<"\n";
  }else assert(timing.callbacks==0);
  auto health=meq_transport_health(r);
  std::cout<<"rate="<<sampleRate<<" planar="<<planar<<" swapped="<<swapped<<" drift="<<driftPPM<<"ppm buffer="<<health.bufferedFrames<<" ratio="<<health.correction<<" underruns="<<health.underruns<<" energy="<<energy<<"\n";
  assert(energy>1000);assert(health.underruns==0);assert(health.overruns==0);
  assert(health.bufferedFrames<2048);assert(fabs(health.correction-1)<.0021);
  // Lost producer and session revocation must render silence without touching physical inputs.
  if(planar){
    buffers->mBuffers[1].mDataByteSize-=4;
    meq_output_callback(0,&ts,&input,&ts,buffers,&ts,r);
    assert(meq_transport_health(r).invalidSamples==1);
    for(int i=0;i<255;i++)assert(out[i]==0&&out[i+256]==0);
    buffers->mBuffers[1].mDataByteSize+=4;
  }
  s->active=0;meq_output_callback(0,&ts,&input,&ts,buffers,&ts,r);
  for(float v:out)assert(v==0);
  meq_renderer_destroy(r);meq_destroy(dsp);
}
// Independent producer/consumer clocks with different HAL quanta. The original
// equal-block fixture never covered a 512-frame virtual output feeding 128 frames.
static void batchedRenderTests(uint32_t sourceFrames,uint32_t outputFrames,double driftPPM=0,bool jitter=false){
  constexpr double sampleRate=48000;
  MEQConnection connection;connection.memory=std::make_shared<Mapping>();assert(connection.memory->create(sampleRate,123));
  auto s=connection.memory->s;s->active=1;s->sourceRunning=1;s->deadline=UINT64_MAX;
  auto dsp=meq_create();MEQBand bands[8]{};for(auto &b:bands){b.frequency=1000;b.width=1;}
  assert(meq_prepare(dsp,sampleRate,bands,8,0));
  char error[512]{};auto r=meq_renderer_create(&connection,dsp,sampleRate,outputFrames,sourceFrames,{0,0,2},{0,1,2},error,sizeof(error));assert(r);
  assert(!meq_renderer_set_source_frames(r,0)&&!meq_renderer_set_source_frames(r,4097));
  std::vector<float> source(sourceFrames*2),out(outputFrames*2);
  AudioBufferList buffers{1,{{2,UInt32(out.size()*sizeof(float)),out.data()}}};
  AudioBufferList input{0,{}};AudioTimeStamp ts{};ts.mFlags=kAudioTimeStampSampleTimeValid;
  double sourceTime=0,phase=0;uint64_t block=0;
  const double period=sourceFrames/(1+driftPPM/1e6);
  // 320 simulated seconds for 128-frame outputs; includes clock drift settling.
  for(int k=0;k<120000;k++){
    ts.mSampleTime=double(k)*outputFrames;
    while(sourceTime+(jitter&&block%7==3?outputFrames:0)<=ts.mSampleTime){
      for(uint32_t i=0;i<sourceFrames;i++){source[i*2]=float(.25*sin(phase));source[i*2+1]=0;phase+=2*M_PI*440/sampleRate;}
      assert(write(s,source.data(),sourceFrames,0));sourceTime+=period;++block;
    }
    assert(meq_output_callback(0,&ts,&input,&ts,&buffers,&ts,r)==noErr);
    double energy=0;for(uint32_t i=0;i<outputFrames;i++){
      assert(std::isfinite(out[i*2])&&fabs(out[i*2])<=.945&&out[i*2+1]==0);energy+=out[i*2]*out[i*2];
    }
    if(k>1000)assert(energy>0.001); // No silent/repriming blocks once started.
  }
  const auto h=meq_transport_health(r);
  std::cout<<"batched source="<<sourceFrames<<" output="<<outputFrames<<" drift="<<driftPPM<<" jitter="<<jitter<<" underruns="<<h.underruns<<" overruns="<<h.overruns<<"\n";
  assert(h.underruns==0&&h.overruns==0&&h.invalidSamples==0);
  assert(h.bufferedFrames<4*std::max(sourceFrames,outputFrames));
  // A source-quantum change is consumed safely without a control/audio data race.
  assert(meq_renderer_set_source_frames(r,1024));
  meq_output_callback(0,&ts,&input,&ts,&buffers,&ts,r);
  assert(r->target>=2048);
  // An expired lease must still silence a well-buffered renderer.
  s->deadline=0;meq_output_callback(0,&ts,&input,&ts,&buffers,&ts,r);
  for(float value:out)assert(value==0);
  meq_renderer_destroy(r);meq_destroy(dsp);
}
struct BurstFixture {
  MEQConnection connection;
  MEQDSP *dsp=meq_create();
  MEQRenderer *renderer=nullptr;
  Shared *shared=nullptr;
  double rate;
  uint32_t frames;
  uint64_t position=0;
  std::vector<float> source,out;
  BurstFixture(double sampleRate=48000,uint32_t outputFrames=512):rate(sampleRate),frames(outputFrames),source(capacity*2),out(outputFrames*2){
    connection.memory=std::make_shared<Mapping>();assert(connection.memory->create(rate,123));
    shared=connection.memory->s;shared->active=1;shared->sourceRunning=1;shared->deadline=UINT64_MAX;
    MEQBand bands[8]{};for(auto &b:bands){b.frequency=1000;b.width=1;}
    assert(meq_prepare(dsp,rate,bands,8,0));
    for(uint32_t i=0;i<capacity;i++){source[i*2]=.25f;source[i*2+1]=-.125f;}
    createRenderer();
  }
  ~BurstFixture(){meq_renderer_destroy(renderer);meq_destroy(dsp);}
  void createRenderer(){
    char error[512]{};
    renderer=meq_renderer_create(&connection,dsp,rate,frames,512,{0,0,2},{0,1,2},error,sizeof(error));
    if(!renderer){std::cerr<<error<<"\n";abort();}
  }
  void produce(uint32_t n,uint32_t chunk=0){
    while(n){auto size=std::min(n,chunk?chunk:n);assert(write(shared,source.data(),size,0));n-=size;}
  }
  void render(){
    AudioBufferList buffers{1,{{2,UInt32(out.size()*sizeof(float)),out.data()}}},input{0,{}};
    AudioTimeStamp ts{};ts.mFlags=kAudioTimeStampSampleTimeValid;ts.mSampleTime=double(position);
    assert(meq_output_callback(0,&ts,&input,&ts,&buffers,&ts,renderer)==noErr);position+=frames;
  }
  void continuous() const {
    // DC makes any missing portion of a callback visible. Block energy alone
    // can pass when the limiter's delayed samples precede a mostly silent block.
    for(uint32_t i=0;i<frames;i++){
      assert(std::isfinite(out[i*2])&&fabs(out[i*2]-.25f)<.0001f);
      assert(std::isfinite(out[i*2+1])&&fabs(out[i*2+1]+.125f)<.0001f);
    }
  }
};
static void observedBurstTests(double rate,uint32_t outputFrames,uint32_t burst,uint32_t chunk,double driftPPM=0,bool jitter=false){
  BurstFixture f(rate,outputFrames);
  double sourceTime=0;uint64_t block=0;
  const auto period=burst/(1+driftPPM/1e6);
  while(f.position<rate*40){
    while(sourceTime+(jitter&&block%7==3?outputFrames:0)<=f.position){
      f.produce(burst,chunk);sourceTime+=period;++block;
    }
    f.render();if(f.position>rate)f.continuous();
  }
  const auto h=meq_transport_health(f.renderer);
  std::cout<<"observed burst="<<h.observedBurstFrames<<" target="<<h.targetFrames<<" rate="<<rate<<" output="<<outputFrames<<" grouped="<<(chunk!=0)<<" drift="<<driftPPM<<" jitter="<<jitter<<" underruns="<<h.underruns<<"\n";
  assert(h.underruns==0&&h.shortReads==0&&h.converterErrors==0&&h.overruns==0&&h.invalidSamples==0);
  assert(h.observedBurstFrames==burst&&h.targetFrames==2*burst);
}
static void burstTransitionTests(){
  BurstFixture f;
  // Grow from regular 512-frame delivery to grouped 4096-frame bursts, then
  // return to small writes. The reserve must not shrink and oscillate.
  for(unsigned phase=0;phase<3;phase++){
    const uint32_t burst=phase==1?4096:512;
    const auto start=f.position;double next=double(start);
    while(f.position-start<48000*4){
      while(next<=f.position){f.produce(burst,phase==1?512:0);next+=burst;}
      f.render();if(f.position-start>48000)f.continuous();
    }
    assert(meq_transport_health(f.renderer).targetFrames==(phase?8192u:1024u));
  }
  auto health=meq_transport_health(f.renderer);assert(health.underruns==0&&health.converterErrors==0);
  // A source pause may exhaust its queued audio, but is not an active underrun.
  f.shared->sourceRunning=0;
  for(int k=0;k<40;k++)f.render();
  health=meq_transport_health(f.renderer);
  assert(health.underruns==0&&health.shortReads>0&&health.converterErrors==0);
  f.shared->sourceRunning=1;f.shared->discontinuities.fetch_add(1);
  f.render(); // Process the discontinuity before the fresh source arrives.
  for(int k=0;k<1000;k++){if(k%8==0)f.produce(4096);f.render();if(k>100)f.continuous();}
  assert(meq_transport_health(f.renderer).underruns==0);
  // A new renderer resets adaptation; old priming/discontinuities do not.
  meq_renderer_destroy(f.renderer);discard(f.shared);f.createRenderer();
  health=meq_transport_health(f.renderer);assert(health.observedBurstFrames==0&&health.targetFrames==1024);
}
static void reserveAndFailureTests(){
  BurstFixture f;
  f.produce(512);f.render();
  const auto readBefore=f.shared->read.load();
  f.produce(4096);f.render();
  assert(meq_transport_health(f.renderer).targetFrames==8192);
  assert(f.shared->read.load()==readBefore); // Retain the queued audio while growing.
  discard(f.shared);
  f.produce(capacity);f.render();
  auto h=meq_transport_health(f.renderer);
  assert(h.observedBurstFrames==capacity&&h.targetFrames==8192); // Reachable and capped.
  // Corrupt/nonmonotonic observations cannot wrap the arithmetic or grow forever.
  const auto written=f.shared->written.load();f.shared->written=written+capacity+1;
  f.shared->active=0;f.render();assert(meq_transport_health(f.renderer).targetFrames==8192);
  f.shared->written=written;f.shared->read=written;f.render();
  assert(meq_transport_health(f.renderer).targetFrames==8192);

  BurstFixture error;
  error.produce(4096);error.render();error.produce(4096);error.render();
  assert(error.renderer->primed);
  assert(AudioUnitUninitialize(error.renderer->converter)==noErr);
  error.render();h=meq_transport_health(error.renderer);
  assert(h.converterErrors==1&&h.lastConverterStatus!=noErr&&h.invalidSamples==1);
  assert(h.underruns==0&&h.shortReads==0); // Converter failure is not starvation.
}
static void transportTelemetryConcurrencyTests(){
  BurstFixture f;std::atomic<bool> done{false};
  std::thread control([&]{
    while(!done.load(std::memory_order_relaxed)){
      const auto h=meq_transport_health(f.renderer);
      assert(h.targetFrames>=1024&&h.targetFrames<=8192&&h.observedBurstFrames<=capacity);
      assert(meq_renderer_set_source_frames(f.renderer,1024));
      assert(meq_renderer_set_source_frames(f.renderer,512));
    }
  });
  for(int k=0;k<5000;k++){if(k%8==0)f.produce(4096,512);f.render();}
  done.store(true,std::memory_order_relaxed);control.join();
  const auto h=meq_transport_health(f.renderer);
  assert(h.underruns==0&&h.overruns==0&&h.shortReads==0&&h.converterErrors==0);
}
int main(){@autoreleasepool{
  ringTests();reserveAndFailureTests();burstTransitionTests();transportTelemetryConcurrencyTests();
  observedBurstTests(48000,512,512,0);
  for(double rate:{32000,44100,48000,96000,192000}){
    observedBurstTests(rate,512,4096,0);
    observedBurstTests(rate,128,4096,512);
  }
  observedBurstTests(48000,512,4096,512,300,true);
  observedBurstTests(48000,128,4096,0,-300,true);
  batchedRenderTests(512,128);batchedRenderTests(512,128,300,true);batchedRenderTests(512,128,-300,true);batchedRenderTests(512,256);batchedRenderTests(512,512,0,true);batchedRenderTests(1024,128);batchedRenderTests(128,512);renderTests(0);renderTests(300);renderTests(-300);renderTests(0,44100);renderTests(0,96000);renderTests(0,192000);renderTests(0,48000,true,true);renderTests(0,48000,false,true);std::cout<<"Native transport/render checks passed\n";
}}
