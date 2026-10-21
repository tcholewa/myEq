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
  char error[512]{};auto r=meq_renderer_create(&connection,dsp,sampleRate,256,left,right,error,sizeof(error));
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
int main(){@autoreleasepool{ringTests();renderTests(0);renderTests(300);renderTests(-300);renderTests(0,44100);renderTests(0,96000);renderTests(0,192000);renderTests(0,48000,true,true);renderTests(0,48000,false,true);std::cout<<"Native transport/render checks passed\n";}}
