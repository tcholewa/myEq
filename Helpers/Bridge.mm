#include "IPC.hpp"
#import <SystemConfiguration/SystemConfiguration.h>

using namespace meq;
namespace {
dispatch_queue_t queue;
xpc_connection_t driverPeer,appPeer,recoveryPeer;
std::shared_ptr<Mapping> memory;
uint64_t appBeat=0,recoveryBeat=0,lastRender=0,renderChanged=0;

void revoke(){
  if(!memory)return;
  memory->s->active=0;memory->s->deadline=0;memory.reset();
  if(driverPeer)xpc_connection_send_message(driverPeer,message("detach"));
}
bool foreground(xpc_connection_t c){
  uid_t uid=0;auto user=SCDynamicStoreCopyConsoleUser(nullptr,&uid,nullptr);if(user)CFRelease(user);
  return uid>=500&&xpc_connection_get_euid(c)==uid;
}
void refresh(){
  if(driverPeer)xpc_connection_send_message(driverPeer,message("refresh"));
}
void handle(xpc_connection_t c,const std::string &role,xpc_object_t m){
  auto op=string(m,"op");
  if(op=="open"&&role=="app"){
    if(c!=appPeer||!foreground(c)){reply(c,m,"Only the active myEq app may open audio.");return;}
    if(!driverPeer||!recoveryPeer){reply(c,m,"Waiting for the audio driver and recovery helper.",true);return;}
    if(xpc_connection_get_euid(c)!=xpc_connection_get_euid(recoveryPeer)||xpc_connection_get_asid(c)!=xpc_connection_get_asid(recoveryPeer)){
      reply(c,m,"The recovery helper belongs to a different login session.");return;
    }
    if(memory){reply(c,m,"An audio session is already open.");return;}
    double rate=xpc_dictionary_get_double(m,"rate");
    if(!std::isfinite(rate)||rate<32000||rate>192000){reply(c,m,"Unsupported sample rate.");return;}
    auto next=std::make_shared<Mapping>();uint64_t generation;arc4random_buf(&generation,sizeof(generation));
    if(!next->create(rate,generation?generation:1)){reply(c,m,"Cannot allocate audio transport.");return;}
    auto attach=message("attach");xpc_dictionary_set_value(attach,"memory",next->object);
    if(auto name=xpc_dictionary_get_string(m,"outputName"))xpc_dictionary_set_string(attach,"outputName",name);
    auto result=request(driverPeer,attach);
    if(!succeeded(result)){reply(c,m,error(result).c_str(),retryable(result));return;}
    memory=next;appBeat=now();renderChanged=appBeat;lastRender=0;
    auto r=xpc_dictionary_create_reply(m);xpc_dictionary_set_uint64(r,"version",protocol);
    xpc_dictionary_set_value(r,"memory",next->object);xpc_connection_send_message(c,r);return;
  }
  if(op=="activate"&&role=="recovery"){
    if(!memory||!appPeer||!foreground(appPeer)||now()-appBeat>2*NSEC_PER_SEC){reply(c,m,"Audio renderer is not ready.");return;}
    auto s=memory->s;
    if(!s->rendered.load()){reply(c,m,"Physical output has not started.");return;}
    recoveryBeat=now();s->deadline=now()+2*NSEC_PER_SEC;s->active=1;renderChanged=now();lastRender=s->rendered.load();
    refresh();reply(c,m);return;
  }
  if(op=="heartbeat"&&(role=="app"||role=="recovery")){
    if(role=="app")appBeat=now();else recoveryBeat=now();
    if(memory&&memory->s->active){
      auto rendered=memory->s->rendered.load();if(rendered!=lastRender){lastRender=rendered;renderChanged=now();}
      if(!appPeer||!foreground(appPeer)||now()-appBeat>1500*NSEC_PER_MSEC||now()-recoveryBeat>1500*NSEC_PER_MSEC||now()-renderChanged>1500*NSEC_PER_MSEC){revoke();reply(c,m,"Audio session stopped; ordinary playback is being restored.");return;}
      memory->s->deadline=now()+2*NSEC_PER_SEC;
    }
    if(role=="app"&&!memory){reply(c,m,"Audio transport disconnected. Retry to reconnect.");return;}
    reply(c,m);return;
  }
  if((op=="close"||op=="deactivate")&&(role=="app"||role=="recovery")){revoke();reply(c,m);return;}
  reply(c,m,"Unknown bridge operation.");
}
}
int main(){@autoreleasepool{
  queue=dispatch_queue_create("com.tc.myEq.bridge",DISPATCH_QUEUE_SERIAL);
  auto listener=xpc_connection_create_mach_service(bridgeService,queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);
  xpc_connection_set_event_handler(listener,^(xpc_object_t object){
    auto c=(xpc_connection_t)object;
    __block std::string role;__block bool ready=false;
    xpc_connection_set_event_handler(c,^(xpc_object_t m){
      if(xpc_get_type(m)==XPC_TYPE_ERROR){
        if(c==driverPeer){driverPeer=nil;revoke();}
        if(c==appPeer){appPeer=nil;revoke();}
        if(c==recoveryPeer){recoveryPeer=nil;revoke();}return;
      }
      if(!isMessage(m)){reply(c,m,"Protocol mismatch.");return;}
      if(role.empty()){
        if(string(m,"op")!="hello"){xpc_connection_cancel(c);return;}
        auto claimed=string(m,"role");std::string req;
        if(claimed=="driver")req="anchor apple and (identifier \"com.apple.audio.DriverHelper\" or identifier \"com.apple.audio.Core-Audio-Driver-Service\" or identifier \"com.apple.audio.Core-Audio-Driver-Service.helper\")";
        else if(claimed=="app")req=requirement(@"app");
        else if(claimed=="recovery")req=requirement(@"recovery");
        if(!constrain(c,req)){xpc_connection_cancel(c);return;}
        role=claimed;reply(c,m);return;
      }
      // The second request is checked by the XPC runtime against the signing requirement.
      if(!ready){
        if(string(m,"op")!="ready"){xpc_connection_cancel(c);return;}
        if(role!="driver"&&!foreground(c)){reply(c,m,"Only the active console user may connect.");return;}
        auto existing=role=="driver"?driverPeer:role=="app"?appPeer:recoveryPeer;
        if(existing&&existing!=c){
          if(xpc_connection_get_pid(existing)!=xpc_connection_get_pid(c)&&(role=="driver"||foreground(existing))){reply(c,m,"Another instance is connected.");return;}
          revoke();xpc_connection_cancel(existing);
        }
        if(role=="driver")driverPeer=c;else if(role=="app")appPeer=c;else recoveryPeer=c;
        ready=true;reply(c,m);return;
      }
      handle(c,role,m);
    });xpc_connection_resume(c);
  });xpc_connection_resume(listener);
  auto timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC/4,NSEC_PER_MSEC*25);
  dispatch_source_set_event_handler(timer,^{if(memory&&memory->s->active&&
    (now()-appBeat>1500*NSEC_PER_MSEC||now()-recoveryBeat>1500*NSEC_PER_MSEC||!appPeer||!foreground(appPeer)))revoke();});
  dispatch_resume(timer);dispatch_main();
}}
