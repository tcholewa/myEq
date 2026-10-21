#pragma once
#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <memory>
#include <string>
#include <vector>
#include "Transport.hpp"

namespace meq {
inline xpc_object_t message(const char *op) {
  auto m=xpc_dictionary_create(nullptr,nullptr,0);
  xpc_dictionary_set_string(m,"op",op);
  xpc_dictionary_set_uint64(m,"version",protocol);
  return m;
}
inline bool isMessage(xpc_object_t m) {
  return m && xpc_get_type(m)==XPC_TYPE_DICTIONARY &&
    xpc_dictionary_get_uint64(m,"version")==protocol;
}
inline std::string string(xpc_object_t m,const char *key) {
  auto s=xpc_dictionary_get_string(m,key); return s?s:"";
}
inline void reply(xpc_connection_t peer,xpc_object_t request,const char *error="",bool retryable=false) {
  auto r=xpc_dictionary_create_reply(request); if(!r)return;
  xpc_dictionary_set_uint64(r,"version",protocol);
  xpc_dictionary_set_string(r,"error",error);
  xpc_dictionary_set_bool(r,"retryable",retryable);
  xpc_connection_send_message(peer,r);
}
// Block captures own this storage even if the caller times out before XPC completes.
struct Response { dispatch_semaphore_t done=dispatch_semaphore_create(0); xpc_object_t value; };
inline xpc_object_t request(xpc_connection_t c,xpc_object_t m,double seconds=3) {
  if(!c)return nil;
  auto r=std::make_shared<Response>();
  xpc_connection_send_message_with_reply(c,m,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(xpc_object_t v){
    r->value=v; dispatch_semaphore_signal(r->done);
  });
  if(dispatch_semaphore_wait(r->done,dispatch_time(DISPATCH_TIME_NOW,int64_t(seconds*1e9))))return nil;
  return r->value;
}
inline bool succeeded(xpc_object_t r) { return isMessage(r)&&string(r,"error").empty(); }
inline bool retryable(xpc_object_t r) {
  return !r || r==XPC_ERROR_CONNECTION_INTERRUPTED || r==XPC_ERROR_CONNECTION_INVALID ||
    (isMessage(r)&&xpc_dictionary_get_bool(r,"retryable"));
}
inline std::string error(xpc_object_t r) {
  if(!r)return "The audio helper did not respond in time.";
  if(r==XPC_ERROR_CONNECTION_INTERRUPTED||r==XPC_ERROR_CONNECTION_INVALID)return "The audio helper is starting or reconnecting.";
  if(r==XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT)return "The audio helper does not match this app. Reinstall myEq.pkg.";
  if(!isMessage(r))return "The audio helper protocol is incompatible. Reinstall myEq.pkg.";
  return string(r,"error");
}
inline void copyError(char *out,size_t n,const std::string &s) { if(out&&n)snprintf(out,n,"%s",s.c_str()); }
inline NSDictionary *trust() {
  const char *path="/Library/Application Support/myEq/trust.plist";
  struct stat st{};
  if(lstat(path,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||(st.st_mode&0022))return nil;
  return [NSDictionary dictionaryWithContentsOfFile:@(path)];
}
inline std::string requirement(NSString *role) {
  NSDictionary *t=trust(); NSString *hash=t[role];
  NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
  if(![hash isKindOfClass:NSString.class]||hash.length!=40||[hash rangeOfCharacterFromSet:bad].location!=NSNotFound)return "";
  return std::string("cdhash H\"")+hash.UTF8String+"\"";
}
inline bool constrain(xpc_connection_t c,const std::string &req) {
  return !req.empty() && xpc_connection_set_peer_code_signing_requirement(c,req.c_str())==0;
}
inline xpc_object_t handshakeResult(xpc_connection_t c,const char *role) {
  auto h=message("hello");xpc_dictionary_set_string(h,"role",role);
  auto r=request(c,h);if(!succeeded(r))return r;
  return request(c,message("ready"));
}
inline bool handshake(xpc_connection_t c,const char *role) { return succeeded(handshakeResult(c,role)); }
struct Mapping {
  Shared *s=nullptr; size_t size=0; xpc_object_t object;
  ~Mapping(){if(s)munmap(s,size);}
  bool create(double rate,uint64_t generation) {
    // XPC maps whole VM pages. Negotiate that exact allocation, not sizeof(Shared).
    size=mappingBytes();
    void *p=mmap(nullptr,size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0);
    if(p==MAP_FAILED)return false;
    s=new(p)Shared();s->rate=rate;s->generation=generation;
    object=xpc_shmem_create(p,size);return object!=nil;
  }
  bool map(xpc_object_t obj) {
    if(!obj||xpc_get_type(obj)!=XPC_TYPE_SHMEM)return false;
    void *p=nullptr; size=xpc_shmem_map(obj,&p);s=static_cast<Shared*>(p);object=obj;
    return valid(s,size);
  }
};
}
