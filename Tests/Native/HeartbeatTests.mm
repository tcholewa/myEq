#include "../../Sources/CTransport/IPC.hpp"
#include <deque>
#include "../../Sources/CTransport/Health.hpp"
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
static xpc_object_t ended(){auto r=status();xpc_dictionary_set_bool(r,"ended",true);return r;}
int main(){@autoreleasepool{
  MEQConnection c;char error[512];bool canRetry;
  auto check=[&](int expected,bool retry){assert(meq_heartbeat(&c,error,sizeof(error),&canRetry)==expected);assert(canRetry==retry);assert(responses.empty());};
  responses={status(),status()};check(1,false);
  responses={nil};check(0,true);
  c.memory=std::make_shared<Mapping>();assert(c.memory->create(48000,47));c.generation=47;
  auto shared=c.memory->s;shared->active=1;shared->deadline=now()+peerHealthNS;
  responses={status(),nil};check(1,false);
  responses={nil};check(1,false); // delayed bridge reply, valid existing lease
  shared->deadline=now()-1;responses={nil};check(0,true);
  responses={status(),nil};check(0,true);
  shared->deadline=now()+peerHealthNS;
  shared->active=0;responses={nil};check(0,true);
  shared->active=1;c.generation=48;responses={nil};check(0,true);c.generation=47;
  // Explicit error replies and signature/peer events cannot use a live lease as grace.
  responses={XPC_ERROR_CONNECTION_INTERRUPTED};check(0,true);
  responses={XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT};check(0,false);
  responses={meq::message("reply")};check(0,false);
  auto malformed=status();xpc_dictionary_set_string(malformed,"reason","0");responses={status(),malformed};check(0,false);
  responses={status(),status(1,true)};check(0,true);
  responses={status(),status(1,false)};check(0,false);
  responses={status(),status(2)};check(2,false);
  responses={status(),status(3)};check(3,false);
  responses={status(),XPC_ERROR_CONNECTION_INVALID};check(0,true);
  // Ended sessions read the recovery reason in either settlement ordering.
  responses={ended(),status(1,true)};check(0,true);
  responses={ended(),status(1,false)};check(0,false);
  responses={ended(),status(2)};check(2,false);
  responses={ended(),status(3)};check(3,false);
  responses={ended(),status()};check(0,true); // retirement notification not processed yet
  auto inactive=status();xpc_dictionary_set_bool(inactive,"active",false);
  responses={ended(),inactive};check(0,true); // restored before the poll, no reason published yet
  responses={ended(),nil};check(0,true); // no healthy grace, even with a live test mapping
  responses={ended(),malformed};check(0,false);
  responses={ended(),XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT};check(0,false);
  auto invalidEnded=ended();xpc_dictionary_set_string(invalidEnded,"ended","true");
  responses={invalidEnded};check(0,false);
  auto ongoing=status();xpc_dictionary_set_bool(ongoing,"ended",false);
  responses={ongoing,status()};check(1,false);
  // Activation refreshes the app lease after potentially slow HAL buffer setup.
  responses={status(),status()};assert(meq_activate_route(&c,"usb",error,sizeof(error),&canRetry));assert(responses.empty());
  responses={nil};assert(!meq_activate_route(&c,"usb",error,sizeof(error),&canRetry)&&canRetry&&responses.empty());
  responses={ended()};assert(!meq_activate_route(&c,"usb",error,sizeof(error),&canRetry)&&canRetry&&responses.empty());
  responses={invalidEnded};assert(!meq_activate_route(&c,"usb",error,sizeof(error),&canRetry)&&!canRetry&&responses.empty());
  c.state->failure=1;check(0,true);
  c.state->failure=2;check(0,false);
  std::cout<<"Heartbeat transient/permanent classification passed\n";
}}
