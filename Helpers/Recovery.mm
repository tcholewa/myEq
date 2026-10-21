#include "IPC.hpp"
#import <CoreAudio/CoreAudio.h>
#import <AppKit/AppKit.h>
#import <SystemConfiguration/SystemConfiguration.h>

using namespace meq;
namespace {
dispatch_queue_t queue;
xpc_connection_t bridge,app;
bool active=false;
int reason=0;
std::string target,oldAlerts;
NSString *journal;
AudioObjectPropertyAddress address(AudioObjectPropertySelector s,AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal){return {s,scope,0};}
template<class T>T scalar(AudioObjectID id,AudioObjectPropertySelector s,T initial,AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal){auto a=address(s,scope);UInt32 n=sizeof(T);AudioObjectGetPropertyData(id,&a,0,nullptr,&n,&initial);return initial;}
std::string uid(AudioObjectID id){auto a=address(kAudioDevicePropertyDeviceUID);CFStringRef v=nullptr;UInt32 n=sizeof(v);if(AudioObjectGetPropertyData(id,&a,0,nullptr,&n,&v)||!v)return "";std::string result=[(__bridge NSString*)v UTF8String];CFRelease(v);return result;}
std::vector<AudioObjectID> devices(){auto a=address(kAudioHardwarePropertyDevices);UInt32 n=0;if(AudioObjectGetPropertyDataSize(1,&a,0,nullptr,&n))return {};std::vector<AudioObjectID> ids(n/4);if(n&&AudioObjectGetPropertyData(1,&a,0,nullptr,&n,ids.data()))return {};return ids;}
AudioObjectID find(const std::string &value){for(auto id:devices())if(uid(id)==value)return id;return 0;}
bool live(AudioObjectID id){return id&&scalar(id,kAudioDevicePropertyDeviceIsAlive,UInt32(0));}
bool physical(AudioObjectID id){
  if(!live(id))return false;auto t=scalar(id,kAudioDevicePropertyTransportType,UInt32(0));
  bool transport=t==kAudioDeviceTransportTypeBuiltIn||t==kAudioDeviceTransportTypeUSB||t==kAudioDeviceTransportTypeHDMI||t==kAudioDeviceTransportTypeDisplayPort||t==kAudioDeviceTransportTypeThunderbolt||t==kAudioDeviceTransportTypePCI||t==kAudioDeviceTransportTypeBluetooth||t==kAudioDeviceTransportTypeBluetoothLE;
  auto a=address(kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput);UInt32 n=0;
  return transport&&AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&n)==noErr&&n>0;
}
AudioObjectID current(AudioObjectPropertySelector s){return scalar(1,s,AudioObjectID(0));}
bool setDefault(AudioObjectPropertySelector s,AudioObjectID id){if(!id)return false;auto a=address(s);return AudioObjectSetPropertyData(1,&a,0,nullptr,4,&id)==noErr;}
AudioObjectID fallback(){
  auto selected=current(kAudioHardwarePropertyDefaultOutputDevice);if(physical(selected))return selected;
  auto all=devices();for(auto id:all)if(physical(id)&&scalar(id,kAudioDevicePropertyTransportType,UInt32(0))==kAudioDeviceTransportTypeBuiltIn)return id;
  for(auto id:all)if(physical(id))return id;return 0;
}
bool connectBridge(){
  if(bridge)return true;
  auto c=xpc_connection_create_mach_service(bridgeService,queue,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
  if(!constrain(c,requirement(@"bridge"))){xpc_connection_cancel(c);return false;}
  bridge=c;
  xpc_connection_set_event_handler(c,^(xpc_object_t m){if(xpc_get_type(m)==XPC_TYPE_ERROR&&bridge==c)bridge=nil;});
  xpc_connection_resume(c);if(!handshake(c,"recovery")){xpc_connection_cancel(c);bridge=nil;return false;}return true;
}
void restore(){
  // Only properties still pointing at our virtual device are ours to restore.
  AudioObjectID physicalTarget=find(target);if(!physical(physicalTarget))physicalTarget=fallback();
  if(uid(current(kAudioHardwarePropertyDefaultOutputDevice))==deviceUID)setDefault(kAudioHardwarePropertyDefaultOutputDevice,physicalTarget);
  if(uid(current(kAudioHardwarePropertyDefaultSystemOutputDevice))==deviceUID){
    auto alerts=find(oldAlerts);setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice,live(alerts)?alerts:physicalTarget);
  }
  active=false;
  if(bridge)request(bridge,message("deactivate"),0.5);
  // Keep the journal if no output is available; retry restoration on the next device appearance.
  if(uid(current(kAudioHardwarePropertyDefaultOutputDevice))!=deviceUID&&uid(current(kAudioHardwarePropertyDefaultSystemOutputDevice))!=deviceUID)
    [[NSFileManager defaultManager] removeItemAtPath:journal error:nil];
}
bool saveJournal(){
  NSError *error=nil;NSString *folder=[journal stringByDeletingLastPathComponent];
  [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
  if(error)return false;
  NSDictionary *data=@{@"target":@(target.c_str()),@"alerts":@(oldAlerts.c_str()),@"schema":@1};
  return [data writeToFile:journal atomically:YES];
}
std::string activate(const std::string &destination,bool &canRetry){
  if(active)restore();
  auto selected=find(destination),virtualID=find(deviceUID);
  if(!physical(selected)||!virtualID)return "Select a connected physical audio output.";
  target=destination;oldAlerts=uid(current(kAudioHardwarePropertyDefaultSystemOutputDevice));
  if(oldAlerts==deviceUID)oldAlerts=target;
  if(!saveJournal())return "Cannot save the audio recovery journal. Playback was not redirected.";
  if(!connectBridge())return "The audio bridge is unavailable. Reinstall this build.";
  auto result=request(bridge,message("activate"));if(!succeeded(result)){canRetry=retryable(result);return error(result);}
  // The driver publishes alive on its control queue; wait outside real-time IO.
  for(int i=0;i<100&&!live(virtualID);++i)usleep(10000);
  if(!live(virtualID)||!setDefault(kAudioHardwarePropertyDefaultOutputDevice,virtualID)||!setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice,virtualID)){
    restore();return "macOS could not select the virtual output. Ordinary playback was restored.";
  }
  active=true;reason=0;return "";
}
void tick(){
  if(!bridge)connectBridge();
  if(active){
    uid_t console=0;auto user=SCDynamicStoreCopyConsoleUser(nullptr,&console,nullptr);if(user)CFRelease(user);
    if(console!=getuid()||!app){reason=1;restore();return;}
    if(!physical(find(target))){reason=3;restore();return;}
    if(uid(current(kAudioHardwarePropertyDefaultOutputDevice))!=deviceUID){reason=2;restore();return;}
    auto r=request(bridge,message("heartbeat"),0.5);if(!succeeded(r)){reason=1;restore();return;}
  }else if([[NSFileManager defaultManager] fileExistsAtPath:journal])restore();
}
}
int main(int argc,const char **argv){@autoreleasepool{
  journal=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/myEq/route-recovery.plist"];
  NSDictionary *prior=[NSDictionary dictionaryWithContentsOfFile:journal];
  if([prior[@"target"] isKindOfClass:NSString.class])target=[prior[@"target"] UTF8String];
  if([prior[@"alerts"] isKindOfClass:NSString.class])oldAlerts=[prior[@"alerts"] UTF8String];
  if(argc==2&&strcmp(argv[1],"--restore")==0){restore();return 0;}
  queue=dispatch_queue_create("com.tc.myEq.recovery",DISPATCH_QUEUE_SERIAL);
  auto listener=xpc_connection_create_mach_service(recoveryService,queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);
  xpc_connection_set_event_handler(listener,^(xpc_object_t object){
    auto c=(xpc_connection_t)object;__block bool challenged=false,ready=false;
    xpc_connection_set_event_handler(c,^(xpc_object_t m){
      if(xpc_get_type(m)==XPC_TYPE_ERROR){if(app==c){app=nil;reason=1;restore();}return;}
      if(!isMessage(m)){reply(c,m,"Protocol mismatch.");return;}
      if(!challenged){if(string(m,"op")!="hello"||!constrain(c,requirement(@"app"))){xpc_connection_cancel(c);return;}challenged=true;reply(c,m);return;}
      if(!ready){
        if(string(m,"op")!="ready"||xpc_connection_get_euid(c)!=getuid()||(app&&xpc_connection_get_pid(app)!=xpc_connection_get_pid(c))){reply(c,m,"Another myEq instance is connected.");return;}
        if(app){restore();xpc_connection_cancel(app);}
        app=c;ready=true;reply(c,m);return;
      }
      auto op=string(m,"op");
      if(op=="activate"){bool canRetry=false;auto e=activate(string(m,"uid"),canRetry);reply(c,m,e.c_str(),canRetry);}
      else if(op=="restore"){reason=0;restore();reply(c,m);}
      else if(op=="status"){
        auto r=xpc_dictionary_create_reply(m);xpc_dictionary_set_uint64(r,"version",protocol);
        xpc_dictionary_set_int64(r,"reason",reason);xpc_dictionary_set_bool(r,"active",active);xpc_connection_send_message(c,r);
      }else reply(c,m,"Unknown recovery operation.");
    });xpc_connection_resume(c);
  });xpc_connection_resume(listener);
  auto timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC/4,NSEC_PER_MSEC*25);
  dispatch_source_set_event_handler(timer,^{tick();});dispatch_resume(timer);
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil usingBlock:^(NSNotification*){dispatch_async(queue,^{reason=1;restore();});}];
  [[NSRunLoop currentRunLoop] run];
  return 0;
}}
