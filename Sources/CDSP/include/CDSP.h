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
typedef struct { float peakLeft, peakRight, reduction; uint64_t callbacks, faults; } MEQMeter;
MEQDSP *_Null_unspecified meq_create(void);
void meq_destroy(MEQDSP *_Null_unspecified dsp);
// prepare/layout require a stopped audio callback. submit is single-producer.
bool meq_prepare(MEQDSP *_Null_unspecified , double rate, const MEQBand *_Null_unspecified , int count, double preamp);
bool meq_submit(MEQDSP *_Null_unspecified , const MEQBand *_Null_unspecified , int count, double preamp);
void meq_layout(MEQDSP *_Null_unspecified , MEQChannel inL, MEQChannel inR, MEQChannel outL, MEQChannel outR);
void meq_process(MEQDSP *_Null_unspecified , float *_Null_unspecified interleavedStereo, uint32_t frames);
MEQMeter meq_meter(MEQDSP *_Null_unspecified );
// Single meter consumer: atomically drain stereo peaks since the previous read.
// Health/statistics readers use meq_meter instead, which does not drain peaks.
MEQMeter meq_take_meter(MEQDSP *_Null_unspecified );
double meq_response(const MEQBand *_Null_unspecified , int count, double frequency, double rate);
OSStatus meq_audio_callback(AudioObjectID, const AudioTimeStamp * _Nonnull, const AudioBufferList * _Nonnull, const AudioTimeStamp * _Nonnull, AudioBufferList * _Nonnull, const AudioTimeStamp * _Nonnull, void * _Nullable);
#ifdef __cplusplus
}
#endif
#endif
