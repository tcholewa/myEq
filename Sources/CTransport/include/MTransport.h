#ifndef MYEQ_TRANSPORT_H
#define MYEQ_TRANSPORT_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <CoreAudio/CoreAudio.h>
#include <CDSP.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MEQConnection MEQConnection;
typedef struct MEQRenderer MEQRenderer;
typedef struct {
  uint64_t callbacks, underruns, overruns, discontinuities, invalidSamples;
  uint32_t bufferedFrames;
  double correction;
  bool connected;
  // Renderer-local diagnostics; not part of the shared-memory protocol.
  uint32_t observedBurstFrames, targetFrames;
  uint64_t shortReads, converterErrors;
  OSStatus lastConverterStatus;
} MEQTransportHealth;
typedef struct {uint64_t callbacks, maximumNS, overHalfPeriod, overPeriod;} MEQRenderTiming;
// Opt-in MYEQ_RENDER_TIMING=1, configured before renderer creation; control-reader only.
MEQRenderTiming meq_render_timing(MEQRenderer * _Nullable);
// Bounded, descriptor-validated persistence. Caller frees successful read buffers.
int meq_read_settings(const char * _Nonnull path, uint8_t * _Nullable * _Nonnull bytes, size_t * _Nonnull length);
bool meq_write_settings(const char * _Nonnull path, const uint8_t * _Nonnull bytes, size_t length);
bool meq_installation_id(char * _Nonnull value, size_t capacity);
// Control-thread calls only. Requests have bounded deadlines, never audio-thread IPC.
MEQConnection * _Nullable meq_connect(char * _Nonnull error, size_t capacity, bool * _Nonnull retryable);
bool meq_open_transport(MEQConnection * _Null_unspecified, double rate, const char * _Nonnull outputName, char * _Nonnull error, size_t capacity, bool * _Nonnull retryable);
bool meq_prepare_buffers(MEQConnection * _Null_unspecified, const char * _Nonnull outputUID, bool apply, char * _Nonnull error, size_t capacity, bool * _Nonnull retryable);
bool meq_activate_route(MEQConnection * _Null_unspecified, const char * _Nonnull outputUID, char * _Nonnull error, size_t capacity, bool * _Nonnull retryable);
// Returns 1: healthy, 0: failure, 2: manual bypass, 3: destination disconnected.
int meq_heartbeat(MEQConnection * _Null_unspecified, char * _Nonnull error, size_t capacity, bool * _Nonnull retryable);
void meq_close_transport(MEQConnection * _Nullable);
void meq_disconnect(MEQConnection * _Nullable);
MEQRenderer * _Nullable meq_renderer_create(MEQConnection * _Null_unspecified, MEQDSP * _Nonnull, double rate,
  uint32_t bufferFrames, uint32_t sourceFrames, MEQChannel left, MEQChannel right, char * _Nonnull error, size_t capacity);
// Control queue publishes source quantum changes; the callback consumes them atomically.
bool meq_renderer_set_source_frames(MEQRenderer * _Nullable, uint32_t sourceFrames);
void meq_renderer_destroy(MEQRenderer * _Nullable);
MEQTransportHealth meq_transport_health(MEQRenderer * _Nullable);
OSStatus meq_output_callback(AudioObjectID, const AudioTimeStamp * _Nonnull, const AudioBufferList * _Nonnull,
  const AudioTimeStamp * _Nonnull, AudioBufferList * _Nonnull, const AudioTimeStamp * _Nonnull, void * _Nullable);
// Exchanges hardware volume controls; no digital gain is applied in the driver.
bool meq_volume_request(MEQConnection * _Null_unspecified, float * _Nonnull volume, bool * _Nonnull muted);
void meq_volume_state(MEQConnection * _Null_unspecified, bool volumeSupported, bool muteSupported,
  float volume, bool muted);
#ifdef __cplusplus
}
#endif
#endif
