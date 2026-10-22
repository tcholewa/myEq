#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <map>
#include <string>
#include <cstring>
#include <cassert>
#include <iostream>
#import <SystemConfiguration/SystemConfiguration.h>
#include <unistd.h>
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
  std::cout<<"Recovery ownership and disconnect checks passed\n";
}}
