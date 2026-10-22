// Real anonymous XPC connections with deliberately late replies, no installed services or routing.
#include "../../Sources/CTransport/Client.mm"
#include "../../Sources/CTransport/Health.hpp"
#include <cassert>
#include <iostream>
int main(){@autoreleasepool{
  MEQConnection c;c.memory=std::make_shared<Mapping>();assert(c.memory->create(48000,47));c.generation=47;
  auto s=c.memory->s;s->active=1;s->deadline=now()+peerHealthNS;
  auto server=dispatch_queue_create("test.delayed.bridge",DISPATCH_QUEUE_SERIAL);
  auto renew=std::make_shared<bool>(true);
  auto permanent=std::make_shared<bool>(false);
  auto listener=xpc_connection_create(nullptr,server);
  serialEvents(listener,server,^(xpc_object_t peer){
    if(xpc_get_type(peer)!=XPC_TYPE_CONNECTION)return;
    xpc_connection_set_target_queue((xpc_connection_t)peer,server);
    serialEvents((xpc_connection_t)peer,server,^(xpc_object_t m){
      if(xpc_get_type(m)!=XPC_TYPE_DICTIONARY)return;
      auto r=replyMessage(m);assert(r);
      if(*permanent){sendReply((xpc_connection_t)peer,r,"Invalid audio session.");return;}
      if(*renew)s->deadline.store(now()+peerHealthNS,std::memory_order_release);
      // Delay reply delivery, not lease processing. This reproduces the 500ms false failure.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,700*NSEC_PER_MSEC),server,^{sendReply((xpc_connection_t)peer,r);});
    });xpc_connection_resume((xpc_connection_t)peer);
  });xpc_connection_resume(listener);
  auto remote=xpc_connection_create_from_endpoint(xpc_endpoint_create(listener));
  xpc_connection_set_event_handler(remote,^(xpc_object_t){});xpc_connection_resume(remote);c.state->bridge=remote;
  char error[512];bool canRetry=false;
  for(unsigned i=0;i<6;++i)assert(meq_heartbeat(&c,error,sizeof(error),&canRetry)==1&&!canRetry);
  dispatch_sync(server,^{*permanent=true;});
  assert(meq_heartbeat(&c,error,sizeof(error),&canRetry)==0&&!canRetry); // explicit rejection wins over a live lease
  dispatch_sync(server,^{*permanent=false;*renew=false;});
  unsigned failures=0;
  for(unsigned i=0;i<5;++i)if(meq_heartbeat(&c,error,sizeof(error),&canRetry)==0){assert(canRetry);++failures;break;}
  assert(failures==1&&now()>=s->deadline.load()); // silence cannot extend the bridge deadline
  xpc_connection_cancel(remote);xpc_connection_cancel(listener);
  std::cout<<"Delayed real XPC replies preserve a live lease; rejection and expiry still stop\n";
}}
