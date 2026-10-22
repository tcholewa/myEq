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
  revoke();assert(detachMessages==0);
  generation=1;memory=std::make_shared<Mapping>();assert(memory->create(48000,1));
  auto prior=memory;
  handle(nullptr,"app",sessionMessage("close",1),message("reply"));
  assert(memory==prior); // A stale/non-current peer cannot revoke this mapping.prior->s->active=1;prior->s->deadline=now()+NSEC_PER_SEC;
  revoke();assert(detachMessages==1&&!memory&&!prior->s->active&&!prior->s->deadline);
  // Recovery restore, app close, and both disconnect events must not enqueue more HAL detaches.
  for(int i=0;i<4;i++)revoke();
  assert(detachMessages==1);
  generation=2;memory=std::make_shared<Mapping>();assert(memory->create(48000,2));
  revoke();assert(detachMessages==2);
  // Retired-session heartbeat is retryable only for the current paired owner.
  appPeer=xpc_connection_create(nullptr,nullptr);recoveryPeer=xpc_connection_create(nullptr,nullptr);
  for(auto c:{appPeer,recoveryPeer}){xpc_connection_set_event_handler(c,^(xpc_object_t){});xpc_connection_resume(c);}
  retiredGeneration=42;generation=0;
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));
  assert(lastReply&&retryable(lastReply));
  handle(appPeer,"app",sessionMessage("heartbeat",41),message("reply"));
  assert(!retryable(lastReply));
  foreignSession=recoveryPeer;assert(!paired());
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!retryable(lastReply));
  foreignSession=nullptr;consoleUID=502;consoleUser.state->publish(consoleUser.state->invalidate(),consoleUID);assert(!paired());
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!retryable(lastReply));
  consoleUID=501;consoleUser.state->publish(consoleUser.state->invalidate(),consoleUID);assert(paired());
  generation=43;
  handle(appPeer,"app",sessionMessage("heartbeat",42),message("reply"));assert(!retryable(lastReply));
  for(auto c:{appPeer,recoveryPeer})xpc_connection_cancel(c);appPeer=nil;recoveryPeer=nil;generation=0;
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
  std::cout<<"Bridge detach idempotence and temporary/permanent IPC failure classification passed\n";
}}
