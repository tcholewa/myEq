#include "IPC.hpp"
#import <SystemConfiguration/SystemConfiguration.h>

using namespace meq;
namespace {
dispatch_queue_t queue;
xpc_connection_t driverPeer,appPeer,recoveryPeer;
std::shared_ptr<Mapping> memory;
uint64_t generation=0,appBeat=0,recoveryBeat=0,lastRender=0,renderChanged=0;
bool sessionActive=false,recoveryAvailable=false;
uint64_t retiredGeneration=0;
size_t pendingPeers=0;
struct Peer { std::string role;bool ready=false,pending=true; };
void finishPending(const std::shared_ptr<Peer>& p){if(p->pending){p->pending=false;--pendingPeers;}}
bool foreground(xpc_connection_t c){
  if(!c)return false;
  uid_t uid=0;auto user=SCDynamicStoreCopyConsoleUser(nullptr,&uid,nullptr);if(user)CFRelease(user);
  return uid>=500&&xpc_connection_get_euid(c)==uid;
}
bool owner(xpc_connection_t c,const std::string &role){
  return c&&c==(role=="app"?appPeer:role=="recovery"?recoveryPeer:nullptr)&&foreground(c);
}
bool paired(){return appPeer&&recoveryPeer&&foreground(appPeer)&&foreground(recoveryPeer)&&
  xpc_connection_get_euid(appPeer)==xpc_connection_get_euid(recoveryPeer)&&
  xpc_connection_get_asid(appPeer)==xpc_connection_get_asid(recoveryPeer);}
void revoke(){
  const auto old=generation;if(sessionActive){retiredGeneration=old;recoveryAvailable=false;}generation=0;sessionActive=false;
  if(memory){memory->s->active=0;memory->s->deadline=0;memory.reset();}
  if(old&&driverPeer)xpc_connection_send_message(driverPeer,sessionMessage("detach",old));
}
void refresh(){if(driverPeer&&generation)xpc_connection_send_message(driverPeer,sessionMessage("refresh",generation));}
void handle(xpc_connection_t c,const std::string &role,xpc_object_t m,xpc_object_t r){
  if(!r||!owner(c,role)){sendReply(c,r,"This connection no longer owns the session.");return;}
  auto op=string(m,"op");
  if(op=="status"&&role=="recovery"&&schema(m,"status")){
    xpc_dictionary_set_uint64(r,"generation",generation);xpc_dictionary_set_uint64(r,"retired",retiredGeneration);xpc_dictionary_set_bool(r,"active",sessionActive);sendReply(c,r);return;
  }
  if(op=="settled"&&role=="recovery"&&schema(m,"settled",{{"generation",XPC_TYPE_UINT64}})){
    if(generation||xpc_dictionary_get_uint64(m,"generation")!=retiredGeneration){sendReply(c,r,"Recovery belongs to a different session.");return;}
    retiredGeneration=0;recoveryAvailable=true;sendReply(c,r);return;
  }
  if(op=="open"&&role=="app"&&schema(m,"open",{{"rate",XPC_TYPE_DOUBLE},{"outputName",XPC_TYPE_STRING,1024}})){
    if(!driverPeer||!recoveryPeer||!recoveryAvailable||retiredGeneration){sendReply(c,r,"Waiting for the audio driver and recovery helper.",true);return;}
    if(!paired()){sendReply(c,r,"The recovery helper belongs to a different login session.");return;}
    if(generation){sendReply(c,r,"An audio session is already open.");return;}
    double rate=xpc_dictionary_get_double(m,"rate");
    if(!std::isfinite(rate)||rate<32000||rate>192000){sendReply(c,r,"Unsupported sample rate.");return;}
    uint64_t token;arc4random_buf(&token,sizeof(token));if(!token)token=1;
    auto next=std::make_shared<Mapping>();
    if(!next->create(rate,token)){sendReply(c,r,"Cannot allocate audio transport.");return;}
    generation=token;appBeat=now();renderChanged=appBeat;lastRender=0;
    auto attach=sessionMessage("attach",token);xpc_dictionary_set_value(attach,"memory",next->object);
    xpc_dictionary_set_double(attach,"rate",rate);xpc_dictionary_set_string(attach,"outputName",xpc_dictionary_get_string(m,"outputName"));
    auto expectedDriver=driverPeer;
    requestAsync(driverPeer,attach,queue,3,^(xpc_object_t result){
      if(generation!=token||c!=appPeer||driverPeer!=expectedDriver||!paired()){
        if(generation==token)revoke();sendReply(c,r,"Audio session was superseded.");return;
      }
      if(!succeeded(result)){revoke();sendReply(c,r,error(result).c_str(),retryable(result));return;}
      memory=next;appBeat=now();renderChanged=appBeat;
      xpc_dictionary_set_uint64(r,"generation",token);xpc_dictionary_set_value(r,"memory",next->object);sendReply(c,r);
    });return;
  }
  if(!sessionSchema(m,op.c_str())||!generation||xpc_dictionary_get_uint64(m,"generation")!=generation||!paired()){
    sendReply(c,r,"Invalid or stale audio session.");return;
  }
  if(op=="activate"&&role=="recovery"){
    if(!memory||now()-appBeat>2*NSEC_PER_SEC){sendReply(c,r,"Audio renderer is not ready.");return;}
    auto s=memory->s;if(!s->rendered.load()){sendReply(c,r,"Physical output has not started.");return;}
    recoveryBeat=now();s->deadline=now()+2*NSEC_PER_SEC;s->active=1;sessionActive=true;
    renderChanged=now();lastRender=s->rendered.load();refresh();sendReply(c,r);return;
  }
  if(op=="heartbeat"){
    if(role=="app")appBeat=now();else recoveryBeat=now();
    if(memory&&sessionActive){
      auto rendered=memory->s->rendered.load();if(rendered!=lastRender){lastRender=rendered;renderChanged=now();}
      if(now()-appBeat>1500*NSEC_PER_MSEC||now()-recoveryBeat>1500*NSEC_PER_MSEC||now()-renderChanged>1500*NSEC_PER_MSEC){
        revoke();sendReply(c,r,"Audio session stopped; ordinary playback is being restored.");return;}
      memory->s->deadline=now()+2*NSEC_PER_SEC;
    }
    sendReply(c,r);return;
  }
  if((op=="close"&&role=="app")||(op=="deactivate"&&role=="recovery")){revoke();sendReply(c,r);return;}
  sendReply(c,r,"Unknown bridge operation.");
}
void acceptPeer(xpc_connection_t c,std::string appRequirement=requirement(@"app"),std::string recoveryRequirement=requirement(@"recovery")){
  if(pendingPeers>=32){xpc_connection_cancel(c);return;}
  ++pendingPeers;auto p=std::make_shared<Peer>();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),queue,^{if(!p->ready){finishPending(p);xpc_connection_cancel(c);}});
  xpc_connection_set_event_handler(c,^(xpc_object_t m){
    if(xpc_get_type(m)==XPC_TYPE_ERROR){
      finishPending(p);
      if(c==driverPeer){driverPeer=nil;revoke();}
      if(c==appPeer){appPeer=nil;revoke();}
      if(c==recoveryPeer){recoveryPeer=nil;recoveryAvailable=false;revoke();}return;
    }
    if(!p->pending&&!p->ready){xpc_connection_cancel(c);return;}
    auto r=replyMessage(m);if(!r){finishPending(p);xpc_connection_cancel(c);return;}
    if(!isMessage(m)){sendReply(c,r,"Protocol mismatch.");finishPending(p);xpc_connection_cancel(c);return;}
    if(p->role.empty()){
      if(!schema(m,"hello",{{"role",XPC_TYPE_STRING,32}})){finishPending(p);xpc_connection_cancel(c);return;}
      auto claimed=string(m,"role");std::string req;
      if(claimed=="driver")req="anchor apple and (identifier \"com.apple.audio.DriverHelper\" or identifier \"com.apple.audio.Core-Audio-Driver-Service\" or identifier \"com.apple.audio.Core-Audio-Driver-Service.helper\")";
      else if(claimed=="app")req=appRequirement;else if(claimed=="recovery")req=recoveryRequirement;
      if(!constrain(c,req)){finishPending(p);xpc_connection_cancel(c);return;}
      p->role=claimed;sendReply(c,r);return;
    }
    if(!p->ready){
      if(!schema(m,"ready")||(p->role!="driver"&&!foreground(c))){finishPending(p);xpc_connection_cancel(c);return;}
      auto existing=p->role=="driver"?driverPeer:p->role=="app"?appPeer:recoveryPeer;
      if(existing&&existing!=c){
        // Never treat a recycled PID as authority to replace a live peer.
        if(p->role=="driver"||foreground(existing)){sendReply(c,r,"Another instance is connected.",true);finishPending(p);xpc_connection_cancel(c);return;}
        revoke();xpc_connection_cancel(existing);
      }
      if(p->role=="driver")driverPeer=c;else if(p->role=="app")appPeer=c;else {recoveryPeer=c;recoveryAvailable=false;}
      p->ready=true;finishPending(p);sendReply(c,r);return;
    }
    handle(c,p->role,m,r);
  });xpc_connection_resume(c);
}
}
int main(){@autoreleasepool{
  queue=dispatch_queue_create("com.tc.myEq.bridge",DISPATCH_QUEUE_SERIAL);
  auto listener=xpc_connection_create_mach_service(bridgeService,queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);
  xpc_connection_set_event_handler(listener,^(xpc_object_t o){if(xpc_get_type(o)==XPC_TYPE_CONNECTION)acceptPeer((xpc_connection_t)o);});
  xpc_connection_resume(listener);
  auto timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC/4,NSEC_PER_MSEC*25);
  dispatch_source_set_event_handler(timer,^{
    if(generation&&(!paired()||(!sessionActive&&now()-appBeat>4*NSEC_PER_SEC)||
       (sessionActive&&(now()-appBeat>1500*NSEC_PER_MSEC||now()-recoveryBeat>1500*NSEC_PER_MSEC||now()-renderChanged>1500*NSEC_PER_MSEC))))revoke();
  });dispatch_resume(timer);dispatch_main();
}}
