// Fresh Core Audio client: enqueue silence to the already active myEq output.
// Never changes defaults, enables EQ, records audio, or controls another app.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <unistd.h>

static bool activeDefault() {
  AudioObjectPropertyAddress property{kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,0};
  AudioDeviceID device=0;UInt32 size=sizeof(device);
  if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&property,0,nullptr,&size,&device))return false;
  property.mSelector=kAudioDevicePropertyDeviceUID;CFStringRef uid=nullptr;size=sizeof(uid);
  if(AudioObjectGetPropertyData(device,&property,0,nullptr,&size,&uid)||!uid)return false;
  bool matches=CFEqual(uid,CFSTR("com.tc.myEq.output"));CFRelease(uid);
  property.mSelector=kAudioDevicePropertyDeviceIsAlive;UInt32 alive=0;size=sizeof(alive);
  return matches&&AudioObjectGetPropertyData(device,&property,0,nullptr,&size,&alive)==noErr&&alive;
}
struct State {
  std::atomic<unsigned> callbacks{0};
  std::atomic<OSStatus> error{noErr};
  std::atomic<bool> stopping{false};
};
static void refill(void *context,AudioQueueRef queue,AudioQueueBufferRef buffer) {
  auto state=static_cast<State*>(context);
  if(state->stopping)return;
  state->callbacks.fetch_add(1);
  auto status=AudioQueueEnqueueBuffer(queue,buffer,0,nullptr);
  if(status)state->error=status;
}
static bool play(double rate) {
  State state;AudioQueueRef queue=nullptr;
  AudioStreamBasicDescription format{rate,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,8,1,8,2,32,0};
  OSStatus status=AudioQueueNewOutput(&format,refill,&state,nullptr,nullptr,0,&queue);
  CFStringRef uid=CFSTR("com.tc.myEq.output");
  if(!status)status=AudioQueueSetProperty(queue,kAudioQueueProperty_CurrentDevice,&uid,sizeof(uid));
  for(int i=0;i<3&&!status;i++){
    AudioQueueBufferRef buffer=nullptr;
    status=AudioQueueAllocateBuffer(queue,1024*format.mBytesPerFrame,&buffer);
    if(!status){buffer->mAudioDataByteSize=buffer->mAudioDataBytesCapacity;memset(buffer->mAudioData,0,buffer->mAudioDataByteSize);status=AudioQueueEnqueueBuffer(queue,buffer,0,nullptr);}
  }
  if(!status)status=AudioQueueStart(queue,nullptr);
  AudioTimeStamp time{};
  if(!status){
    usleep(1500000);
    status=AudioQueueGetCurrentTime(queue,nullptr,&time,nullptr);
  }
  state.stopping=true;
  if(queue){AudioQueueStop(queue,true);AudioQueueDispose(queue,true);}
  bool passed=status==noErr&&state.error==noErr&&state.callbacks>5&&
    (time.mFlags&kAudioTimeStampSampleTimeValid)&&std::isfinite(time.mSampleTime)&&time.mSampleTime>rate/2&&activeDefault();
  printf("%s: %.0f Hz client, startup/time status %d, enqueue status %d, %u callbacks, sample time %.0f\n",
    passed?"PASS":"FAIL",rate,status,state.error.load(),state.callbacks.load(),time.mSampleTime);
  return passed;
}
int main(){
  if(!activeDefault()){fprintf(stderr,"Enable myEq before this check. No audio route was changed.\n");return 78;}
  for(double rate:{44100.,48000.,96000.})if(!play(rate))return 1;
  puts("Fresh AudioQueue clients play through the active virtual output; default route preserved.");
}
