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
} MEQTransportHealth;
// Control-thread calls only. Requests have bounded deadlines, never audio-thread IPC.
MEQConnection * _Nullable meq_connect(char * _Nonnull error, size_t capacity);
bool meq_open_transport(MEQConnection * _Null_unspecified, double rate, char * _Nonnull error, size_t capacity);
bool meq_activate_route(MEQConnection * _Null_unspecified, const char * _Nonnull outputUID, char * _Nonnull error, size_t capacity);
// Returns 1: healthy, 0: failure, 2: manual bypass, 3: destination disconnected.
int meq_heartbeat(MEQConnection * _Null_unspecified, char * _Nonnull error, size_t capacity);
void meq_close_transport(MEQConnection * _Nullable);
void meq_disconnect(MEQConnection * _Nullable);
MEQRenderer * _Nullable meq_renderer_create(MEQConnection * _Null_unspecified, MEQDSP * _Nonnull, double rate,
  uint32_t bufferFrames, MEQChannel left, MEQChannel right, char * _Nonnull error, size_t capacity);
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
