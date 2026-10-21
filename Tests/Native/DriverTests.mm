#include "../../Driver/Driver.mm"
#include <cassert>
#include <iostream>
int main(){@autoreleasepool{
  setup();UInt32 size=0;AudioObjectID objects[4]{};
  AudioObjectPropertyAddress property{kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput,0};
  assert(get(driver,device,0,&property,0,nullptr,sizeof(objects),&size,objects)==noErr&&size==0);
  property.mScope=kAudioObjectPropertyScopeOutput;
  assert(get(driver,device,0,&property,0,nullptr,sizeof(objects),&size,objects)==noErr&&size==4&&objects[0]==stream);
  property.mSelector=kAudioStreamPropertyDirection;UInt32 direction=99;
  assert(get(driver,stream,0,&property,0,nullptr,4,&size,&direction)==noErr&&direction==0);
  property.mSelector=kAudioDevicePropertyDeviceIsAlive;UInt32 isAlive=99;
  assert(get(driver,device,0,&property,0,nullptr,4,&size,&isAlive)==noErr&&isAlive==0);
  Boolean performs=false,inPlace=false;
  will(driver,device,1,kAudioServerPlugInIOOperationWriteMix,&performs,&inPlace);assert(performs&&inPlace);
  will(driver,device,1,kAudioServerPlugInIOOperationReadInput,&performs,&inPlace);assert(!performs);
  property.mSelector=kAudioDevicePropertyNominalSampleRate;Boolean can=true;
  assert(settable(driver,device,0,&property,&can)==noErr&&!can);
  assert(get(driver,device,0,&property,0,nullptr,1,&size,objects)==kAudioHardwareBadPropertySizeError);
  auto shared=std::make_shared<Mapping>();assert(shared->create(48000,10));
  realtime=shared->s;shared->s->active=1;
  float samples[32]{};AudioServerPlugInIOCycleInfo times{};
  times.mOutputTime.mFlags=kAudioTimeStampSampleTimeValid;
  io(driver,device,stream,1,kAudioServerPlugInIOOperationWriteMix,16,&times,samples,nullptr);
  times.mOutputTime.mSampleTime=16;
  io(driver,device,stream,1,kAudioServerPlugInIOOperationWriteMix,16,&times,samples,nullptr);
  assert(shared->s->written==32&&shared->s->discontinuities==0);
  times.mOutputTime.mSampleTime=1000;
  io(driver,device,stream,1,kAudioServerPlugInIOOperationWriteMix,16,&times,samples,nullptr);
  assert(shared->s->written==48&&shared->s->discontinuities==1);
  realtime=nullptr;
  std::cout<<"Output-only driver contract checks passed\n";
}}
