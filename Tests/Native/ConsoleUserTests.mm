#include "../../Sources/CTransport/ConsoleUser.hpp"
#include <cassert>
#include <iostream>
using namespace meq;
int main(){@autoreleasepool{
  auto state=std::make_shared<ConsoleUserState>();
  assert(state->current()==ConsoleUserState::unknown);
  auto original=state->invalidate();assert(state->publish(original,501)&&state->current()==501);
  auto changed=state->invalidate();assert(state->current()==ConsoleUserState::unknown);
  assert(!state->publish(original,501));assert(state->publish(changed,502)&&state->current()==502);
  auto missing=state->invalidate();assert(state->publish(missing,0)&&state->current()==ConsoleUserState::unknown);
  // A blocked system query neither blocks cached reads nor republishes after a newer change.
  auto blocked=state->invalidate();auto gate=dispatch_semaphore_create(0);
  dispatch_async(state->worker,^{dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER);assert(!state->publish(blocked,501));});
  auto replacement=state->invalidate();assert(state->publish(replacement,502));
  for(unsigned i=0;i<10000;++i)assert(state->current()==502);
  dispatch_semaphore_signal(gate);dispatch_sync(state->worker,^{});assert(state->current()==502);
  // Configd restart/unknown-owner invalidation cannot preserve prior authorization.
  state->invalidate();assert(state->current()==ConsoleUserState::unknown);
  std::cout<<"Console ownership cached reads, invalidation and stale query rejection passed\n";
}}
