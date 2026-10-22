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
struct MockDevice {std::string uid;bool alive;UInt32 transport;};
static std::map<UInt32,MockDevice> mockDevices;
static UInt32 media=0,alerts=0;
static OSStatus mockGet(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32,const void*,UInt32 *size,void *data){
  if(id==1){
    if(a->mSelector==kAudioHardwarePropertyDevices){for(auto &[key,value]:mockDevices){memcpy(data,&key,4);data=(char*)data+4;}return noErr;}
    UInt32 value=a->mSelector==kAudioHardwarePropertyDefaultOutputDevice?media:alerts;memcpy(data,&value,4);return noErr;
  }
  auto i=mockDevices.find(id);if(i==mockDevices.end())return kAudioHardwareBadObjectError;
  if(a->mSelector==kAudioDevicePropertyDeviceUID){CFStringRef value=CFStringCreateWithCString(nullptr,i->second.uid.c_str(),kCFStringEncodingUTF8);memcpy(data,&value,sizeof(value));return noErr;}
  UInt32 value=a->mSelector==kAudioDevicePropertyDeviceIsAlive?i->second.alive:i->second.transport;memcpy(data,&value,4);return noErr;
}
static OSStatus mockSize(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32,const void*,UInt32 *size){*size=id==1?UInt32(mockDevices.size()*4):4;return noErr;}
static OSStatus mockSet(AudioObjectID,const AudioObjectPropertyAddress *a,UInt32,const void*,UInt32,const void *data){if(a->mSelector==kAudioHardwarePropertyDefaultOutputDevice)memcpy(&media,data,4);else memcpy(&alerts,data,4);return noErr;}
#define AudioObjectGetPropertyData mockGet
#define AudioObjectGetPropertyDataSize mockSize
#define AudioObjectSetPropertyData mockSet
static CFStringRef mockConsole(SCDynamicStoreRef,uid_t *uid,gid_t*){if(uid)*uid=getuid();return CFSTR("test");}
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
  journal=[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  mockDevices={{2,{deviceUID,true,kAudioDeviceTransportTypeVirtual}},{3,{"usb",true,kAudioDeviceTransportTypeUSB}},
    {4,{"built-in",true,kAudioDeviceTransportTypeBuiltIn}},{5,{"alerts",true,kAudioDeviceTransportTypeHDMI}}};
  target="usb";oldAlerts="alerts";media=2;alerts=2;active=true;
  assert(restoreDefaults());assert(media==3&&alerts==5);
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
  media=2;alerts=2;restore();assert(media==2&&alerts==2&&!settled);
  completeRPC("deactivate",response());assert(media==2&&alerts==2);
  completeRPC("status",response());assert(media==3&&alerts==3&&!settled);
  assert(xpc_dictionary_get_uint64(pendingRPCs.front().message,"generation")==17);
  completeRPC("settled",response());assert(settled&&pendingRPCs.empty());
  reconcile();assert(pendingRPCs.empty()); // No inactive status traffic once settled.
  // An old completion cannot restore over a new session.
  settled=false;media=2;alerts=2;reconcile();++epoch;active=true;generation=18;
  completeRPC("status",response());assert(media==2&&alerts==2&&pendingRPCs.empty());
  // An active generation, malformed reply or timeout never authorizes restoration.
  active=false;generation=0;
  reconcile();completeRPC("status",response(18));assert(media==2&&alerts==2);
  reconcile();completeRPC("status",meq::message("status"));assert(media==2&&alerts==2);
  reconcile();completeRPC("status",nil);assert(media==2&&alerts==2);
  // A failed settlement acknowledgement leaves recovery pending for retry.
  reconcile();completeRPC("status",response());completeRPC("settled",nil);assert(!settled);
  reconcile();completeRPC("status",response());completeRPC("settled",response());assert(settled);
  xpc_connection_cancel(bridge);bridge=nil;
  std::cout<<"Recovery ownership and disconnect checks passed\n";
}}
