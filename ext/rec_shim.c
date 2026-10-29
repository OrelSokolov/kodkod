/* rec_shim.c — mono PCM16 microphone capture bridge for kodkod's
 * voice input, over the vendored miniaudio (ported from perevodilka's
 * rec_shim). A single capture device fills a lock-free SPSC ring
 * (producer = the audio callback, consumer = the reader thread),
 * all ring memory is malloc'd once at start.
 *
 *   kodkod_rec_start(rate, buffer_ms)   open the device + ring
 *   kodkod_rec_read(out, frames)        drain up to `frames` frames
 *   kodkod_rec_available                frames currently queued
 *   kodkod_rec_captured                 total frames seen by the callback
 *   kodkod_rec_dropped                  frames lost to a full ring
 *   kodkod_rec_stop                     device down + free
 *
 * When the ring is full the callback DROPS the overflow (never
 * overwrites un-consumed audio) and counts it — a UI stall shows up as
 * kodkod_rec_dropped() growth, not as a corrupted recording.
 */

#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

#include "miniaudio.h"

static ma_device g_device;
static int g_running = 0;
static int g_rate = 0;
static short *g_ring = NULL;
static unsigned g_ring_frames = 0; /* power of two */

static atomic_size_t g_head;     /* consumer position (free-running) */
static atomic_size_t g_tail;     /* producer position (free-running) */
static atomic_size_t g_captured; /* total frames from the device */
static atomic_size_t g_dropped;  /* frames lost to a full ring */

static unsigned ring_count(void) {
  size_t head = atomic_load_explicit(&g_head, memory_order_acquire);
  size_t tail = atomic_load_explicit(&g_tail, memory_order_acquire);
  return (unsigned)((tail - head) & (size_t)(g_ring_frames - 1));
}

static unsigned ring_free(void) {
  size_t head = atomic_load_explicit(&g_head, memory_order_acquire);
  size_t tail = atomic_load_explicit(&g_tail, memory_order_acquire);
  return (unsigned)((head - tail - 1) & (size_t)(g_ring_frames - 1));
}

static void data_callback(ma_device *pDevice, void *pOutput, const void *pInput,
                          ma_uint32 frameCount) {
  (void)pDevice;
  (void)pOutput;
  const short *in = (const short *)pInput;
  unsigned frames = frameCount;
  unsigned dropped = 0;

  while (frames > 0) {
    unsigned space = ring_free();
    if (space == 0) {
      dropped += frames;
      break;
    }
    unsigned n = frames < space ? frames : space;
    size_t tail = atomic_load_explicit(&g_tail, memory_order_relaxed);
    size_t pos = tail & (size_t)(g_ring_frames - 1);
    unsigned first = (unsigned)(g_ring_frames - pos);
    if (first > n)
      first = n;
    memcpy(g_ring + pos, in, (size_t)first * sizeof(short));
    if (n > first)
      memcpy(g_ring, in + first, (size_t)(n - first) * sizeof(short));
    atomic_store_explicit(&g_tail, tail + n, memory_order_release);
    in += n;
    frames -= n;
  }

  if (dropped)
    atomic_fetch_add_explicit(&g_dropped, dropped, memory_order_relaxed);
  atomic_fetch_add_explicit(&g_captured, frameCount, memory_order_relaxed);
}

int kodkod_rec_start(int rate, unsigned buffer_ms) {
  if (g_running)
    return g_rate == rate ? 0 : -1; /* caller must stop() a different rate */
  g_rate = rate;

  unsigned frames = (unsigned)rate * buffer_ms / 1000;
  unsigned p2 = 1;
  while (p2 < frames)
    p2 <<= 1;
  g_ring_frames = p2;
  g_ring = (short *)malloc((size_t)p2 * sizeof(short));
  if (!g_ring)
    return -1;
  atomic_store(&g_head, 0);
  atomic_store(&g_tail, 0);
  atomic_store(&g_captured, 0);
  atomic_store(&g_dropped, 0);

  ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
  cfg.sampleRate = (ma_uint32)rate;
  cfg.capture.format = ma_format_s16;
  cfg.capture.channels = 1;
  cfg.dataCallback = data_callback;

  if (ma_device_init(NULL, &cfg, &g_device) != MA_SUCCESS) {
    free(g_ring);
    g_ring = NULL;
    return -2;
  }
  if (ma_device_start(&g_device) != MA_SUCCESS) {
    ma_device_uninit(&g_device);
    free(g_ring);
    g_ring = NULL;
    return -3;
  }
  g_running = 1;
  return 0;
}

/* Drains up to `frames` frames into `out`; returns the count moved. */
unsigned kodkod_rec_read(short *out, unsigned frames) {
  if (!g_running)
    return 0;
  unsigned read = 0;
  while (read < frames) {
    unsigned avail = ring_count();
    if (avail == 0)
      break;
    unsigned n = frames - read;
    if (n > avail)
      n = avail;
    size_t head = atomic_load_explicit(&g_head, memory_order_relaxed);
    size_t pos = head & (size_t)(g_ring_frames - 1);
    unsigned first = (unsigned)(g_ring_frames - pos);
    if (first > n)
      first = n;
    memcpy(out + read, g_ring + pos, (size_t)first * sizeof(short));
    if (n > first)
      memcpy(out + read + first, g_ring, (size_t)(n - first) * sizeof(short));
    atomic_store_explicit(&g_head, head + n, memory_order_release);
    read += n;
  }
  return read;
}

unsigned kodkod_rec_available(void) { return g_running ? ring_count() : 0; }
unsigned kodkod_rec_captured(void) {
  return g_running ? (unsigned)atomic_load(&g_captured) : 0;
}
unsigned kodkod_rec_dropped(void) {
  return g_running ? (unsigned)atomic_load(&g_dropped) : 0;
}

void kodkod_rec_stop(void) {
  if (g_running) {
    ma_device_uninit(&g_device);
    free(g_ring);
    g_ring = NULL;
    g_running = 0;
    g_rate = 0;
  }
}
