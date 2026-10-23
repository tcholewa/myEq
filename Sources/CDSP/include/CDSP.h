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
// Visual metering defaults off. Safe from the single control/meter-consumer thread
// while audio runs; EQ, limiting, and health counters always continue.
void meq_set_metering_enabled(MEQDSP *_Null_unspecified , bool enabled);
MEQMeter meq_meter(MEQDSP *_Null_unspecified );
// Single meter consumer: atomically drain stereo peaks since the previous read.
// Health/statistics readers use meq_meter instead, which does not drain peaks.
MEQMeter meq_take_meter(MEQDSP *_Null_unspecified );
// Post-processing output visualization. The reader retains storage independently of the stopped/destroyed DSP.
// One control owner changes enable state; one analysis consumer requests/takes snapshots.
typedef struct MEQSpectrumReader MEQSpectrumReader;
typedef struct {uint32_t frames; double sampleRate; uint64_t epoch, sequence, capturedNS;} MEQSpectrumSnapshot;
typedef struct {uint64_t capturedBlocks, published, dropped;} MEQSpectrumStats;
MEQSpectrumReader * _Nullable meq_spectrum_reader_create(MEQDSP * _Nonnull);
void meq_spectrum_reader_destroy(MEQSpectrumReader * _Nullable);
void meq_spectrum_set_enabled(MEQSpectrumReader * _Nonnull, bool enabled);
void meq_spectrum_request(MEQSpectrumReader * _Nonnull);
MEQSpectrumSnapshot meq_spectrum_format(MEQSpectrumReader * _Nonnull);
bool meq_spectrum_take(MEQSpectrumReader * _Nonnull, float * _Nonnull stereo, uint32_t capacityFrames, MEQSpectrumSnapshot * _Nonnull);
MEQSpectrumStats meq_spectrum_stats(MEQSpectrumReader * _Nonnull);
double meq_response(const MEQBand *_Null_unspecified , int count, double frequency, double rate);
OSStatus meq_audio_callback(AudioObjectID, const AudioTimeStamp * _Nonnull, const AudioBufferList * _Nonnull, const AudioTimeStamp * _Nonnull, AudioBufferList * _Nonnull, const AudioTimeStamp * _Nonnull, void * _Nullable);
#ifdef __cplusplus
}
#endif
#endif
