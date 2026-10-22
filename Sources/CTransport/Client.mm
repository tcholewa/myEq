#include "include/MTransport.h"
#include "IPC.hpp"
#import <AudioToolbox/AudioToolbox.h>
#include <array>
#include <cstdlib>

using namespace meq;
namespace {
struct ClientState {
  xpc_connection_t bridge=nil,recovery=nil;
  std::atomic<int> failure{0}; // 0 connected, 1 transient, 2 permanent; permanent wins.
  ~ClientState(){if(bridge)xpc_connection_cancel(bridge);if(recovery)xpc_connection_cancel(recovery);}
};
}
struct MEQConnection {
  std::shared_ptr<ClientState> state=std::make_shared<ClientState>();
  std::shared_ptr<Mapping> memory;
  uint64_t volumeSequence=0,generation=0;
};
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
struct MEQRenderer {
  std::shared_ptr<Mapping> memory;
  MEQDSP *dsp;
  AudioUnit converter=nullptr;
  MEQChannel left,right;
  double rate;
  uint32_t outputFrames,target,fade=0,fadeFrames=1;
  Float32 appliedRate=1;
  bool warming=false;
  bool timingEnabled=false;
  std::array<std::atomic<uint64_t>,8> timingBins{};
  std::atomic<uint64_t> timingMaximum{0};
  std::atomic<uint32_t> sourceFrames{0};
  uint64_t discontinuity=0;
  bool primed=false,shortRead=false;
  Drift drift;
  std::atomic<double> correction{1};
  std::array<float,capacity*2> input{};
  std::array<float,8192*2> stereo{};
  std::array<float,8192> leftSamples{},rightSamples{};
  ~MEQRenderer(){if(converter){AudioUnitUninitialize(converter);AudioComponentInstanceDispose(converter);}}
};
// Single callback writer; control readers only load. No CAS loop, allocation or logging.
struct RenderTimer {
  MEQRenderer *r;uint64_t begin;uint32_t frames;
  explicit RenderTimer(MEQRenderer *renderer):r(renderer),begin(r->timingEnabled?now():0),frames(r->outputFrames){}
  ~RenderTimer(){
    if(!begin)return;
    const auto elapsed=now()-begin;
    const double fraction=double(elapsed)*r->rate/(1e9*frames);
    unsigned bin=0;double upper=.0625;
    while(bin<7&&fraction>upper){++bin;upper*=2;}
    r->timingBins[bin].fetch_add(1,std::memory_order_relaxed);
    if(elapsed>r->timingMaximum.load(std::memory_order_relaxed))r->timingMaximum.store(elapsed,std::memory_order_relaxed);
  }
};
extern "C" MEQRenderTiming meq_render_timing(MEQRenderer *r){
  MEQRenderTiming result{};if(!r||!r->timingEnabled)return result;
  for(unsigned i=0;i<8;++i){auto count=r->timingBins[i].load(std::memory_order_relaxed);result.callbacks+=count;if(i>=4)result.overHalfPeriod+=count;if(i>=5)result.overPeriod+=count;}
  result.maximumNS=r->timingMaximum.load(std::memory_order_relaxed);return result;
}
extern "C" int meq_read_settings(const char *path,uint8_t **bytes,size_t *length){
  *bytes=nullptr;*length=0;struct stat st{};if(lstat(path,&st)&&errno==ENOENT)return 1;
  NSData *data=readFile(path,4*1024*1024,getuid());if(!data)return -1;
  auto copy=static_cast<uint8_t*>(malloc(std::max(size_t(1),size_t(data.length))));if(!copy)return -1;
  memcpy(copy,data.bytes,data.length);*bytes=copy;*length=data.length;return 0;
}
extern "C" bool meq_write_settings(const char *path,const uint8_t *bytes,size_t length){
  if(length>4*1024*1024)return false;
  return privateWrite(@(path),[NSData dataWithBytes:bytes length:length],4*1024*1024);
}
extern "C" bool meq_installation_id(char *value,size_t capacity){
  id identifier=trust()[@"installationID"];
  if(![identifier isKindOfClass:NSString.class]||![[NSUUID alloc] initWithUUIDString:identifier])return false;
  copyError(value,capacity,[identifier UTF8String]);return true;
}
extern "C" MEQConnection *meq_connect(char *out,size_t size,bool *canRetry){
  *canRetry=false;
  auto c=std::make_unique<MEQConnection>();
  auto q=dispatch_queue_create("com.tc.myEq.ipc",DISPATCH_QUEUE_SERIAL);
  std::weak_ptr<ClientState> weak=c->state;
  for(int i=0;i<2;i++){
    auto peer=xpc_connection_create_mach_service(i?bridgeService:recoveryService,q,i?XPC_CONNECTION_MACH_SERVICE_PRIVILEGED:0);
    if(!constrain(peer,requirement(i?@"bridge":@"recovery"))){copyError(out,size,"Install this build of myEq before enabling EQ.");xpc_connection_cancel(peer);return nullptr;}
    if(i)c->state->bridge=peer;else c->state->recovery=peer;
    xpc_connection_set_event_handler(peer,^(xpc_object_t event){if(xpc_get_type(event)==XPC_TYPE_ERROR)if(auto s=weak.lock()){int failure=retryable(event)?1:2;int previous=s->failure.load();
      while(previous<failure&&!s->failure.compare_exchange_weak(previous,failure)){}
      NSLog(@"myEq: %s connection event: %s",i?"bridge":"recovery",error(event).c_str());}});
    xpc_connection_resume(peer);
    auto result=handshakeResult(peer,"app");
    if(!succeeded(result)){
      *canRetry=retryable(result);
      auto detail=std::string(i?"Audio bridge: ":"Recovery helper: ")+error(result);
      NSLog(@"myEq: connection failed: %s",detail.c_str());copyError(out,size,detail);return nullptr;
    }
  }
  return c.release();
}
extern "C" bool meq_open_transport(MEQConnection *c,double rate,const char *outputName,char *out,size_t size,bool *canRetry){
  *canRetry=false;
  auto m=message("open");xpc_dictionary_set_double(m,"rate",rate);
  xpc_dictionary_set_string(m,"outputName",outputName);
  auto r=request(c->state->bridge,m);if(!succeeded(r)){*canRetry=retryable(r);copyError(out,size,error(r));return false;}
  auto mapping=std::make_shared<Mapping>();
  if(!mapping->map(xpc_dictionary_get_value(r,"memory"))||mapping->acceptedRate!=rate||mapping->acceptedGeneration!=xpc_dictionary_get_uint64(r,"generation")){copyError(out,size,"Invalid or incompatible driver transport.");return false;}
  c->memory=mapping;c->generation=mapping->acceptedGeneration;c->volumeSequence=0;return true;
}
extern "C" bool meq_prepare_buffers(MEQConnection *c,const char *uid,bool apply,char *out,size_t size,bool *canRetry){
  *canRetry=false;
  auto m=sessionMessage("prepareBuffers",c->generation);xpc_dictionary_set_string(m,"uid",uid);xpc_dictionary_set_bool(m,"apply",apply);
  auto r=request(c->state->recovery,m);
  if(!succeeded(r)){*canRetry=retryable(r);copyError(out,size,error(r));return false;}return true;
}
extern "C" bool meq_activate_route(MEQConnection *c,const char *uid,char *out,size_t size,bool *canRetry){
  *canRetry=false;
  // Buffer preparation may wait for HAL publication; start activation with a fresh app beat.
  auto renewed=request(c->state->bridge,sessionMessage("heartbeat",c->generation),0.5);
  if(!succeeded(renewed)){*canRetry=retryable(renewed);copyError(out,size,error(renewed));return false;}
  auto m=sessionMessage("activate",c->generation);xpc_dictionary_set_string(m,"uid",uid);
  auto r=request(c->state->recovery,m);if(!succeeded(r)){*canRetry=retryable(r);copyError(out,size,error(r));return false;}return true;
}
extern "C" int meq_heartbeat(MEQConnection *c,char *out,size_t size,bool *canRetry){
  *canRetry=false;
  if(!c||c->state->failure.load()){
    *canRetry=c&&c->state->failure.load()==1;
    copyError(out,size,"Audio helper connection was lost. Retry to reconnect.");return 0;
  }
  // Renew first: a slow recovery status RPC must not starve the app's own lease.
  auto r=request(c->state->bridge,sessionMessage("heartbeat",c->generation),0.5);
  if(!succeeded(r)){*canRetry=retryable(r);copyError(out,size,error(r));return 0;}
  auto status=request(c->state->recovery,sessionMessage("status",c->generation),0.5);
  // Only absence of a reply is tolerated; the bridge independently enforces recovery freshness.
  if(!status&&!c->state->failure.load())return 1;
  if(!succeeded(status)){*canRetry=retryable(status);copyError(out,size,error(status));return 0;}
  if(!xpc_dictionary_get_value(status,"reason")||xpc_get_type(xpc_dictionary_get_value(status,"reason"))!=XPC_TYPE_INT64||!xpc_dictionary_get_value(status,"active")||xpc_get_type(xpc_dictionary_get_value(status,"active"))!=XPC_TYPE_BOOL){copyError(out,size,"The recovery helper returned an invalid status.");return 0;}
  auto reason=xpc_dictionary_get_int64(status,"reason");if(reason==2||reason==3)return int(reason);
  if(reason||!xpc_dictionary_get_bool(status,"active")){*canRetry=reason==1&&retryable(status);copyError(out,size,"Audio recovery restored ordinary playback. Retry to reconnect.");return 0;}
  return 1;
}
extern "C" void meq_close_transport(MEQConnection *c){
  if(!c||!c->generation)return;
  request(c->state->recovery,sessionMessage("restore",c->generation),3);
  request(c->state->bridge,sessionMessage("close",c->generation),0.5);c->memory.reset();c->generation=0;
}
extern "C" void meq_disconnect(MEQConnection *c){delete c;}
extern "C" bool meq_volume_request(MEQConnection *c,float *volume,bool *muted){
  if(!c||!c->memory)return false;auto s=c->memory->s;
  auto v=s->volumeRequest.load(std::memory_order_acquire);if(v==c->volumeSequence)return false;
  c->volumeSequence=v;*volume=s->volume.load();*muted=s->muted.load();return true;
}
extern "C" void meq_volume_state(MEQConnection *c,bool volumeSupported,bool muteSupported,float volume,bool muted){
  if(!c||!c->memory)return;auto s=c->memory->s;s->volumeSupported=volumeSupported;s->muteSupported=muteSupported;
  // Do not erase a volume-key request that arrived between polling and publishing hardware state.
  if(s->volumeRequest.load()==c->volumeSequence){s->volume=std::clamp(volume,0.f,1.f);s->muted=muted;}
}
static OSStatus supply(void *context,AudioUnitRenderActionFlags *,const AudioTimeStamp *,UInt32,UInt32 frames,AudioBufferList *out){
  auto r=static_cast<MEQRenderer*>(context);if(frames>capacity||out->mNumberBuffers!=2)return kAudio_ParamError;
  auto count=r->warming?frames:meq::read(r->memory->s,r->input.data(),frames);if(count<frames)r->shortRead=true;
  for(UInt32 c=0;c<2;c++){
    if(!out->mBuffers[c].mData||out->mBuffers[c].mDataByteSize<frames*sizeof(float))return kAudio_ParamError;
    auto p=static_cast<float*>(out->mBuffers[c].mData);for(UInt32 i=0;i<frames;i++)p[i]=r->input[i*2+c];
  }return noErr;
}
extern "C" MEQRenderer *meq_renderer_create(MEQConnection *c,MEQDSP *dsp,double rate,uint32_t frames,uint32_t sourceFrames,MEQChannel left,MEQChannel right,char *out,size_t size){
  if(!c||!c->memory||!dsp||frames>4096||!frames||!sourceFrames||sourceFrames>4096){copyError(out,size,"Unsupported output buffer size.");return nullptr;}
  auto r=std::make_unique<MEQRenderer>();r->memory=c->memory;r->dsp=dsp;r->rate=rate;r->left=left;r->right=right;r->outputFrames=frames;r->sourceFrames=sourceFrames;r->target=std::max(256u,2*std::max(frames,sourceFrames));r->fadeFrames=uint32_t(ceil(rate*.005));
  const char *timing=getenv("MYEQ_RENDER_TIMING");r->timingEnabled=timing&&strcmp(timing,"1")==0;
  AudioComponentDescription description{kAudioUnitType_FormatConverter,kAudioUnitSubType_Varispeed,kAudioUnitManufacturer_Apple,0,0};
  auto component=AudioComponentFindNext(nullptr,&description);
  OSStatus status=component?AudioComponentInstanceNew(component,&r->converter):kAudio_ParamError;
  AudioStreamBasicDescription fmt{rate,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved,4,1,4,2,32,0};
  UInt32 maximum=8192;AURenderCallbackStruct callback{supply,r.get()};
  if(!status)status=AudioUnitSetProperty(r->converter,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&fmt,sizeof(fmt));
  if(!status)status=AudioUnitSetProperty(r->converter,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&fmt,sizeof(fmt));
  if(!status)status=AudioUnitSetProperty(r->converter,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maximum,sizeof(maximum));
  if(!status)status=AudioUnitSetProperty(r->converter,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback));
  if(!status)status=AudioUnitInitialize(r->converter);
  if(status){copyError(out,size,"Could not initialize clock-drift conversion (Core Audio "+std::to_string(status)+").");return nullptr;}
  // Exercise lazy converter setup before HAL starts, without consuming transport samples.
  r->warming=true;
  struct {UInt32 count;AudioBuffer buffers[2];} warm{2,{{1,frames*4,r->leftSamples.data()},{1,frames*4,r->rightSamples.data()}}};
  AudioTimeStamp timestamp{};timestamp.mFlags=kAudioTimeStampSampleTimeValid;
  AudioUnitRenderActionFlags flags=0;
  status=AudioUnitRender(r->converter,&flags,&timestamp,0,frames,reinterpret_cast<AudioBufferList*>(&warm));
  if(!status)status=AudioUnitReset(r->converter,kAudioUnitScope_Global,0);
  r->warming=false;
  if(status){copyError(out,size,"Could not warm clock-drift conversion.");return nullptr;}
  return r.release();
}
extern "C" bool meq_renderer_set_source_frames(MEQRenderer *r,uint32_t frames){
  if(!r||!frames||frames>4096)return false;
  r->sourceFrames.store(frames,std::memory_order_relaxed);return true;
}
extern "C" void meq_renderer_destroy(MEQRenderer *r){delete r;}
extern "C" MEQTransportHealth meq_transport_health(MEQRenderer *r){
  if(!r)return {};auto s=r->memory->s;
  return {s->rendered.load(),s->underruns.load(),s->overruns.load(),s->discontinuities.load(),s->invalidSamples.load(),available(s),r->correction.load(),bool(s->active.load())};
}
extern "C" OSStatus meq_output_callback(AudioObjectID,const AudioTimeStamp*,const AudioBufferList*,const AudioTimeStamp*,AudioBufferList *out,const AudioTimeStamp *timestamp,void *context){
  auto r=static_cast<MEQRenderer*>(context);auto s=r->memory->s;
  RenderTimer timing(r);
  s->rendered.fetch_add(1,std::memory_order_relaxed);
  for(UInt32 i=0;i<out->mNumberBuffers;i++)if(out->mBuffers[i].mData)memset(out->mBuffers[i].mData,0,out->mBuffers[i].mDataByteSize);
  auto count=[out](MEQChannel c)->uint32_t{
    if(c.buffer<0||UInt32(c.buffer)>=out->mNumberBuffers||c.stride<=0||c.channel<0||c.channel>=c.stride)return 0;
    auto &b=out->mBuffers[c.buffer];return b.mData&&b.mNumberChannels==UInt32(c.stride)&&b.mDataByteSize%(sizeof(float)*c.stride)==0?b.mDataByteSize/(sizeof(float)*c.stride):0;
  };
  const uint32_t frames=count(r->left);
  if(!frames||frames!=count(r->right)||frames>8192){s->invalidSamples.fetch_add(1,std::memory_order_relaxed);return noErr;}
  timing.frames=frames;
  // Reserve two blocks of the larger clock domain, not just two hardware blocks.
  // A 512-frame producer cannot continuously feed a 128-frame device from 256 frames.
  const auto target=std::max(256u,2*std::max(frames,r->sourceFrames.load(std::memory_order_relaxed)));
  if(target!=r->target){
    if(target>r->target)r->primed=false;
    r->target=target;r->drift={};
  }
  auto discontinuity=s->discontinuities.load(std::memory_order_acquire);
  if(discontinuity!=r->discontinuity){r->discontinuity=discontinuity;r->primed=false;discard(s);}
  bool ready=s->active.load(std::memory_order_acquire)&&now()<s->deadline.load(std::memory_order_relaxed);
  if(!ready){r->primed=false;discard(s);}
  if(ready&&!r->primed&&available(s)>=r->target){
    if(AudioUnitReset(r->converter,kAudioUnitScope_Global,0)){
      s->invalidSamples.fetch_add(1,std::memory_order_relaxed);return noErr;
    }
    r->primed=true;r->fade=0;r->drift={};
  }
  memset(r->stereo.data(),0,frames*2*sizeof(float));
  if(ready&&r->primed){
    double ratio=r->drift.update(double(available(s))-r->target,r->rate,frames/r->rate);r->correction.store(ratio,std::memory_order_relaxed);
    if(Float32(ratio)!=r->appliedRate){
      if(AudioUnitSetParameter(r->converter,kVarispeedParam_PlaybackRate,kAudioUnitScope_Global,0,Float32(ratio),0)){
        s->invalidSamples.fetch_add(1,std::memory_order_relaxed);r->primed=false;return noErr;
      }
      r->appliedRate=Float32(ratio);
    }
    struct {UInt32 count;AudioBuffer buffers[2];} buffers{2,{{1,frames*4,r->leftSamples.data()},{1,frames*4,r->rightSamples.data()}}};
    AudioUnitRenderActionFlags flags=0;r->shortRead=false;
    OSStatus status=AudioUnitRender(r->converter,&flags,timestamp,0,frames,reinterpret_cast<AudioBufferList*>(&buffers));
    if(status||r->shortRead){
      if(s->sourceRunning.load(std::memory_order_relaxed))s->underruns.fetch_add(1,std::memory_order_relaxed);
      r->primed=false;discard(s);
    }else for(uint32_t i=0;i<frames;i++){
      const auto fadeFrames=r->fadeFrames;
      if(r->fade<fadeFrames)++r->fade;
      float fade=float(r->fade)/fadeFrames;
      r->stereo[i*2]=r->leftSamples[i]*fade;r->stereo[i*2+1]=r->rightSamples[i]*fade;
    }
  }
  meq_process(r->dsp,r->stereo.data(),frames);
  if(!ready)return noErr;
  float *l=static_cast<float*>(out->mBuffers[r->left.buffer].mData),*rr=static_cast<float*>(out->mBuffers[r->right.buffer].mData);
  for(uint32_t i=0;i<frames;i++){l[i*r->left.stride+r->left.channel]=r->stereo[i*2];rr[i*r->right.stride+r->right.channel]=r->stereo[i*2+1];}
  return noErr;
}
