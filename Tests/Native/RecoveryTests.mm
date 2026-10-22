#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <map>
#include <string>
#include <cstring>
#include <cassert>
#include <iostream>
#import <SystemConfiguration/SystemConfiguration.h>
#include <unistd.h>
#include "IPC.hpp"
#include <deque>
struct PendingRPC { xpc_object_t message; void (^completion)(xpc_object_t); };
static std::deque<PendingRPC> pendingRPCs;
static void mockRequestAsync(xpc_connection_t,xpc_object_t message,dispatch_queue_t,double,void (^completion)(xpc_object_t)){
  pendingRPCs.push_back({message,[completion copy]});
}
#define requestAsync mockRequestAsync
struct MockDevice {std::string uid;bool alive;UInt32 transport;uint32_t frames=128;bool writable=true;double maximum=4096;bool refuse=false;};
static std::map<UInt32,MockDevice> mockDevices;
static UInt32 media=0,alerts=0;
static OSStatus mockGet(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32,const void*,UInt32 *size,void *data){
  if(id==1){
    if(a->mSelector==kAudioHardwarePropertyDevices){for(auto &[key,value]:mockDevices){memcpy(data,&key,4);data=(char*)data+4;}return noErr;}
    UInt32 value=a->mSelector==kAudioHardwarePropertyDefaultOutputDevice?media:alerts;memcpy(data,&value,4);return noErr;
  }
  auto i=mockDevices.find(id);if(i==mockDevices.end())return kAudioHardwareBadObjectError;
  if(a->mSelector==kAudioDevicePropertyDeviceUID){CFStringRef value=CFStringCreateWithCString(nullptr,i->second.uid.c_str(),kCFStringEncodingUTF8);memcpy(data,&value,sizeof(value));return noErr;}
  if(a->mSelector==kAudioDevicePropertyBufferFrameSize){memcpy(data,&i->second.frames,4);return noErr;}
  if(a->mSelector==kAudioDevicePropertyBufferFrameSizeRange){AudioValueRange range{32,i->second.maximum};memcpy(data,&range,sizeof(range));return noErr;}
  UInt32 value=a->mSelector==kAudioDevicePropertyDeviceIsAlive?i->second.alive:i->second.transport;memcpy(data,&value,4);return noErr;
}
static OSStatus mockSize(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32,const void*,UInt32 *size){*size=id==1?UInt32(mockDevices.size()*4):4;return noErr;}
static OSStatus mockSet(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32,const void*,UInt32,const void *data){if(a->mSelector==kAudioDevicePropertyBufferFrameSize){if(mockDevices[id].refuse)return kAudioHardwareIllegalOperationError;memcpy(&mockDevices[id].frames,data,4);return noErr;}if(a->mSelector==kAudioHardwarePropertyDefaultOutputDevice)memcpy(&media,data,4);else memcpy(&alerts,data,4);return noErr;}
static OSStatus mockSettable(AudioObjectID id,const AudioObjectPropertyAddress*,Boolean *value){*value=mockDevices[id].writable;return noErr;}
#define AudioObjectIsPropertySettable mockSettable
#define AudioObjectGetPropertyData mockGet
#define AudioObjectGetPropertyDataSize mockSize
#define AudioObjectSetPropertyData mockSet
static uid_t consoleUID=getuid();
static CFStringRef mockConsole(SCDynamicStoreRef,uid_t *uid,gid_t*){if(uid)*uid=consoleUID;return CFSTR("test");}
#define SCDynamicStoreCopyConsoleUser mockConsole
#define main recovery_program_main
#include "../../Helpers/Recovery.mm"
#undef main
#undef requestAsync
static xpc_object_t response(uint64_t currentGeneration=0,uint64_t retiredGeneration=17){
  auto r=meq::message("status");xpc_dictionary_set_string(r,"error","");
  xpc_dictionary_set_uint64(r,"generation",currentGeneration);xpc_dictionary_set_uint64(r,"retired",retiredGeneration);return r;
}
static void completeRPC(const char *operation,xpc_object_t result){
  assert(!pendingRPCs.empty());auto pending=pendingRPCs.front();pendingRPCs.pop_front();
  assert(meq::string(pending.message,"op")==operation);pending.completion(result);
}
int main(){@autoreleasepool{
  journal=[[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]] stringByAppendingPathComponent:@"journal.plist"];
  mockDevices={{2,{deviceUID,true,kAudioDeviceTransportTypeVirtual}},{3,{"usb",true,kAudioDeviceTransportTypeUSB}},
    {4,{"built-in",true,kAudioDeviceTransportTypeBuiltIn}},{5,{"alerts",true,kAudioDeviceTransportTypeHDMI}}};
  target="usb";oldAlerts="alerts";media=2;alerts=2;active=true;
  assert(restoreDefaults());assert(media==3&&alerts==5);
  // Buffer negotiation, unsupported hardware, rollback and external changes.
  assert(prepareBuffer(3,512,false)&&mockDevices[3].frames==512&&bufferChanges.size()==1);
  assert(restoreBuffers()&&mockDevices[3].frames==128&&bufferChanges.empty());
  mockDevices[3].frames=1024;assert(prepareBuffer(3,512,false)&&mockDevices[3].frames==1024&&bufferChanges.empty());
  mockDevices[3].frames=64;mockDevices[3].maximum=256;
  assert(prepareBuffer(3,512,false)&&mockDevices[3].frames==256);
  mockDevices[3].frames=192;assert(restoreBuffers()&&mockDevices[3].frames==192);
  mockDevices[3].maximum=4096;mockDevices[3].writable=false;
  assert(prepareBuffer(3,512,false)&&mockDevices[3].frames==192&&bufferChanges.empty());
  mockDevices[3].writable=true;mockDevices[3].refuse=true;
  assert(prepareBuffer(3,512,false)&&mockDevices[3].frames==192&&bufferChanges.empty());
  mockDevices[3].refuse=false;
  mockDevices[2].frames=1024;assert(prepareBuffer(2,512,true)&&mockDevices[2].frames==512);
  assert(restoreBuffers()&&mockDevices[2].frames==1024);
  for(uint32_t frames:{64u,128u,256u})assert(bufferRequest(frames,32,4096)==512);
  assert(bufferRequest(512,32,4096)==0&&bufferRequest(1024,32,4096)==0);
  assert(bufferRequest(128,32,300)==300&&bufferRequest(128,1024,4096)==1024);
  assert(!bufferRequest(128,32,NAN)&&!bufferRequest(128,32,8192,8192));
  // A crash must not overwrite a user's subsequent manual selection.
  media=4;alerts=5;active=true;restoreDefaults();assert(media==4&&alerts==5);
  // A missing physical target cannot be restored; choose an available physical fallback.
  media=2;alerts=2;mockDevices[3].alive=false;restoreDefaults();assert(media==4&&alerts==5);
  // Existing platform fallback wins over a different still-connected saved target.
  media=4;alerts=2;mockDevices[3].alive=true;restoreDefaults();assert(media==4&&alerts==5);
  // Missing alert output falls back to the selected media hardware.
  media=2;alerts=2;mockDevices[5].alive=false;restoreDefaults();assert(media==3&&alerts==3);
  // Recovery must wait for authenticated bridge retirement before touching defaults.
  bridge=xpc_connection_create(nullptr,nullptr);xpc_connection_set_event_handler(bridge,^(xpc_object_t){});xpc_connection_resume(bridge);
  bridgeReady=true;active=true;generation=17;
  media=2;alerts=2;beginActivity();assert(activity);restore();assert(activity);assert(media==2&&alerts==2&&!settled);
  completeRPC("deactivate",response());assert(media==2&&alerts==2);
  completeRPC("status",response());assert(media==3&&alerts==3&&!settled);
  assert(xpc_dictionary_get_uint64(pendingRPCs.front().message,"generation")==17);
  completeRPC("settled",response());assert(settled&&pendingRPCs.empty()&&!activity);
  reconcile();assert(pendingRPCs.empty()); // No inactive status traffic once settled.
  // An old completion cannot restore over a new session.
  settled=false;media=2;alerts=2;reconcile();++epoch;active=true;generation=18;
  completeRPC("status",response());assert(media==2&&alerts==2&&pendingRPCs.empty()&&checking);
  // An active generation, malformed reply or timeout never authorizes restoration.
  active=false;generation=0;checking=false;
  reconcile();completeRPC("status",response(18));assert(media==2&&alerts==2);
  reconcile();completeRPC("status",meq::message("status"));assert(media==2&&alerts==2);
  reconcile();completeRPC("status",nil);assert(media==2&&alerts==2);
  // A failed settlement acknowledgement leaves recovery pending for retry.
  reconcile();completeRPC("status",response());completeRPC("settled",nil);assert(!settled);
  reconcile();completeRPC("status",response());completeRPC("settled",response());assert(settled);
  // A failed open before prepare/activate still needs bridge retirement settlement.
  assert(settled&&generation==0);handleRetired(17);
  completeRPC("status",response());completeRPC("settled",response());assert(settled);
  generation=18;handleRetired(17);assert(pendingRPCs.empty()&&generation==18);generation=0;
  // A different console user cannot restore this user's routes.
  consoleUID=getuid()+1;media=2;alerts=2;
  assert(!foregroundSelf()&&!restoreDefaults()&&media==2&&alerts==2);
  beginActivity();active=true;generation=19;tick();assert(!active&&!activity);
  pendingRPCs.clear();consoleUID=getuid();
  // Losing ownership during activation releases the activity and invalidates late completion.
  beginActivity();activating=true;generation=20;auto oldEpoch=epoch;
  finishActivation(nullptr,nil,oldEpoch,now());
  assert(!activating&&!activity&&epoch!=oldEpoch);pendingRPCs.clear();
  // A late heartbeat completion cannot clear a replacement session's pending request.
  app=xpc_connection_create(nullptr,nullptr);xpc_connection_set_event_handler(app,^(xpc_object_t){});xpc_connection_resume(app);
  active=true;activating=false;generation=21;media=2;heartbeatPending=false;routePollPending=true;bridgeLastReply=now();tick();
  assert(heartbeatPending&&pendingRPCs.size()==1);++epoch;
  completeRPC("heartbeat",nil);assert(heartbeatPending&&active&&generation==21);
  heartbeatPending=false;active=false;generation=0;xpc_connection_cancel(app);app=nil;
  // Idempotent acquisition/release and same-owner lock do not manufacture new activity tokens.
  beginActivity();id original=activity;beginActivity();assert(activity==original);
  endActivity();endActivity();assert(!activity);
  // A stalled HAL worker does not stop repeated lease RPCs on the state queue.
  queue=dispatch_queue_create("test.recovery.state",DISPATCH_QUEUE_SERIAL);
  halQueue=dispatch_queue_create("test.recovery.hal",DISPATCH_QUEUE_SERIAL);
  auto gate=dispatch_semaphore_create(0);
  dispatch_async(halQueue,^{dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER);});
  app=xpc_connection_create(nullptr,nullptr);xpc_connection_set_event_handler(app,^(xpc_object_t){});xpc_connection_resume(app);
  active=true;generation=22;media=2;routePollPending=false;heartbeatPending=false;bridgeLastReply=now();
  dispatch_sync(queue,^{
    tick();assert(routePollPending&&heartbeatPending);completeRPC("heartbeat",response());
    tick();assert(routePollPending&&heartbeatPending);completeRPC("heartbeat",nil);
    assert(active&&!heartbeatPending); // one 500ms deadline is not peer death
    bridgeLastReply=now()-recoveryHealthNS;
    tick();completeRPC("heartbeat",nil);assert(!active);
    pendingRPCs.clear();++epoch; // old HAL completion cannot affect replacement state
  });
  dispatch_semaphore_signal(gate);dispatch_sync(halQueue,^{});dispatch_sync(queue,^{});
  assert(!active&&pendingRPCs.empty());
  xpc_connection_cancel(app);app=nil;
  xpc_connection_cancel(bridge);bridge=nil;
  [[NSFileManager defaultManager] removeItemAtPath:journal.stringByDeletingLastPathComponent error:nil];
  std::cout<<"Recovery ownership and disconnect checks passed\n";
}}
