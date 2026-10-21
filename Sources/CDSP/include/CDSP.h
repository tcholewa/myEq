#ifndef MYEQ_DSP_H
#define MYEQ_DSP_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MEQDSP MEQDSP;
// 0: bell, 1: low shelf, 2: high shelf, 3: low cut, 4: high cut.
typedef struct { int32_t type; bool enabled; double frequency, gain, width; } MEQBand;
typedef struct { int32_t buffer, channel, stride; } MEQChannel;
typedef struct { float peak, reduction; uint64_t callbacks, faults; } MEQMeter;
MEQDSP *meq_create(void);
void meq_destroy(MEQDSP *dsp);
// prepare/layout require a stopped audio callback. submit is single-producer.
bool meq_prepare(MEQDSP *, double rate, const MEQBand *, int count, double preamp);
bool meq_submit(MEQDSP *, const MEQBand *, int count, double preamp);
void meq_layout(MEQDSP *, MEQChannel inL, MEQChannel inR, MEQChannel outL, MEQChannel outR);
void meq_process(MEQDSP *, float *interleavedStereo, uint32_t frames);
MEQMeter meq_meter(MEQDSP *);
double meq_response(const MEQBand *, int count, double frequency, double rate);
OSStatus meq_audio_callback(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *, const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *);
#ifdef __cplusplus
}
#endif
#endif
