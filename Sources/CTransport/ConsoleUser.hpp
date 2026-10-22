#pragma once
#import <SystemConfiguration/SystemConfiguration.h>
#include <atomic>
#include <cstdint>
#include <memory>

namespace meq {
static_assert(std::atomic<uint64_t>::is_always_lock_free);
// Console ownership is published from notifications, never queried synchronously by a heartbeat.
// Revision and UID share one atomic so an old query cannot undo a newer invalidation.
struct ConsoleUserState {
  static constexpr uint32_t unknown=UINT32_MAX;
  std::atomic<uint64_t> snapshot{unknown};
  dispatch_queue_t worker=dispatch_queue_create("com.tc.myEq.console.read",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
  uint64_t invalidate(){
    auto old=snapshot.load(std::memory_order_relaxed);uint64_t next;
    do {next=((old+uint64_t(1ULL<<32))&0xffffffff00000000ULL)|unknown;}
    while(!snapshot.compare_exchange_weak(old,next,std::memory_order_acq_rel));
    return next;
  }
  bool publish(uint64_t token,uid_t uid){
    const auto value=(token&0xffffffff00000000ULL)|(uid>=500?uint32_t(uid):unknown);
    return snapshot.compare_exchange_strong(token,value,std::memory_order_release,std::memory_order_relaxed);
  }
  uid_t current()const{return uid_t(uint32_t(snapshot.load(std::memory_order_acquire)));}
};
class ConsoleUserMonitor {
  SCDynamicStoreRef store=nullptr;
  dispatch_queue_t notifications=nullptr;
  static void read(SCDynamicStoreRef source,const std::shared_ptr<ConsoleUserState>& state,uint64_t token){
    uid_t uid=ConsoleUserState::unknown;
    auto user=SCDynamicStoreCopyConsoleUser(source,&uid,nullptr);
    if(user)CFRelease(user);else uid=ConsoleUserState::unknown;
    state->publish(token,uid);
  }
  static void changed(SCDynamicStoreRef source,CFArrayRef,void *context){
    auto state=*static_cast<std::shared_ptr<ConsoleUserState>*>(context);
    const auto token=state->invalidate();
    // A missing/changed console identity fails closed while the new value is fetched.
    // An empty change list (configd restart) follows the same invalidation path.
    CFRetain(source);
    dispatch_async(state->worker,^{read(source,state,token);CFRelease(source);});
  }
 public:
  std::shared_ptr<ConsoleUserState> state=std::make_shared<ConsoleUserState>();
  ConsoleUserMonitor()=default;
  ConsoleUserMonitor(const ConsoleUserMonitor&)=delete;
  ConsoleUserMonitor& operator=(const ConsoleUserMonitor&)=delete;
  ~ConsoleUserMonitor(){if(store){SCDynamicStoreSetDispatchQueue(store,nullptr);CFRelease(store);}}
  uid_t current()const{return state->current();}
  bool start(){
    if(store)return true;
    SCDynamicStoreContext context{};context.info=&state;
    context.retain=[](const void *p)->const void*{return new std::shared_ptr<ConsoleUserState>(*static_cast<const std::shared_ptr<ConsoleUserState>*>(p));};
    context.release=[](const void *p){delete static_cast<const std::shared_ptr<ConsoleUserState>*>(p);};
    store=SCDynamicStoreCreate(nullptr,CFSTR("myEq console ownership"),changed,&context);
    if(!store)return false;
    auto key=SCDynamicStoreKeyCreateConsoleUser(nullptr);
    if(!key){CFRelease(store);store=nullptr;return false;}
    const void *keys[]={key};auto list=CFArrayCreate(nullptr,keys,1,&kCFTypeArrayCallBacks);CFRelease(key);
    if(!list){CFRelease(store);store=nullptr;return false;}
    notifications=dispatch_queue_create("com.tc.myEq.console.notifications",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    bool ok=SCDynamicStoreSetNotificationKeys(store,list,nullptr)&&SCDynamicStoreSetDispatchQueue(store,notifications);
    CFRelease(list);
    if(!ok){CFRelease(store);store=nullptr;return false;}
    // Initial IPC is confined to process startup, before any audio session is admitted.
    auto initial=state;auto source=store;const auto token=initial->invalidate();
    dispatch_sync(initial->worker,^{read(source,initial,token);});
    return true;
  }
};
}
