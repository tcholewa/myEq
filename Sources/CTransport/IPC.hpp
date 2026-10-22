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
#include "SecureFile.hpp"
#include <bsm/audit.h>

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
inline bool textField(xpc_object_t m,const char *key,size_t limit,bool nonempty=false) {
  auto v=xpc_dictionary_get_value(m,key);
  if(!v||xpc_get_type(v)!=XPC_TYPE_STRING)return false;
  size_t n=xpc_string_get_length(v);
  return n<=limit&&(!nonempty||n)&&strlen(xpc_string_get_string_ptr(v))==n;
}
struct Field { const char *name; xpc_type_t type; size_t limit=0; bool optional=false; };
inline bool schema(xpc_object_t m,const char *op,std::initializer_list<Field> fields={}) {
  if(!isMessage(m)||!textField(m,"op",32,true)||string(m,"op")!=op)return false;
  for(auto f:fields){auto v=xpc_dictionary_get_value(m,f.name);
    if(!v){if(f.optional)continue;return false;}
    if(xpc_get_type(v)!=f.type||(f.type==XPC_TYPE_STRING&&!textField(m,f.name,f.limit)))return false;
  }
  return xpc_dictionary_apply(m,^(const char *key,xpc_object_t){
    if(!strcmp(key,"op")||!strcmp(key,"version"))return true;
    for(auto f:fields)if(!strcmp(key,f.name))return true;
    return false;
  });
}
inline xpc_object_t replyMessage(xpc_object_t request) {
  if(!request||xpc_get_type(request)!=XPC_TYPE_DICTIONARY)return nil;
  auto r=xpc_dictionary_create_reply(request);if(!r)return nil;
  xpc_dictionary_set_uint64(r,"version",protocol);
  xpc_dictionary_set_string(r,"error","");xpc_dictionary_set_bool(r,"retryable",false);return r;
}
inline void sendReply(xpc_connection_t peer,xpc_object_t r,const char *error="",bool retryable=false) {
  if(!r||!peer)return;
  xpc_dictionary_set_string(r,"error",error);xpc_dictionary_set_bool(r,"retryable",retryable);
  xpc_connection_send_message(peer,r);
}
inline void reply(xpc_connection_t peer,xpc_object_t request,const char *error="",bool retryable=false) {
  sendReply(peer,replyMessage(request),error,retryable);
}
inline au_asid_t auditSession(){auditinfo_addr_t a{};return getaudit_addr(&a,sizeof(a))?AU_DEFAUDITSID:a.ai_asid;}
inline xpc_object_t sessionMessage(const char *op,uint64_t generation){
  auto m=message(op);xpc_dictionary_set_uint64(m,"generation",generation);return m;
}
inline bool sessionSchema(xpc_object_t m,const char *op){return schema(m,op,{{"generation",XPC_TYPE_UINT64}})&&xpc_dictionary_get_uint64(m,"generation");}
// All completions and deadlines execute on the supplied serial control queue.
inline void requestAsync(xpc_connection_t c,xpc_object_t m,dispatch_queue_t q,double seconds,void (^completion)(xpc_object_t)) {
  if(!c){dispatch_async(q,^{completion(nil);});return;}
  auto done=std::make_shared<bool>(false);
  xpc_connection_send_message_with_reply(c,m,q,^(xpc_object_t r){if(!*done){*done=true;completion(r);}});
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,int64_t(seconds*1e9)),q,^{if(!*done){*done=true;completion(nil);}});
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
inline bool validReply(xpc_object_t r) {
  if(!isMessage(r)||!textField(r,"error",2048))return false;
  auto flag=xpc_dictionary_get_value(r,"retryable");return !flag||xpc_get_type(flag)==XPC_TYPE_BOOL;
}
inline bool succeeded(xpc_object_t r) { return validReply(r)&&string(r,"error").empty(); }
inline bool retryable(xpc_object_t r) {
  return !r || r==XPC_ERROR_CONNECTION_INTERRUPTED || r==XPC_ERROR_CONNECTION_INVALID ||
    (validReply(r)&&xpc_dictionary_get_bool(r,"retryable"));
}
inline std::string error(xpc_object_t r) {
  if(!r)return "The audio helper did not respond in time.";
  if(r==XPC_ERROR_CONNECTION_INTERRUPTED||r==XPC_ERROR_CONNECTION_INVALID)return "The audio helper is starting or reconnecting.";
  if(r==XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT)return "The audio helper does not match this app. Reinstall myEq.pkg.";
  if(!validReply(r))return "The audio helper protocol is incompatible. Reinstall myEq.pkg.";
  return string(r,"error");
}
inline void copyError(char *out,size_t n,const std::string &s) { if(out&&n)snprintf(out,n,"%s",s.c_str()); }
inline NSDictionary *trust() {
  return readPlist("/Library/Application Support/myEq/trust.plist",64*1024,0,true);
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
  double acceptedRate=0;uint64_t acceptedGeneration=0;
  ~Mapping(){if(s)munmap(s,size);}
  bool create(double rate,uint64_t generation) {
    // XPC maps whole VM pages. Negotiate that exact allocation, not sizeof(Shared).
    size=mappingBytes();
    void *p=mmap(nullptr,size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0);
    if(p==MAP_FAILED)return false;
    s=new(p)Shared();s->rate=rate;s->generation=generation;acceptedRate=rate;acceptedGeneration=generation;
    object=xpc_shmem_create(p,size);return object!=nil;
  }
  bool map(xpc_object_t obj) {
    if(!obj||xpc_get_type(obj)!=XPC_TYPE_SHMEM)return false;
    void *p=nullptr; size=xpc_shmem_map(obj,&p);s=static_cast<Shared*>(p);object=obj;
    if(!valid(s,size))return false;
    acceptedRate=s->rate;acceptedGeneration=s->generation;
    return std::isfinite(acceptedRate)&&acceptedRate>=32000&&acceptedRate<=192000&&acceptedGeneration;
  }
};
}
