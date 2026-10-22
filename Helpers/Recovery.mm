#include "IPC.hpp"
#import <CoreAudio/CoreAudio.h>
#import <AppKit/AppKit.h>
#import <SystemConfiguration/SystemConfiguration.h>

using namespace meq;
namespace {
dispatch_queue_t queue;
xpc_connection_t bridge,app;
bool settled=false;
xpc_connection_t restorePeer; xpc_object_t restoreResponse;
bool active=false,activating=false,bridgeReady=false,connecting=false,checking=false,heartbeatPending=false;
int reason=0;
bool recoveryRetryable=false;
id activity;
void beginActivity(){if(!activity)activity=[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Maintaining system audio recovery"];}
void endActivity(){if(activity){[[NSProcessInfo processInfo] endActivity:activity];activity=nil;}}
uint64_t generation=0,epoch=0;
std::string target,oldAlerts;
NSString *journal;
size_t pendingPeers=0;
bool foregroundSelf(){uid_t uid=0;auto user=SCDynamicStoreCopyConsoleUser(nullptr,&uid,nullptr);if(user)CFRelease(user);return uid==getuid()&&uid>=500;}
bool owner(xpc_connection_t c){return c&&c==app&&foregroundSelf()&&xpc_connection_get_euid(c)==getuid()&&xpc_connection_get_asid(c)==auditSession();}
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

// Only a bridge-authorized, settled recovery transaction calls this routine.
// The bridge blocks new opens until we acknowledge completion.
bool restoreDefaults(){
  if(!foregroundSelf())return false;
  AudioObjectID physicalTarget=find(target);if(!physical(physicalTarget))physicalTarget=fallback();
  if(uid(current(kAudioHardwarePropertyDefaultOutputDevice))==deviceUID)setDefault(kAudioHardwarePropertyDefaultOutputDevice,physicalTarget);
  if(uid(current(kAudioHardwarePropertyDefaultSystemOutputDevice))==deviceUID){
    auto alerts=find(oldAlerts);setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice,physical(alerts)?alerts:physicalTarget);
  }
  bool restored=uid(current(kAudioHardwarePropertyDefaultOutputDevice))!=deviceUID&&uid(current(kAudioHardwarePropertyDefaultSystemOutputDevice))!=deviceUID;
  if(restored)[[NSFileManager defaultManager] removeItemAtPath:journal error:nil];
  return restored;
}
void reconcile();
void restore(){
  NSLog(@"myEq: recovery restore reason=%d retryable=%d",reason,recoveryRetryable);
  const auto old=generation;settled=false;++epoch;active=false;activating=false;checking=false;heartbeatPending=false;generation=0;
  if(bridgeReady&&old){auto c=bridge;requestAsync(c,sessionMessage("deactivate",old),queue,0.5,^(xpc_object_t){if(c==bridge)reconcile();});}
  else reconcile();
}
bool saveJournal(){
  NSDictionary *data=@{@"target":@(target.c_str()),@"alerts":@(oldAlerts.c_str()),@"schema":@2,
    @"uid":@(getuid()),@"asid":@(auditSession()),@"generation":@(generation)};
  NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:data format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  return privateWrite(journal,encoded,16*1024);
}
void reconcile(){
  if(settled||active||activating||checking||!bridgeReady||!foregroundSelf())return;
  checking=true;const auto attempt=epoch;auto c=bridge;
  requestAsync(c,message("status"),queue,0.5,^(xpc_object_t r){
    if(c!=bridge||attempt!=epoch)return;checking=false;
    if(active||activating||!foregroundSelf()||!succeeded(r))return;
    auto g=xpc_dictionary_get_value(r,"generation"),retired=xpc_dictionary_get_value(r,"retired");
    if(!g||!retired||xpc_get_type(g)!=XPC_TYPE_UINT64||xpc_get_type(retired)!=XPC_TYPE_UINT64||xpc_uint64_get_value(g))return;
    if(!restoreDefaults())return;
    // No new open can pass until this acknowledgement is handled by the bridge.
    requestAsync(c,sessionMessage("settled",xpc_uint64_get_value(retired)),queue,0.5,^(xpc_object_t result){
      if(c!=bridge||attempt!=epoch)return;
      if(succeeded(result)){settled=true;endActivity();sendReply(restorePeer,restoreResponse);restorePeer=nil;restoreResponse=nil;}
    });
  });
}
void connectBridge(){
  if(bridge||connecting||!foregroundSelf())return;connecting=true;
  auto c=xpc_connection_create_mach_service(bridgeService,queue,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
  if(!constrain(c,requirement(@"bridge"))){xpc_connection_cancel(c);connecting=false;return;}
  bridge=c;
  xpc_connection_set_event_handler(c,^(xpc_object_t m){if(xpc_get_type(m)==XPC_TYPE_ERROR&&bridge==c){
    NSLog(@"myEq: recovery bridge event: %s",error(m).c_str());
    recoveryRetryable=retryable(m);reason=1;endActivity();
    bridge=nil;bridgeReady=false;settled=false;connecting=false;checking=false;heartbeatPending=false;++epoch;active=false;activating=false;generation=0;
  }});
  xpc_connection_resume(c);auto hello=message("hello");xpc_dictionary_set_string(hello,"role","recovery");
  requestAsync(c,hello,queue,1,^(xpc_object_t r){
    if(c!=bridge)return;if(!succeeded(r)){xpc_connection_cancel(c);bridge=nil;connecting=false;return;}
    requestAsync(c,message("ready"),queue,1,^(xpc_object_t result){
      if(c!=bridge)return;connecting=false;
      if(!succeeded(result)){xpc_connection_cancel(c);bridge=nil;return;}
      bridgeReady=true;reconcile();
    });
  });
}
void finishActivation(xpc_connection_t c,xpc_object_t response,uint64_t attempt,uint64_t deadline){
  if(attempt!=epoch||!owner(c)||!activating){
    if(attempt==epoch&&activating){reason=1;recoveryRetryable=false;restore();endActivity();}
    sendReply(c,response,"Audio activation was superseded.");return;
  }
  auto virtualID=find(deviceUID);
  if(!live(virtualID)&&now()<deadline){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC),queue,^{finishActivation(c,response,attempt,deadline);});return;}
  if(!live(virtualID)||!setDefault(kAudioHardwarePropertyDefaultOutputDevice,virtualID)||!setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice,virtualID)){
    restore();sendReply(c,response,"macOS could not select the virtual output. Playback is being restored.",true);return;
  }
  active=true;activating=false;reason=0;recoveryRetryable=false;sendReply(c,response);
}
void activate(xpc_connection_t c,xpc_object_t m,xpc_object_t response){
  if(active||activating||checking){sendReply(c,response,"Audio recovery is busy.",true);return;}
  if(!bridgeReady){sendReply(c,response,"Audio bridge is reconnecting.",true);return;}
  auto destination=string(m,"uid");auto selected=find(destination),virtualID=find(deviceUID);
  if(!physical(selected)||!virtualID){sendReply(c,response,"Select a connected physical audio output.");return;}
  generation=xpc_dictionary_get_uint64(m,"generation");target=destination;
  oldAlerts=uid(current(kAudioHardwarePropertyDefaultSystemOutputDevice));if(oldAlerts==deviceUID)oldAlerts=target;
  if(!saveJournal()){generation=0;sendReply(c,response,"Cannot save the audio recovery journal. Playback was not redirected.");return;}
  beginActivity();settled=false;activating=true;const auto attempt=++epoch;auto expectedBridge=bridge;
  requestAsync(bridge,sessionMessage("activate",generation),queue,1,^(xpc_object_t result){
    if(attempt!=epoch||expectedBridge!=bridge||!owner(c)){
      if(attempt==epoch&&activating){reason=1;recoveryRetryable=false;restore();endActivity();}
      sendReply(c,response,"Audio activation was superseded.");return;
    }
    if(!succeeded(result)){restore();sendReply(c,response,error(result).c_str(),retryable(result));return;}
    finishActivation(c,response,attempt,now()+NSEC_PER_SEC);
  });
}
void tick(){
  if(!foregroundSelf()){
    if(active||activating){reason=1;recoveryRetryable=false;restore();}
    endActivity();return;
  }
  if(!bridge)connectBridge();
  if((active||activating)&&!app){reason=1;recoveryRetryable=true;restore();return;}
  if(active){
    if(!physical(find(target))){reason=3;restore();return;}
    if(uid(current(kAudioHardwarePropertyDefaultOutputDevice))!=deviceUID){reason=2;restore();return;}
    if(!heartbeatPending&&bridgeReady){heartbeatPending=true;const auto attempt=epoch;auto c=bridge;
      requestAsync(c,sessionMessage("heartbeat",generation),queue,0.5,^(xpc_object_t r){
        if(c!=bridge||attempt!=epoch)return;heartbeatPending=false;if(!succeeded(r)){reason=1;recoveryRetryable=retryable(r);restore();}
      });
    }
  }else reconcile();
}
struct Peer{bool challenged=false,ready=false,pending=true;};
void finishPending(const std::shared_ptr<Peer>& p){if(p->pending){p->pending=false;--pendingPeers;}}
void acceptPeer(xpc_connection_t c){
  if(pendingPeers>=32){xpc_connection_cancel(c);return;}++pendingPeers;auto p=std::make_shared<Peer>();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),queue,^{if(!p->ready){finishPending(p);xpc_connection_cancel(c);}});
  xpc_connection_set_event_handler(c,^(xpc_object_t m){
    if(xpc_get_type(m)==XPC_TYPE_ERROR){finishPending(p);if(app==c){app=nil;reason=1;recoveryRetryable=retryable(m);restore();}return;}
    if(!p->pending&&!p->ready){xpc_connection_cancel(c);return;}
    auto r=replyMessage(m);if(!r){finishPending(p);xpc_connection_cancel(c);return;}
    if(!isMessage(m)){sendReply(c,r,"Protocol mismatch.");finishPending(p);xpc_connection_cancel(c);return;}
    if(!p->challenged){
      if(!schema(m,"hello",{{"role",XPC_TYPE_STRING,32}})||string(m,"role")!="app"||!constrain(c,requirement(@"app"))){finishPending(p);xpc_connection_cancel(c);return;}
      p->challenged=true;sendReply(c,r);return;
    }
    if(!p->ready){
      if(!schema(m,"ready")||!foregroundSelf()||xpc_connection_get_euid(c)!=getuid()||xpc_connection_get_asid(c)!=auditSession()){
        sendReply(c,r,"Another myEq instance or login session is connected.");finishPending(p);xpc_connection_cancel(c);return;
      }
      if(app){sendReply(c,r,"Another myEq instance is connected.",true);finishPending(p);xpc_connection_cancel(c);return;}
      app=c;p->ready=true;finishPending(p);sendReply(c,r);return;
    }
    if(!owner(c)){sendReply(c,r,"This connection no longer owns the session.");return;}
    auto op=string(m,"op");
    if(op=="activate"&&schema(m,"activate",{{"generation",XPC_TYPE_UINT64},{"uid",XPC_TYPE_STRING,1024}})&&xpc_dictionary_get_uint64(m,"generation"))activate(c,m,r);
    else if(op=="restore"&&sessionSchema(m,"restore")&&xpc_dictionary_get_uint64(m,"generation")==generation){reason=0;restorePeer=c;restoreResponse=r;restore();}
    else if(op=="status"&&sessionSchema(m,"status")){
      auto requested=xpc_dictionary_get_uint64(m,"generation");
      if(generation&&requested!=generation){sendReply(c,r,"Invalid or stale audio session.");return;}
      xpc_dictionary_set_int64(r,"reason",reason);xpc_dictionary_set_bool(r,"active",active);sendReply(c,r,"",reason==1&&recoveryRetryable);
    }else {sendReply(c,r,"Invalid recovery operation or session.");xpc_connection_cancel(c);}
  });xpc_connection_resume(c);
}
}
int main(int argc,const char **argv){@autoreleasepool{
  journal=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/myEq/route-recovery.plist"];
  NSDictionary *prior=readPlist(journal.fileSystemRepresentation,16*1024,getuid());
  // Legacy journals contain routing data only; they never authorize an active session.
  bool validSchema=[prior[@"schema"] isKindOfClass:NSNumber.class]&&([prior[@"schema"] intValue]==1||[prior[@"schema"] intValue]==2);
  if(validSchema&&([prior[@"schema"] intValue]==1||([prior[@"uid"] isKindOfClass:NSNumber.class]&&[prior[@"uid"] unsignedIntValue]==getuid()))){
    if([prior[@"target"] isKindOfClass:NSString.class]&&[prior[@"target"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=1024)target=[prior[@"target"] UTF8String];
    if([prior[@"alerts"] isKindOfClass:NSString.class]&&[prior[@"alerts"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=1024)oldAlerts=[prior[@"alerts"] UTF8String];
  }
  // Installer invokes a verified, privately staged copy after quiescing the app.
  if(argc==2&&strcmp(argv[1],"--restore")==0)return restoreDefaults()?0:1;
  queue=dispatch_queue_create("com.tc.myEq.recovery",DISPATCH_QUEUE_SERIAL);
  auto listener=xpc_connection_create_mach_service(recoveryService,queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);
  xpc_connection_set_event_handler(listener,^(xpc_object_t o){if(xpc_get_type(o)==XPC_TYPE_CONNECTION)acceptPeer((xpc_connection_t)o);});xpc_connection_resume(listener);
  auto timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC/4,NSEC_PER_MSEC*25);
  dispatch_source_set_event_handler(timer,^{tick();});dispatch_resume(timer);
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil usingBlock:^(NSNotification*){dispatch_async(queue,^{reason=1;recoveryRetryable=true;restore();endActivity();});}];
  [[NSRunLoop currentRunLoop] run];return 0;
}}
