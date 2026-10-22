// Anonymous XPC endpoints only: no installed services, HAL calls, or real routing.
#include "../../Sources/CTransport/IPC.hpp"
#import <SystemConfiguration/SystemConfiguration.h>
#import <Security/Security.h>
#include <cassert>
#include <iostream>
#include <random>
static CFStringRef testConsole(SCDynamicStoreRef,uid_t *uid,gid_t*){if(uid)*uid=getuid();return CFSTR("fixture");}
#define SCDynamicStoreCopyConsoleUser testConsole
#define main bridge_program_main
#include "../../Helpers/Bridge.mm"
#undef main
#undef SCDynamicStoreCopyConsoleUser
static std::string selfRequirement(){
  SecCodeRef code=nullptr;CFDictionaryRef info=nullptr;
  assert(SecCodeCopySelf(kSecCSDefaultFlags,&code)==errSecSuccess);
  assert(SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info)==errSecSuccess);
  NSData *hash=((__bridge NSDictionary*)info)[(__bridge NSString*)kSecCodeInfoUnique];assert(hash.length==20);
  std::string result="cdhash H\"";for(NSUInteger i=0;i<hash.length;i++){char hex[3];snprintf(hex,3,"%02x",((const unsigned char*)hash.bytes)[i]);result+=hex;}
  CFRelease(info);CFRelease(code);return result+"\"";
}
static void runIPC(){
  consoleUser.state->publish(consoleUser.state->invalidate(),getuid());
  queue=dispatch_queue_create("myEq.security.fixture",DISPATCH_QUEUE_SERIAL);
  auto good=selfRequirement();
  auto listener=xpc_connection_create(nullptr,queue);
  serialEvents(listener,queue,^(xpc_object_t c){if(xpc_get_type(c)==XPC_TYPE_CONNECTION)acceptPeer((xpc_connection_t)c,good,good);});xpc_connection_resume(listener);
  auto endpoint=xpc_endpoint_create(listener);
  auto connect=[&]{auto c=xpc_connection_create_from_endpoint(endpoint);xpc_connection_set_event_handler(c,^(xpc_object_t){});xpc_connection_resume(c);return c;};
  auto appClient=connect();auto helloResult=handshakeResult(appClient,"app");if(!succeeded(helloResult))std::cerr<<"Fixture handshake: "<<error(helloResult)<<"\n";assert(succeeded(helloResult));
  auto recoveryClient=connect();assert(handshake(recoveryClient,"recovery"));
  auto status=request(recoveryClient,message("status"));assert(succeeded(status)&&!xpc_dictionary_get_uint64(status,"generation"));
  assert(succeeded(request(recoveryClient,sessionMessage("settled",0))));
  dispatch_sync(queue,^{generation=42;memory=std::make_shared<Mapping>();assert(memory->create(48000,42));});
  assert(!succeeded(request(appClient,sessionMessage("close",41))));
  dispatch_sync(queue,^{assert(generation==42&&memory);});
  // A request with no reply context must not run a mutating handler.
  xpc_connection_send_message(appClient,sessionMessage("close",42));
  assert(!succeeded(request(appClient,sessionMessage("heartbeat",42),1)));
  // Disconnect revocation is expected; the service itself must remain usable.
  assert(succeeded(request(recoveryClient,message("status"))));
  xpc_connection_cancel(appClient);xpc_connection_cancel(recoveryClient);xpc_connection_cancel(listener);
  auto denied=xpc_connection_create(nullptr,queue);
  std::string impossible="cdhash H\"0000000000000000000000000000000000000000\"";
  serialEvents(denied,queue,^(xpc_object_t c){if(xpc_get_type(c)==XPC_TYPE_CONNECTION)acceptPeer((xpc_connection_t)c,impossible,impossible);});xpc_connection_resume(denied);
  auto remote=xpc_connection_create_from_endpoint(xpc_endpoint_create(denied));
  xpc_connection_set_event_handler(remote,^(xpc_object_t){});xpc_connection_resume(remote);
  assert(!handshake(remote,"app"));xpc_connection_cancel(remote);xpc_connection_cancel(denied);
}
static void parserAndRingFuzz(){
  auto r=message("reply");assert(!succeeded(r));xpc_dictionary_set_int64(r,"error",99);assert(!succeeded(r));
  xpc_dictionary_set_string(r,"error","");assert(succeeded(r));xpc_dictionary_set_string(r,"retryable","true");assert(!succeeded(r));
  assert(!replyMessage(message("status")));assert(!replyMessage(xpc_array_create(nullptr,0)));
  auto open=message("open");xpc_dictionary_set_double(open,"rate",48000);xpc_dictionary_set_string(open,"outputName",std::string(1025,'a').c_str());
  assert(!schema(open,"open",{{"rate",XPC_TYPE_DOUBLE},{"outputName",XPC_TYPE_STRING,1024}}));
  std::mt19937_64 rng(0x4d455132);auto mapping=std::make_shared<Mapping>();assert(mapping->create(48000,1));
  std::vector<float> in(capacity*2,0.1f),out(capacity*2);auto s=mapping->s;
  for(int i=0;i<25000;i++){
    s->read=rng();s->written=rng();s->frames=uint32_t(rng());s->channels=uint32_t(rng());
    assert(!valid(s,mapping->size));
    auto n=uint32_t(rng()%(capacity+1));write(s,in.data(),n,0);meq::read(s,out.data(),n);
    auto m=message("ready");xpc_dictionary_set_value(m,"version",i%2?xpc_string_create("2"):xpc_uint64_create(rng()));
    assert(!schema(m,"ready"));
  }
  s->read=UINT64_MAX-8;s->written=UINT64_MAX-1;assert(available(s)==7);
}
static void files(){
  NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSString *path=[dir stringByAppendingPathComponent:@"state.plist"];
  NSData *bytes=[@"test" dataUsingEncoding:NSUTF8StringEncoding];assert(privateWrite(path,bytes,1024));
  assert(openRootFile(path.fileSystemRepresentation)<0); // User-owned ancestors cannot supply installation trust.
  assert(readFile(path.fileSystemRepresentation,4,getuid()).length==4);assert(!readFile(path.fileSystemRepresentation,3,getuid()));
  NSString *link=[dir stringByAppendingPathComponent:@"link"];
  assert(symlink(path.fileSystemRepresentation,link.fileSystemRepresentation)==0);
  assert(!readFile(link.fileSystemRepresentation,100,getuid()));assert(!privateWrite(link,bytes,1024));
  NSString *hard=[dir stringByAppendingPathComponent:@"hard"];
  assert(::link(path.fileSystemRepresentation,hard.fileSystemRepresentation)==0);assert(!readFile(path.fileSystemRepresentation,100,getuid()));
  [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
}
int main(){@autoreleasepool{parserAndRingFuzz();files();runIPC();std::cout<<"Security: typed replies, schema/cursor fuzz, safe files, real XPC authentication and stale-session rejection passed\n";}}
