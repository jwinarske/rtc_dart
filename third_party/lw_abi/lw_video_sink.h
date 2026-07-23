/*
 * lw_video_sink.h — dmabuf zero-copy video data-plane ABI (v1).
 *
 * Single definition of the decoded-frame descriptor and the sink callback
 * table. This one installed header is shared, verbatim, by the libwebrtc
 * core, the hardware decoder, and every presenter. No other definition of
 * LwDmabufDescriptor / LwVideoSinkV1 may exist.
 *
 * This ABI is process-internal and native-to-native: decoded frames travel
 * decoder -> presenter by reference (dmabuf fds), never crossing into a
 * managed runtime. The control side brokers the track -> sink binding only.
 */
#ifndef LW_VIDEO_SINK_H_
#define LW_VIDEO_SINK_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped when the C ABI surface changes incompatibly. Checked at load time
 * between the loader and libwebrtc.so, and against the decoder's shared
 * tree-revision pin. */
#define LW_ABI_VERSION 8

/* Max planes in a single dmabuf frame (e.g. NV12 = 2, I420 = 3). */
#define LW_MAX_PLANES 4

/* One plane of a dmabuf-backed frame.
 *
 * fd is NON-OWNING: owned by the producer (the decoder CAPTURE-queue pool).
 * It is valid only until the matching LwFrameRelease is invoked, and only
 * within a single pool_generation (the kernel reuses fd numbers after a
 * pool is torn down). Consumers MUST NOT close fd. */
typedef struct LwDmabufPlane {
  int32_t fd;      /* non-owning; valid until release_cb */
  uint32_t offset; /* byte offset of this plane within the dmabuf */
  uint32_t pitch;  /* row stride in bytes */
} LwDmabufPlane;

/* A decoded frame, described by reference (zero copy).
 *
 * `size` is sizeof(LwDmabufDescriptor) at the producer's compile time. A
 * consumer built against a different ABI minor MUST check `desc->size`
 * before reading any field beyond it: read min(sizeof(local), desc->size)
 * bytes, treat the remainder as absent. New fields only ever append.
 *
 * `num_planes` is attacker/bug-reachable via the bitstream path upstream;
 * consumers MUST validate `num_planes <= LW_MAX_PLANES` before indexing
 * planes[] rather than trusting it. */
typedef struct LwDmabufDescriptor {
  uint32_t size;     /* sizeof(LwDmabufDescriptor) */
  uint32_t fourcc;   /* DRM_FORMAT_* */
  uint64_t modifier; /* DRM_FORMAT_MOD_* (AFBC/UBWC/linear) */
  uint32_t width, height;
  uint32_t num_planes; /* 1..LW_MAX_PLANES; validate before indexing */
  LwDmabufPlane planes[LW_MAX_PLANES];
  int32_t acquire_fence_fd; /* -1 none; non-owning. Normally -1: DQBUF
                             * implies decode complete. Reserved for
                             * future GPU-producer paths. */
  uint32_t rotation;        /* 0/90/180/270; RTP CVO passthrough */
  int64_t rtp_timestamp_us; /* for A/V sync + latency HUD */
  uint64_t frame_seq;       /* monotonic within a session */
  uint32_t pool_generation; /* increments on pool reallocation; fd numbers
                             * are unique/stable only WITHIN a generation
                             * (kernel reuses fd values after pool close).
                             * Consumers key import caches on this. */
  uint32_t pool_size;       /* buffers in the producer's pool, or 0 if the
                             * producer does not know. A consumer that holds
                             * frames MUST bound what it holds against this:
                             * hold too many and the producer starves waiting
                             * for a buffer to decode into. Pools differ by an
                             * order of magnitude -- a VAAPI surface pool runs
                             * to dozens, a V4L2 CAPTURE pool is often reorder
                             * depth plus pipeline plus one, so eight to ten --
                             * which is why a consumer cannot pick a fixed
                             * depth that suits both. Treat 0 as small. */
} LwDmabufDescriptor;

/* Invoked by the consumer exactly once when it is done with a taken frame
 * (scanout out-fence signaled / wl_buffer.release). Maps to producer
 * re-QBUF. release_ctx is the cookie the producer handed to on_frame. */
typedef void (*LwFrameRelease)(void* release_ctx);

/* The sink callback table. Registered with the sink registry and bound to a
 * track by token.
 *
 * `size` is sizeof(LwVideoSinkV1): forward-compat gate for appended fields.
 * When the function shape must change, introduce LwVideoSinkV2. */
typedef struct LwVideoSinkV1 {
  uint32_t size; /* sizeof(LwVideoSinkV1) */

  /* Called on the DECODER DELIVERY THREAD. MUST be non-blocking and
   * allocation-free (do an SPSC POD handoff of desc + release pair).
   *
   * Consumer either:
   *   - TAKES the frame: stores `desc` BY VALUE, stores
   * `release`+`release_ctx`, returns NONZERO. It now owns exactly one release
   * obligation and MUST call `release(release_ctx)` exactly once.
   *   - DECLINES: returns 0. The producer releases the frame immediately
   *     (latest-wins drop). Declining is THE drop mechanism — it keeps the
   *     decoder unblocked; decode never stalls on presentation. */
  int (*on_frame)(const LwDmabufDescriptor* desc, LwFrameRelease release,
                  void* release_ctx, void* user);

  /* Announces the format/geometry of the generation that is about to begin.
   * ALWAYS precedes the first on_frame of a new pool_generation.
   * NORMATIVE: on this call the consumer MUST invalidate all cached imports
   * from prior generations — fd numbers may be reused by the kernel across
   * pool reallocation and are NOT identity. `fmt_only` carries a valid
   * descriptor with no live fds to import. */
  void (*on_format)(const LwDmabufDescriptor* fmt_only, void* user);

  /* End of stream. No further on_frame for this binding. */
  void (*on_eos)(void* user);
} LwVideoSinkV1;

/*
 * CONTRACT (the header comments above are normative):
 *
 * Ownership:    fds owned by producer. Consumer imports (AddFB2 / wl_buffer /
 *               VkImage) keyed by (pool_generation, planes[0].fd, fourcc,
 *               modifier); caches imports; NEVER closes fds; calls release
 *               exactly once. release -> re-QBUF.
 * Threading:    on_frame on decoder delivery thread; consumer does SPSC
 *               handoff (POD copy), latest-wins. Declining is the drop.
 * Backpressure: pool exhaustion is the only true backpressure (pool sized
 *               reorder + pipeline + 1). HUD watches pool occupancy.
 * Release watchdog (presenter-side, normative): every pending release is
 *               bounded (fence wait w/ timeout ~2 vsync + margin); on expiry
 *               the presenter drops its scanout ref and calls release. The
 *               producer NEVER force-recycles. Producer side raises a
 *               pool-occupancy alarm when occupancy crosses a threshold.
 * Fences:       acquire_fence_fd normally -1. Release timing via KMS
 *               OUT_FENCE_PTR or wl_buffer.release.
 * Evolution:    new fields append; `size` gates; LwVideoSinkV2 when the
 *               function shape must change.
 */

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LW_VIDEO_SINK_H_ */
