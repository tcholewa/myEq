#include "../../Driver/Driver.mm"
#include <cassert>
#include <iostream>
static std::vector<std::string> nameNotifications;
static void *pendingConfiguration=nullptr;
static bool rejectConfiguration=false;
static std::string readString(AudioObjectID object,AudioObjectPropertySelector selector){
  AudioObjectPropertyAddress property{selector,kAudioObjectPropertyScopeGlobal,0};
  UInt32 size=0;CFStringRef value=nullptr;
  assert(propertySize(driver,object,0,&property,0,nullptr,&size)==noErr&&size==sizeof(value));
  assert(get(driver,object,0,&property,0,nullptr,sizeof(value),&size,&value)==noErr);
  std::string result=[(__bridge NSString*)value UTF8String];CFRelease(value);return result;
}
static void completeConfiguration(){
  assert(pendingConfiguration);auto next=pendingConfiguration;pendingConfiguration=nullptr;
  assert(perform(driver,device,1,next)==noErr);
}
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
  realtime=shared->s;shared->s->active=1;shared->s->deadline=now()+NSEC_PER_SEC;
  float samples[32]{};AudioServerPlugInIOCycleInfo times{};
  times.mOutputTime.mFlags=kAudioTimeStampSampleTimeValid;
  io(driver,device,stream,1,kAudioServerPlugInIOOperationWriteMix,16,&times,samples,nullptr);
  times.mOutputTime.mSampleTime=16;
  io(driver,device,stream,1,kAudioServerPlugInIOOperationWriteMix,16,&times,samples,nullptr);
  assert(shared->s->written==32&&shared->s->discontinuities==0);
  times.mOutputTime.mSampleTime=1000;
  io(driver,device,stream,1,kAudioServerPlugInIOOperationWriteMix,16,&times,samples,nullptr);
  assert(shared->s->written==48&&shared->s->discontinuities==1);
  shared->s->deadline=1;
  io(driver,device,stream,1,kAudioServerPlugInIOOperationWriteMix,16,&times,samples,nullptr);
  assert(shared->s->written==48); // Expiration is enforced in WriteMix, not just a timer.
  realtime=nullptr;

  // Exercise the HAL configuration boundary and notifications, not just formatting.
  AudioServerPlugInHostInterface mockHost{};
  mockHost.PropertiesChanged=[](AudioServerPlugInHostRef,AudioObjectID object,UInt32 count,const AudioObjectPropertyAddress *properties)->OSStatus{
    for(UInt32 i=0;i<count;i++)if(object==device&&properties[i].mSelector==kAudioObjectPropertyName){
      // A host may synchronously read the new value while handling its notification.
      nameNotifications.push_back(readString(device,kAudioObjectPropertyName));
    }
    return noErr;
  };
  mockHost.RequestDeviceConfigurationChange=[](AudioServerPlugInHostRef,AudioObjectID object,UInt64 action,void *info)->OSStatus{
    assert(object==device&&action==1&&!pendingConfiguration);
    if(rejectConfiguration)return kAudioHardwareIllegalOperationError;
    pendingConfiguration=info;return noErr;
  };
  host=&mockHost;control=dispatch_queue_create("com.tc.myEq.driver.test",DISPATCH_QUEUE_SERIAL);
  dispatch_queue_set_specific(control,&controlKey,&controlKey,nullptr);
  assert(readString(device,kAudioObjectPropertyName)=="myEq");
  configure(shared,nil,nil,nameForOutput("ADAM Audio D3V"));
  assert(readString(device,kAudioObjectPropertyName)=="myEq"&&nameNotifications.empty());
  completeConfiguration();
  assert(readString(device,kAudioObjectPropertyName)=="myEq: ADAM Audio D3V");
  assert(nameNotifications==std::vector<std::string>{"myEq: ADAM Audio D3V"});
  assert(readString(device,kAudioDevicePropertyDeviceUID)=="com.tc.myEq.output");
  assert(readString(device,kAudioObjectPropertyManufacturer)=="myEq");
  assert(readString(stream,kAudioObjectPropertyName)=="System stereo mix");
  configure(shared,nil,nil,nameForOutput("ADAM Audio D3V"));completeConfiguration();
  assert(nameNotifications.size()==1);
  configure(shared,nil,nil,nameForOutput("Słuchawki 🎧"));completeConfiguration();
  assert(readString(device,kAudioObjectPropertyName)=="myEq: Słuchawki 🎧"&&nameNotifications.size()==2);
  rejectConfiguration=true;configure(shared,nil,nil,nameForOutput("Rejected output"));rejectConfiguration=false;
  assert(readString(device,kAudioObjectPropertyName)=="myEq: Słuchawki 🎧"&&nameNotifications.size()==2);
  configure(shared,nil,nil,nameForOutput("Aborted output"));
  assert(interface.AbortDeviceConfigurationChange(driver,device,1,pendingConfiguration)==noErr);pendingConfiguration=nullptr;
  assert(readString(device,kAudioObjectPropertyName)=="myEq: Słuchawki 🎧"&&nameNotifications.size()==2);
  configure(nullptr);completeConfiguration();
  assert(readString(device,kAudioObjectPropertyName)=="myEq"&&nameNotifications.size()==3);
  assert(readString(device,kAudioDevicePropertyDeviceUID)=="com.tc.myEq.output");
  assert([nameForOutput(nullptr) isEqualToString:@"myEq"]);
  assert([nameForOutput("") isEqualToString:@"myEq"]);
  assert([nameForOutput("\xff") isEqualToString:@"myEq"]);
  std::cout<<"Output-only driver and dynamic device name checks passed\n";
}}
