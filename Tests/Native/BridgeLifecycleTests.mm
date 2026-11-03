// Isolated control-path checks. No installed Mach services or audio device operations.
#include "../../Sources/CTransport/IPC.hpp"
#include <cassert>
#include <iostream>
#import <SystemConfiguration/SystemConfiguration.h>
static int detachMessages=0;
static xpc_object_t lastReply;
static uid_t consoleUID=501,peerUID=501;
static au_asid_t peerASID=42;
static xpc_connection_t foreignSession;
static CFStringRef mockConsole(SCDynamicStoreRef,uid_t *uid,gid_t*){*uid=consoleUID;return CFSTR("test");}
static uid_t mockEUID(xpc_connection_t){return peerUID;}
static au_asid_t mockASID(xpc_connection_t c){return c==foreignSession?43:peerASID;}
static void mockSend(xpc_connection_t,xpc_object_t m){
  if(meq::string(m,"op")=="detach")++detachMessages;else lastReply=m;
}
static void mockReply(xpc_connection_t c,xpc_object_t r,const char *error="",bool retry=false){
  if(!c||!r)return;
  xpc_dictionary_set_string(r,"error",error);xpc_dictionary_set_bool(r,"retryable",retry);lastReply=r;
}
#define sendReply mockReply
#define xpc_connection_send_message mockSend
#define SCDynamicStoreCopyConsoleUser mockConsole
#define xpc_connection_get_euid mockEUID
#define xpc_connection_get_asid mockASID
#define main bridge_program_main
#include "../../Helpers/Bridge.mm"
#undef main
#undef xpc_connection_send_message
int main(){@autoreleasepool{
  consoleUser.state->publish(consoleUser.state->invalidate(),consoleUID);
  // An anonymous, unexported listener supplies a valid object; sends are intercepted above.
  driverPeer=xpc_connection_create(nullptr,nullptr);
  xpc_connection_set_event_handler(driverPeer,^(xpc_object_t){});
  xpc_connection_resume(driverPeer);
  const uint64_t base=10000000000;
  assert(healthDeadline(base,base,base)==base+peerHealthNS);
  for(uint64_t age:{600000000ull,1600000000ull,1999999999ull})
    assert(base+age<healthDeadline(base+age,base,base+age));
  assert(base+recoveryHealthNS==healthDeadline(base+recoveryHealthNS,base,base+recoveryHealthNS));
  assert(base+peerHealthNS==healthDeadline(base,base+peerHealthNS,base+peerHealthNS));
  revokeSession();assert(detachMessages==0);
  generation=1;memory=std::make_shared<Mapping>();assert(memory->create(48000,1));
  auto prior=memory;
  handle(nullptr,"app",sessionMessage("close",1),message("reply"));
  assert(memory==prior); // A stale/non-current peer cannot revoke this mapping.
  prior->s->active=1;prior->s->deadline=now()+NSEC_PER_SEC;
  revokeSession();assert(detachMessages==1&&!memory&&!prior->s->active&&!prior->s->deadline);
  // Recovery restore, app close, and both disconnect events must not enqueue more HAL detaches.
  for(int i=0;i<4;i++)revokeSession();
  assert(detachMessages==1);
  generation=2;memory=std::make_shared<Mapping>();assert(memory->create(48000,2));
  revokeSession();assert(detachMessages==2);
  // The same owner can read an ended outcome before or after restoration settles.
  appPeer=xpc_connection_create(nullptr,nullptr);recoveryPeer=xpc_connection_create(nullptr,nullptr);
  for(auto c:{appPeer,recoveryPeer}){xpc_connection_set_event_handler(c,^(xpc_object_t){});xpc_connection_resume(c);}
  generation=42;sessionActive=true;memory=std::make_shared<Mapping>();assert(memory->create(48000,42));
  auto endedMapping=memory;endedMapping->s->active=1;endedMapping->s->deadline=now()+NSEC_PER_SEC;
  revokeSession();assert(retiredGeneration==42&&!generation&&!memory);
  const int retirementDetaches=detachMessages;
  auto checkEnded=[&]{
    handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));
    assert(succeeded(lastReply)&&xpc_dictionary_get_bool(lastReply,"ended"));
    assert(!endedMapping->s->active.load()&&!endedMapping->s->deadline.load());
    assert(detachMessages==retirementDetaches);
  };
  checkEnded();
  handle(recoveryPeer,"recovery",sessionMessage("heartbeat",42),message("reply"));
  assert(retryable(lastReply)); // Recovery still restores a revoked session.
  handle(recoveryPeer,"recovery",sessionMessage("settled",41),message("reply"));assert(!succeeded(lastReply));
  handle(recoveryPeer,"recovery",sessionMessage("settled",42),message("reply"));
  assert(succeeded(lastReply)&&!retiredGeneration&&recoveryAvailable);
  checkEnded();checkEnded(); // Settlement must not forget the app's ended generation.
  handle(recoveryPeer,"recovery",sessionMessage("heartbeat",42),message("reply"));assert(!succeeded(lastReply)&&!retryable(lastReply));
  auto invalid=sessionMessage("heartbeat",42);xpc_dictionary_set_bool(invalid,"extra",true);
  handle(appPeer,"app",invalid,message("reply"));assert(!succeeded(lastReply)&&!retryable(lastReply));
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));
  assert(succeeded(lastReply));
  handle(appPeer,"app",sessionMessage("heartbeat",41),message("reply"));
  assert(!succeeded(lastReply)&&!retryable(lastReply));
  foreignSession=recoveryPeer;assert(!paired());
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!succeeded(lastReply)&&!retryable(lastReply));
  foreignSession=nullptr;consoleUID=502;consoleUser.state->publish(consoleUser.state->invalidate(),consoleUID);assert(!paired());
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!succeeded(lastReply)&&!retryable(lastReply));
  consoleUID=501;consoleUser.state->publish(consoleUser.state->invalidate(),consoleUID);assert(paired());
  auto originalApp=appPeer,originalRecovery=recoveryPeer;
  auto replacement=xpc_connection_create(nullptr,nullptr);xpc_connection_set_event_handler(replacement,^(xpc_object_t){});xpc_connection_resume(replacement);
  appPeer=replacement;
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!succeeded(lastReply)&&!retryable(lastReply));
  appPeer=originalApp;recoveryPeer=replacement;
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!succeeded(lastReply)&&!retryable(lastReply));
  recoveryPeer=originalRecovery;xpc_connection_cancel(replacement);
  // An active replacement generation rejects the previous token and keeps its mapping intact.
  generation=43;
  memory=std::make_shared<Mapping>();assert(memory->create(48000,43));auto replacementMapping=memory;
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!succeeded(lastReply)&&!retryable(lastReply)&&memory==replacementMapping);
  // First expiry observed by the app's heartbeat follows the same typed outcome path.
  sessionActive=true;appBeat=now()-peerHealthNS;recoveryBeat=now();renderChanged=now();lastRender=0;
  handle(appPeer,"app",sessionMessage("heartbeat",43),message("reply"));
  assert(succeeded(lastReply)&&xpc_dictionary_get_bool(lastReply,"ended")&&!generation&&!memory);
  handle(recoveryPeer,"recovery",sessionMessage("settled",43),message("reply"));assert(succeeded(lastReply));
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!succeeded(lastReply)&&!retryable(lastReply));
  handle(appPeer,"app",sessionMessage("heartbeat",43),message("reply"));assert(succeeded(lastReply)&&xpc_dictionary_get_bool(lastReply,"ended"));
  for(auto c:{appPeer,recoveryPeer})xpc_connection_cancel(c);appPeer=nil;recoveryPeer=nil;generation=0;
  forgetEnded();
  xpc_connection_cancel(driverPeer);driverPeer=nil;

  assert(retryable(nil)&&retryable(XPC_ERROR_CONNECTION_INTERRUPTED)&&retryable(XPC_ERROR_CONNECTION_INVALID));
  assert(!retryable(XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT));
  auto permanent=message("reply");xpc_dictionary_set_string(permanent,"error","Protocol mismatch.");
  assert(!succeeded(permanent)&&!retryable(permanent));
  xpc_dictionary_set_uint64(permanent,"version",protocol+1);
  xpc_dictionary_set_bool(permanent,"retryable",true);
  assert(!retryable(permanent));
  auto temporary=message("reply");xpc_dictionary_set_string(temporary,"error","Driver is connecting.");
  xpc_dictionary_set_bool(temporary,"retryable",true);
  assert(!succeeded(temporary)&&retryable(temporary));
  std::cout<<"Bridge detach idempotence, ended-session ordering/ownership and IPC failure classification passed\n";
}}
