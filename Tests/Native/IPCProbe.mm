// Explicit installed-system check. Sends only handshake messages, never route/audio operations.
#include "../../Sources/CTransport/IPC.hpp"
#include <cassert>
#include <iostream>

using namespace meq;
static xpc_connection_t connect() {
  auto c=xpc_connection_create_mach_service(bridgeService,nullptr,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
  assert(constrain(c,requirement(@"bridge")));
  xpc_connection_set_event_handler(c,^(xpc_object_t){});
  xpc_connection_resume(c);
  return c;
}
int main(){@autoreleasepool{
  auto c=connect();
  auto wrong=message("hello");xpc_dictionary_set_uint64(wrong,"version",protocol+1);
  auto response=request(c,wrong);
  // A signed bridge response proves service discovery and server authentication worked.
  assert(isMessage(response)&&string(response,"error")=="Protocol mismatch.");
  xpc_connection_cancel(c);
  for(const char *role:{"app","recovery","driver"}){
    auto peer=connect();auto hello=message("hello");xpc_dictionary_set_string(hello,"role",role);
    auto first=request(peer,hello);
    if(succeeded(first))assert(!succeeded(request(peer,message("ready"))));
    else assert(!isMessage(first));
    xpc_connection_cancel(peer);
  }
  std::cout<<"Installed bridge authenticated; wrong protocol and all unauthorized roles rejected\n";
}}
