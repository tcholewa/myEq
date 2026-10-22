// Isolated control-path checks. No installed Mach services or audio device operations.
#include "../../Sources/CTransport/IPC.hpp"
#include <cassert>
#include <iostream>
static int detachMessages=0;
static void mockSend(xpc_connection_t,xpc_object_t m){
  if(meq::string(m,"op")=="detach")++detachMessages;
}
#define xpc_connection_send_message mockSend
#define main bridge_program_main
#include "../../Helpers/Bridge.mm"
#undef main
#undef xpc_connection_send_message
int main(){@autoreleasepool{
  // An anonymous, unexported listener supplies a valid object; sends are intercepted above.
  driverPeer=xpc_connection_create(nullptr,nullptr);
  xpc_connection_set_event_handler(driverPeer,^(xpc_object_t){});
  xpc_connection_resume(driverPeer);
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
