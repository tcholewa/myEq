#include "../../Sources/CTransport/IPC.hpp"
#include <deque>
#include <cassert>
#include <iostream>
static std::deque<xpc_object_t> responses;
static xpc_object_t mockRequest(xpc_connection_t,xpc_object_t,double=3){
  assert(!responses.empty());auto r=responses.front();responses.pop_front();return r;
}
#define request mockRequest
#include "../../Sources/CTransport/Client.mm"
#undef request
static xpc_object_t status(int reason=0,bool retry=false){
  auto r=meq::message("reply");xpc_dictionary_set_string(r,"error","");
  xpc_dictionary_set_bool(r,"retryable",retry);
  xpc_dictionary_set_int64(r,"reason",reason);xpc_dictionary_set_bool(r,"active",reason==0);return r;
}
int main(){@autoreleasepool{
  MEQConnection c;char error[512];bool canRetry;
  auto check=[&](int expected,bool retry){assert(meq_heartbeat(&c,error,sizeof(error),&canRetry)==expected);assert(canRetry==retry);assert(responses.empty());};
  responses={status(),status()};check(1,false);
  responses={nil};check(0,true);
  responses={status(),nil};check(1,false);
  responses={XPC_ERROR_CONNECTION_INTERRUPTED};check(0,true);
  responses={XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT};check(0,false);
  responses={meq::message("reply")};check(0,false);
  auto malformed=status();xpc_dictionary_set_string(malformed,"reason","0");responses={status(),malformed};check(0,false);
  responses={status(),status(1,true)};check(0,true);
  responses={status(),status(1,false)};check(0,false);
  responses={status(),status(2)};check(2,false);
  responses={status(),status(3)};check(3,false);
  responses={status(),XPC_ERROR_CONNECTION_INVALID};check(0,true);
  // Activation refreshes the app lease after potentially slow HAL buffer setup.
  responses={status(),status()};assert(meq_activate_route(&c,"usb",error,sizeof(error),&canRetry));assert(responses.empty());
  responses={nil};assert(!meq_activate_route(&c,"usb",error,sizeof(error),&canRetry)&&canRetry&&responses.empty());
  c.state->failure=1;check(0,true);
  c.state->failure=2;check(0,false);
  std::cout<<"Heartbeat transient/permanent classification passed\n";
}}
