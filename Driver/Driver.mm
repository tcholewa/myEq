// Output-only AudioServerPlugIn. No client HAL calls, filesystem audio, or input stream.
#import <CoreAudio/AudioServerPlugIn.h>
#import <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <mutex>
#include "IPC.hpp"

namespace {
using namespace meq;
constexpr AudioObjectID plugin=1, device=2, stream=3, volumeControl=4, muteControl=5;
AudioServerPlugInHostRef host=nullptr;
dispatch_queue_t control;
char controlKey;
void onControl(dispatch_block_t block){
  if(dispatch_get_specific(&controlKey))block();else dispatch_sync(control,block);
}
xpc_connection_t bridge;
dispatch_source_t timer;
std::shared_ptr<Mapping> mapping;
std::atomic<Shared*> realtime{nullptr};
std::atomic<bool> alive{false};
std::atomic<double> rate{48000};
std::atomic<uint64_t> anchor{0}, seed{1};
std::atomic<uint32_t> clients{0}, refs{1};
double ticksPerSecond=1e9;
std::mutex stateMutex;
// Display metadata is protected by stateMutex and never read by the audio callback.
NSString *deviceName=@"myEq";
AudioServerPlugInDriverInterface interface;
AudioServerPlugInDriverInterface *interfacePointer=&interface;
AudioServerPlugInDriverRef driver=&interfacePointer;
bool connecting=false;
uint64_t configurationRevision=0,pendingGeneration=0;
// Used only by the single WriteMix thread, reset while HAL has stopped IO.
double expectedSampleTime=0;
bool expectedSampleTimeValid=false;

void changed(AudioObjectID object,std::initializer_list<AudioObjectPropertySelector> selectors) {
  for(auto s:selectors){AudioObjectPropertyAddress a{s,kAudioObjectPropertyScopeGlobal,0};host->PropertiesChanged(host,object,1,&a);}
}
void setAlive(bool value) {
  if(alive.exchange(value)!=value)changed(device,{kAudioDevicePropertyDeviceIsAlive,kAudioDevicePropertyDeviceCanBeDefaultDevice,kAudioDevicePropertyDeviceCanBeDefaultSystemDevice});
}
struct Configuration {
  std::shared_ptr<Mapping> memory;
  xpc_connection_t peer;
  xpc_object_t request;
  NSString *name;
  uint64_t revision;
};
NSString *nameForOutput(const char *outputName){
  NSString *name=outputName?[NSString stringWithUTF8String:outputName]:nil;
  return name.length?[@"myEq: " stringByAppendingString:name]:@"myEq";
}
void configure(std::shared_ptr<Mapping> memory,xpc_connection_t peer=nil,xpc_object_t request=nil,NSString *name=@"myEq") {
  auto c=new Configuration{memory,peer,request,name,++configurationRevision};
  pendingGeneration=memory?memory->acceptedGeneration:0;
  setAlive(false);
  if(host->RequestDeviceConfigurationChange(host,device,1,c)!=noErr){
    if(request)sendReply(peer,request,"Core Audio rejected driver reconfiguration.");delete c;
  }
}
void connectBridge() {
  if(bridge||connecting)return;connecting=true;
  auto c=xpc_connection_create_mach_service(bridgeService,control,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
  // Trust material is bundled with the driver because the driver sandbox cannot read installer files.
  CFBundleRef bundle=CFBundleGetBundleWithIdentifier(CFSTR("com.tc.myEq.driver"));
  auto trustURL=bundle?CFBundleCopyResourceURL(bundle,CFSTR("BridgeTrust"),CFSTR("plist"),nullptr):nullptr;
  NSDictionary *t=trustURL?[NSDictionary dictionaryWithContentsOfURL:(__bridge NSURL*)trustURL]:nil;
  if(trustURL)CFRelease(trustURL);
  NSString *hash=t[@"bridge"];
  NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
  std::string req=([hash isKindOfClass:NSString.class]&&hash.length==40&&[hash rangeOfCharacterFromSet:bad].location==NSNotFound)?std::string("cdhash H\"")+hash.UTF8String+"\"":"";
  if(!constrain(c,req)){xpc_connection_cancel(c);connecting=false;return;}
  bridge=c;
  xpc_connection_set_event_handler(c,^(xpc_object_t m){
    if(xpc_get_type(m)==XPC_TYPE_ERROR){
      if(bridge==c){bridge=nil;connecting=false;setAlive(false);configure(nullptr);}return;
    }
    if(!isMessage(m)){xpc_connection_cancel(c);return;}
    auto op=string(m,"op");
    if(op=="attach"&&schema(m,"attach",{{"generation",XPC_TYPE_UINT64},{"rate",XPC_TYPE_DOUBLE},{"memory",XPC_TYPE_SHMEM},{"outputName",XPC_TYPE_STRING,1024}})){
      auto response=replyMessage(m);if(!response){xpc_connection_cancel(c);return;}
      auto next=std::make_shared<Mapping>();
      if(!next->map(xpc_dictionary_get_value(m,"memory"))||next->acceptedGeneration!=xpc_dictionary_get_uint64(m,"generation")||next->acceptedRate!=xpc_dictionary_get_double(m,"rate")){
        sendReply(c,response,"Invalid shared memory.");return;
      }
      configure(next,c,response,nameForOutput(xpc_dictionary_get_string(m,"outputName")));
    }else if((op=="detach"||op=="refresh")&&sessionSchema(m,op.c_str())){
      auto token=xpc_dictionary_get_uint64(m,"generation");
      if(op=="detach"){
        if(token==pendingGeneration||(mapping&&token==mapping->acceptedGeneration)){
          if(mapping){mapping->s->active=0;mapping->s->deadline=0;}configure(nullptr);
        }
      }else if(mapping&&token==mapping->acceptedGeneration){
        auto s=mapping->s;setAlive(s->active.load()&&now()<s->deadline.load());
        changed(volumeControl,{kAudioLevelControlPropertyScalarValue});changed(muteControl,{kAudioBooleanControlPropertyValue});
      }
    }else xpc_connection_cancel(c);
  });
  xpc_connection_resume(c);
  auto hello=message("hello");xpc_dictionary_set_string(hello,"role","driver");
  xpc_connection_send_message_with_reply(c,hello,control,^(xpc_object_t r){
    if(!succeeded(r)){connecting=false;xpc_connection_cancel(c);return;}
    xpc_connection_send_message_with_reply(c,message("ready"),control,^(xpc_object_t result){
      connecting=false;if(!succeeded(result))xpc_connection_cancel(c);
    });
  });
}
AudioStreamBasicDescription format() {
  return {rate.load(),kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,8,1,8,2,32,0};
}
template<class T> OSStatus put(const T &value,UInt32 room,UInt32 *size,void *out) {
  if(room<sizeof(T))return kAudioHardwareBadPropertySizeError;
  memcpy(out,&value,sizeof(T));*size=sizeof(T);return noErr;
}
OSStatus list(const std::vector<UInt32> &values,UInt32 room,UInt32 *size,void *out) {
  auto n=std::min(size_t(room/4),values.size());if(n)memcpy(out,values.data(),n*4);*size=UInt32(n*4);return noErr;
}
bool outputScope(const AudioObjectPropertyAddress *a) {return a->mScope!=kAudioObjectPropertyScopeInput;}
OSStatus get(AudioServerPlugInDriverRef,AudioObjectID id,pid_t,const AudioObjectPropertyAddress *a,UInt32 qualifierSize,const void *qualifier,UInt32 room,UInt32 *size,void *out) {
  if(!a||!size||!out||id<plugin||id>muteControl)return kAudioHardwareBadObjectError;
  std::lock_guard<std::mutex> lock(stateMutex);
  *size=0; auto s=realtime.load(std::memory_order_acquire);
  switch(a->mSelector){
    case kAudioObjectPropertyBaseClass:return put<UInt32>(id==plugin?kAudioObjectClassID:id==device?kAudioObjectClassID:id==stream?kAudioObjectClassID:id==volumeControl?kAudioLevelControlClassID:kAudioBooleanControlClassID,room,size,out);
    case kAudioObjectPropertyClass:return put<UInt32>(id==plugin?kAudioPlugInClassID:id==device?kAudioDeviceClassID:id==stream?kAudioStreamClassID:id==volumeControl?kAudioVolumeControlClassID:kAudioMuteControlClassID,room,size,out);
    case kAudioObjectPropertyOwner:return put<UInt32>(id==plugin?kAudioObjectUnknown:id==device?plugin:device,room,size,out);
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: {
      CFStringRef name=a->mSelector==kAudioObjectPropertyManufacturer?CFSTR("myEq"):id==device?(__bridge CFStringRef)deviceName:id==stream?CFSTR("System stereo mix"):id==volumeControl?CFSTR("Output volume"):id==muteControl?CFSTR("Output mute"):CFSTR("myEq");
      if(room<sizeof(name))return kAudioHardwareBadPropertySizeError;CFRetain(name);return put(name,room,size,out);
    }
    case kAudioObjectPropertyOwnedObjects:
      return list(id==plugin?std::vector<UInt32>{device}:id==device&&outputScope(a)?std::vector<UInt32>{stream,volumeControl,muteControl}:std::vector<UInt32>{},room,size,out);
    case kAudioPlugInPropertyBundleID:if(id==plugin){CFStringRef v=CFSTR("com.tc.myEq.driver");CFRetain(v);return put(v,room,size,out);}break;
    case kAudioPlugInPropertyDeviceList:if(id==plugin)return list({device},room,size,out);break;
    case kAudioPlugInPropertyTranslateUIDToDevice:if(id==plugin){
      CFStringRef uid=nullptr;if(qualifierSize==sizeof(uid)&&qualifier)memcpy(&uid,qualifier,sizeof(uid));
      return put<UInt32>(uid&&CFEqual(uid,CFSTR("com.tc.myEq.output"))?device:0,room,size,out);
    }break;
    case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID:if(id==device){CFStringRef v=CFSTR("com.tc.myEq.output");CFRetain(v);return put(v,room,size,out);}break;
    case kAudioDevicePropertyTransportType:if(id==device)return put<UInt32>(kAudioDeviceTransportTypeVirtual,room,size,out);break;
    case kAudioDevicePropertyRelatedDevices:if(id==device)return list({device},room,size,out);break;
    case kAudioDevicePropertyClockDomain:if(id==device)return put<UInt32>(0,room,size,out);break;
    case kAudioDevicePropertyDeviceIsAlive:if(id==device)return put<UInt32>(alive,room,size,out);break;
    case kAudioDevicePropertyDeviceIsRunning:if(id==device)return put<UInt32>(clients.load()>0,room,size,out);break;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
      if(id==device)return put<UInt32>(outputScope(a)&&alive,room,size,out);break;
    case kAudioDevicePropertyStreams:if(id==device)return list(outputScope(a)?std::vector<UInt32>{stream}:std::vector<UInt32>{},room,size,out);break;
    case kAudioObjectPropertyControlList:if(id==device)return list({volumeControl,muteControl},room,size,out);break;
    case kAudioDevicePropertyNominalSampleRate:if(id==device)return put<double>(rate,room,size,out);break;
    case kAudioDevicePropertyAvailableNominalSampleRates:if(id==device)return put(AudioValueRange{32000,192000},room,size,out);break;
    case kAudioDevicePropertyLatency:case kAudioDevicePropertySafetyOffset:if(id==device||id==stream)return put<UInt32>(0,room,size,out);break;
    case kAudioDevicePropertyZeroTimeStampPeriod:if(id==device)return put<UInt32>(16384,room,size,out);break;
    case kAudioDevicePropertyClockAlgorithm:if(id==device)return put<UInt32>(kAudioDeviceClockAlgorithmRaw,room,size,out);break;
    case kAudioDevicePropertyClockIsStable:if(id==device)return put<UInt32>(1,room,size,out);break;
    case kAudioDevicePropertyIsHidden:if(id==device)return put<UInt32>(0,room,size,out);break;
    case kAudioDevicePropertyPreferredChannelsForStereo:if(id==device&&outputScope(a))return list({1,2},room,size,out);break;
    case kAudioStreamPropertyIsActive:if(id==stream)return put<UInt32>(1,room,size,out);break;
    case kAudioStreamPropertyDirection:if(id==stream)return put<UInt32>(0,room,size,out);break;
    case kAudioStreamPropertyTerminalType:if(id==stream)return put<UInt32>(kAudioStreamTerminalTypeSpeaker,room,size,out);break;
    case kAudioStreamPropertyStartingChannel:if(id==stream)return put<UInt32>(1,room,size,out);break;
    case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:if(id==stream)return put(format(),room,size,out);break;
    case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:
      if(id==stream)return put(AudioStreamRangedDescription{format(),{32000,192000}},room,size,out);break;
    case kAudioControlPropertyScope:if(id>=volumeControl)return put<UInt32>(kAudioObjectPropertyScopeOutput,room,size,out);break;
    case kAudioControlPropertyElement:if(id>=volumeControl)return put<UInt32>(0,room,size,out);break;
    case kAudioLevelControlPropertyScalarValue:if(id==volumeControl)return put<float>(s?s->volume.load():1,room,size,out);break;
    case kAudioLevelControlPropertyDecibelValue:if(id==volumeControl)return put<float>(s?20*log10f(std::max(0.001f,s->volume.load())):0,room,size,out);break;
    case kAudioLevelControlPropertyDecibelRange:if(id==volumeControl)return put(AudioValueRange{-60,0},room,size,out);break;
    case kAudioLevelControlPropertyConvertScalarToDecibels:case kAudioLevelControlPropertyConvertDecibelsToScalar:
      if(id==volumeControl&&room>=sizeof(float)){float v;memcpy(&v,out,4);v=a->mSelector==kAudioLevelControlPropertyConvertScalarToDecibels?20*log10f(std::clamp(v,0.001f,1.f)):powf(10,std::clamp(v,-60.f,0.f)/20);return put(v,room,size,out);}break;
    case kAudioBooleanControlPropertyValue:if(id==muteControl)return put<UInt32>(s?s->muted.load():0,room,size,out);break;
  }
  return kAudioHardwareUnknownPropertyError;
}
Boolean has(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a){
  // Probe into local storage; balance CF ownership returned by GetPropertyData.
  uint8_t data[128]{};UInt32 size=0;
  auto status=get(d,id,pid,a,0,nullptr,sizeof(data),&size,data);
  if(status==noErr&&(a->mSelector==kAudioObjectPropertyName||a->mSelector==kAudioObjectPropertyManufacturer||a->mSelector==kAudioPlugInPropertyBundleID||a->mSelector==kAudioDevicePropertyDeviceUID||a->mSelector==kAudioDevicePropertyModelUID)){CFTypeRef v;memcpy(&v,data,sizeof(v));CFRelease(v);}
  return status==noErr;
}
OSStatus propertySize(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 *size){
  uint8_t data[128]{};auto status=get(d,id,pid,a,qs,q,sizeof(data),size,data);
  if(status==noErr&&(a->mSelector==kAudioObjectPropertyName||a->mSelector==kAudioObjectPropertyManufacturer||a->mSelector==kAudioPlugInPropertyBundleID||a->mSelector==kAudioDevicePropertyDeviceUID||a->mSelector==kAudioDevicePropertyModelUID)){CFTypeRef v;memcpy(&v,data,sizeof(v));CFRelease(v);}return status;
}
OSStatus settable(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,Boolean *value){
  if(!has(d,id,pid,a))return kAudioHardwareUnknownPropertyError;
  std::lock_guard<std::mutex> lock(stateMutex);
  auto s=realtime.load();*value=s&&((id==volumeControl&&(a->mSelector==kAudioLevelControlPropertyScalarValue||a->mSelector==kAudioLevelControlPropertyDecibelValue)&&s->volumeSupported.load())||(id==muteControl&&a->mSelector==kAudioBooleanControlPropertyValue&&s->muteSupported.load()));return noErr;
}
OSStatus set(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,UInt32,const void*,UInt32 size,const void *value){
  Boolean can=false;settable(d,id,pid,a,&can);if(!can)return kAudioHardwareUnsupportedOperationError;
  if(size!=4||!value)return kAudioHardwareBadPropertySizeError;
  // Serialize mapping ownership and changes; these are never real-time IO operations.
  __block OSStatus result=noErr;
  onControl(^{auto s=mapping?mapping->s:nullptr;if(!s){result=kAudioHardwareNotRunningError;return;}
    if(id==volumeControl){float v;memcpy(&v,value,4);if(!std::isfinite(v)){result=kAudioHardwareIllegalOperationError;return;}if(a->mSelector==kAudioLevelControlPropertyDecibelValue)v=powf(10,v/20);s->volume.store(std::clamp(v,0.f,1.f));}
    else {uint32_t v;memcpy(&v,value,4);s->muted.store(v?1:0);}
    s->volumeRequest.fetch_add(1,std::memory_order_release);changed(id,{a->mSelector});});return result;
}
HRESULT query(void*,REFIID uuid,LPVOID *out){
  if(!out)return E_POINTER;*out=nullptr;auto u=CFUUIDCreateFromUUIDBytes(nullptr,uuid);
  bool ok=CFEqual(u,kAudioServerPlugInDriverInterfaceUUID)||CFEqual(u,IUnknownUUID);CFRelease(u);
  if(!ok)return E_NOINTERFACE;*out=driver;refs.fetch_add(1);return S_OK;
}
OSStatus initialize(AudioServerPlugInDriverRef,AudioServerPlugInHostRef h){
  host=h;control=dispatch_queue_create("com.tc.myEq.driver.control",DISPATCH_QUEUE_SERIAL);
  dispatch_queue_set_specific(control,&controlKey,&controlKey,nullptr);
  mach_timebase_info_data_t t;mach_timebase_info(&t);ticksPerSecond=1e9*double(t.denom)/t.numer;anchor=mach_absolute_time();
  timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,control);
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC/4,NSEC_PER_MSEC*25);
  dispatch_source_set_event_handler(timer,^{
    if(!bridge)connectBridge();
    auto s=mapping?mapping->s:nullptr;setAlive(s&&s->active.load()&&now()<s->deadline.load());
  });dispatch_resume(timer);return noErr;
}
OSStatus perform(AudioServerPlugInDriverRef,AudioObjectID,UInt64,void *info){
  auto c=static_cast<Configuration*>(info);
  onControl(^{
    if(c->revision!=configurationRevision){sendReply(c->peer,c->request,"Driver configuration was superseded.");return;}
    bool nameChanged=false;
    {std::lock_guard<std::mutex> lock(stateMutex);
      realtime.store(nullptr,std::memory_order_release);mapping=c->memory;
      if(mapping){rate=mapping->acceptedRate;realtime.store(mapping->s,std::memory_order_release);}
      nameChanged=![deviceName isEqualToString:c->name];deviceName=c->name;
      anchor=mach_absolute_time();seed.fetch_add(1);clients=0;
      expectedSampleTimeValid=false;
    }
    if(nameChanged)changed(device,{kAudioObjectPropertyName});
    changed(device,{kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyControlList});
    changed(stream,{kAudioStreamPropertyVirtualFormat,kAudioStreamPropertyPhysicalFormat});
    if(c->request)sendReply(c->peer,c->request);
  });delete c;return noErr;
}
OSStatus start(AudioServerPlugInDriverRef,AudioObjectID,UInt32){
  std::lock_guard<std::mutex> lock(stateMutex);if(!alive)return kAudioHardwareNotRunningError;
  if(clients.fetch_add(1)==0){anchor=mach_absolute_time();seed.fetch_add(1);if(auto s=realtime.load()){s->discontinuities.fetch_add(1);s->sourceRunning=1;}}return noErr;
}
OSStatus stop(AudioServerPlugInDriverRef,AudioObjectID,UInt32){
  std::lock_guard<std::mutex> lock(stateMutex);if(clients&&clients.fetch_sub(1)==1){if(auto s=realtime.load())s->sourceRunning=0;}return noErr;
}
OSStatus timestamp(AudioServerPlugInDriverRef,AudioObjectID,UInt32,Float64 *sample,UInt64 *time,UInt64 *outSeed){
  auto base=anchor.load();double period=16384*ticksPerSecond/rate.load();auto n=uint64_t(double(mach_absolute_time()-base)/period);
  *sample=double(n*16384);*time=base+uint64_t(n*period);*outSeed=seed.load();return noErr;
}
OSStatus will(AudioServerPlugInDriverRef,AudioObjectID,UInt32,UInt32 op,Boolean *yes,Boolean *inPlace){*yes=op==kAudioServerPlugInIOOperationWriteMix;*inPlace=true;return noErr;}
OSStatus cycle(AudioServerPlugInDriverRef,AudioObjectID,UInt32,UInt32,UInt32,const AudioServerPlugInIOCycleInfo*){return noErr;}
OSStatus io(AudioServerPlugInDriverRef,AudioObjectID,AudioObjectID,UInt32,UInt32 op,UInt32 n,const AudioServerPlugInIOCycleInfo *cycle,void *buffer,void*){
  if(op==kAudioServerPlugInIOOperationWriteMix){
    auto s=realtime.load(std::memory_order_acquire);
    if(s&&s->active.load(std::memory_order_acquire)&&now()<s->deadline.load(std::memory_order_relaxed)&&buffer&&cycle){
      double sample=cycle->mOutputTime.mSampleTime;
      if(cycle->mOutputTime.mFlags&kAudioTimeStampSampleTimeValid){
        if(expectedSampleTimeValid&&fabs(sample-expectedSampleTime)>.5)s->discontinuities.fetch_add(1,std::memory_order_release);
        expectedSampleTime=sample+n;expectedSampleTimeValid=true;
      }
      write(s,static_cast<float*>(buffer),n,cycle->mOutputTime.mHostTime);
    }
  }return noErr;
}
void setup(){
  interface={nullptr,query,[](void*)->ULONG{return refs.fetch_add(1)+1;},[](void*)->ULONG{return refs.fetch_sub(1)-1;},initialize,
    [](AudioServerPlugInDriverRef,CFDictionaryRef,const AudioServerPlugInClientInfo*,AudioObjectID*)->OSStatus{return kAudioHardwareUnsupportedOperationError;},
    [](AudioServerPlugInDriverRef,AudioObjectID)->OSStatus{return kAudioHardwareUnsupportedOperationError;},
    [](AudioServerPlugInDriverRef,AudioObjectID,const AudioServerPlugInClientInfo*)->OSStatus{return noErr;},
    [](AudioServerPlugInDriverRef,AudioObjectID,const AudioServerPlugInClientInfo*)->OSStatus{return noErr;},perform,
    [](AudioServerPlugInDriverRef,AudioObjectID,UInt64,void *p)->OSStatus{auto c=static_cast<Configuration*>(p);if(c->request)sendReply(c->peer,c->request,"Driver configuration was aborted.",true);delete c;return noErr;},
    has,settable,propertySize,get,set,start,stop,timestamp,will,cycle,io,cycle};
}
}
extern "C" __attribute__((visibility("default"))) void *MyEqDriverCreate(CFAllocatorRef,CFUUIDRef type){
  if(!CFEqual(type,kAudioServerPlugInTypeUUID))return nullptr;
  static std::once_flag once;std::call_once(once,setup);return driver;
}
