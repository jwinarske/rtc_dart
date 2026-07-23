/*
 * lw_c_api.h — flat C control-plane ABI for libwebrtc.so.
 *
 * Dart-loadable (dart:ffi) and C++-consumable surface over the subset of the
 * wrapper the data plane needs. This first slice covers the video sink
 * registry: presenters register an LwVideoSinkV1 and bind it to a video track
 * by an unguessable token, after which native (dmabuf) frames flow to the sink
 * native-to-native (see lw_video_sink.h). More of the control plane is added
 * here incrementally.
 */
#ifndef LW_C_API_H_
#define LW_C_API_H_

#include <stddef.h>
#include <stdint.h>

#include "lw_video_sink.h"

#if defined(_WIN32)
#define LW_C_API __declspec(dllexport)
#else
#define LW_C_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a peer-connection factory. */
typedef struct lw_factory lw_factory_t;

/* ---- Lifecycle -------------------------------------------------------- */

/* Returns the ABI version the loaded library was built against. A caller
 * compares this to its own LW_ABI_VERSION at load time. */
LW_C_API int lw_abi_version(void);

/* Global init/teardown. lw_initialize returns nonzero on success and must be
 * called once before creating a factory; lw_terminate is called after all
 * handles have been released. Both are thread-safe. */
LW_C_API int lw_initialize(void);
LW_C_API void lw_terminate(void);

/* ---- Factory ---------------------------------------------------------- */

/* Creates a peer-connection factory. Returns NULL on failure; the handle owns
 * one reference (retire it with lw_release). Call lw_factory_initialize before
 * using it. */
LW_C_API lw_factory_t* lw_factory_create(void);

/* Initializes a factory. Returns nonzero on success. */
LW_C_API int lw_factory_initialize(lw_factory_t* factory);

/* ---- Handle reference counting ---------------------------------------- */

/* Retain/release any lw_* handle (all map to the shared RefCountInterface).
 * One pair covers every handle type. Null handles are ignored. Handles may be
 * released in any order: each keeps the factory it came from alive. */
LW_C_API void lw_retain(void* handle);
LW_C_API void lw_release(void* handle);

/* ---- Callback string payloads ----------------------------------------- */

/* Frees a payload delivered to a callback below. Every `char*` a callback
 * receives is owned by the callback, which passes it here once done. NULL is
 * ignored.
 *
 * Data channel messages come this way too. They are length-delimited, since a
 * binary message may contain zero bytes, but a NUL is appended past the length
 * so a text message can also be read as a C string. */
LW_C_API void lw_string_free(char* s);

/* ---- Video sink registry ---------------------------------------------- */

/* Opaque handle to a video track, produced by the control-plane shim. */
typedef struct lw_video_track lw_video_track_t;

/* Unguessable, nonzero handle to a registered video sink. 0 is invalid. */
typedef uint64_t lw_video_sink_token;

/* Registers a native video sink. `sink` and `user` are caller-owned and MUST
 * outlive the binding (they are referenced, not copied). Returns an
 * unguessable token, or 0 on failure (null/invalid sink). */
LW_C_API lw_video_sink_token lw_video_sink_register(const LwVideoSinkV1* sink,
                                                    void* user);

/* Unregisters a sink token. Returns 0 on success, negative if unknown. Does
 * not unbind: unbind the track first (lw_video_track_unbind_sink). */
LW_C_API int lw_video_sink_unregister(lw_video_sink_token token);

/* Binds a registered sink to a video track; native frames on the track are
 * then delivered to the sink. Returns 0 on success, negative on error
 * (null/unknown track, unknown token). */
LW_C_API int lw_video_track_bind_sink(lw_video_track_t* track,
                                      lw_video_sink_token token);

/* Unbinds any native sink from a track. Quiesces: blocks until an in-flight
 * on_frame returns, and emits on_eos to the previously-bound sink. Returns 0
 * on success, negative on error. */
LW_C_API int lw_video_track_unbind_sink(lw_video_track_t* track);

/* Per-decoded-frame callback (fires on the decoder delivery thread) reporting
 * the frame's pixel dimensions. For counting/telemetry only -- the frame
 * itself never crosses here (native frames flow through the sink registry).
 * Must return promptly and must not re-enter the track API (it runs on the
 * delivery path). Pass cb = NULL to clear. */
typedef void (*lw_frame_cb)(int width, int height, void* user);
LW_C_API int lw_video_track_set_frame_callback(lw_video_track_t* track,
                                               lw_frame_cb cb, void* user);

/* ---- Peer connection / transceiver / receiver ------------------------- */

/* Opaque handles produced by the calls below. */
typedef struct lw_pc lw_pc_t;
typedef struct lw_transceiver lw_transceiver_t;
typedef struct lw_receiver lw_receiver_t;

/* Media kind for a transceiver. */
typedef enum lw_media_type {
  LW_MEDIA_AUDIO = 0,
  LW_MEDIA_VIDEO = 1,
  LW_MEDIA_DATA = 2,
} lw_media_type;

/* Creates a peer connection on `factory` with a default configuration.
 * Returns NULL on failure; the handle owns one reference (lw_release). */
LW_C_API lw_pc_t* lw_pc_create(lw_factory_t* factory);

/* Closes a peer connection. The handle stays valid until lw_release. */
LW_C_API void lw_pc_close(lw_pc_t* pc);

/* Adds a transceiver of `media_type` (default direction). Returns NULL on
 * failure; the handle owns one reference. */
LW_C_API lw_transceiver_t* lw_pc_add_transceiver(lw_pc_t* pc,
                                                 lw_media_type media_type);

/* Returns the transceiver's receiver, or NULL. Handle owns one reference. */
LW_C_API lw_receiver_t* lw_transceiver_receiver(lw_transceiver_t* transceiver);

/* Returns the receiver's video track as a handle bindable with
 * lw_video_track_bind_sink, or NULL if the receiver has no video track. Handle
 * owns one reference. */
LW_C_API lw_video_track_t* lw_receiver_video_track(lw_receiver_t* receiver);

/* ---- Local video ------------------------------------------------------ */

/* Opaque handles for the send side. */
typedef struct lw_video_source lw_video_source_t;
typedef struct lw_sender lw_sender_t;

/* Creates a video source that frames are pushed into, rather than one driven
 * by a capture device. `label` is a diagnostic name and may be NULL. Returns
 * NULL on failure; the handle owns one reference. */
LW_C_API lw_video_source_t* lw_factory_create_video_source(
    lw_factory_t* factory, const char* label);

/* Pushes one I420 frame into a source. `data` holds width*height*3/2 bytes:
 * the Y plane, then U, then V, each tightly packed. The data is copied, so it
 * need not outlive the call. Returns 0 on success, negative on error (null
 * handle, bad dimensions, or a size that does not match them).
 *
 * Frames are consumed at whatever rate they are pushed; the caller sets the
 * pace. */
LW_C_API int lw_video_source_push_i420(lw_video_source_t* source, int width,
                                       int height, const uint8_t* data,
                                       size_t size);

/* Creates a local video track fed by `source`.
 *
 * `id` becomes the track's id in the SDP and must be a non-empty string: an
 * empty one produces an "a=msid:<stream> " line with nothing after the space,
 * which the far side rejects when parsing the session description. That
 * failure names the msid attribute and says nothing about the track, so it is
 * refused here instead. Returns NULL on failure; the handle owns one
 * reference. */
LW_C_API lw_video_track_t* lw_factory_create_video_track(
    lw_factory_t* factory, lw_video_source_t* source, const char* id);

/* Attaches a local track to a peer connection, in the streams named by
 * `stream_ids` (may be NULL when `stream_id_count` is 0). Returns the sender,
 * or NULL on failure; the handle owns one reference. */
LW_C_API lw_sender_t* lw_pc_add_track(lw_pc_t* pc, lw_video_track_t* track,
                                      const char* const* stream_ids,
                                      size_t stream_id_count);

/* Enables or disables a track. A disabled track still flows, but carries
 * black frames -- this is mute, not removal. Works on local and remote tracks
 * alike. Returns 0 on success, negative on error. */
LW_C_API int lw_video_track_set_enabled(lw_video_track_t* track, int enabled);

/* Whether a track is enabled. Returns 1, 0, or negative on error. */
LW_C_API int lw_video_track_enabled(lw_video_track_t* track);

/* ---- Pipeline counters ------------------------------------------------ */

/* Per-track frame counters, cheap enough to read every frame: they are plain
 * counters, read without taking the lock the delivery path holds.
 *
 * These describe the local pipeline -- what the decoder produced and where it
 * went. They say nothing about the network; RTP, RTCP, ICE and DTLS statistics
 * are gathered asynchronously by the library and are a separate request.
 *
 * Rates are deliberately absent. Two samples and the elapsed time between them
 * give a rate over whatever window the caller wants, where a rate computed
 * here would impose one. */
typedef struct LwVideoTrackStats {
  uint32_t size; /* sizeof(LwVideoTrackStats) */
  uint32_t reserved;
  /* Every decoded frame the track delivered, whatever path it then took. */
  uint64_t frames_delivered;
  /* Delivered as a dmabuf to a bound sink, which the sink took. */
  uint64_t frames_native;
  /* Delivered through the software path: no native buffer, so the frame was
   * converted. Nonzero means the zero-copy path is not in use. */
  uint64_t frames_cpu;
  /* Native frames that reached no sink: none bound, the sink declined, or the
   * buffer was some other implementation's native type. */
  uint64_t frames_dropped;
  /* Geometry of the most recent frame, or 0 before the first. */
  uint32_t last_width;
  uint32_t last_height;
  /* CLOCK_MONOTONIC microseconds at the most recent frame, or 0 before the
   * first. Paired with frames_delivered across two calls, this gives a rate. */
  int64_t last_frame_us;
} LwVideoTrackStats;

/* Fills `out` with the track's counters. `out->size` must be set by the caller
 * to sizeof(LwVideoTrackStats) before the call. Returns 0 on success, negative
 * on error (null or non-video track, missing or mismatched size). */
LW_C_API int lw_video_track_get_stats(lw_video_track_t* track,
                                      LwVideoTrackStats* out);

/* ---- SDP negotiation -------------------------------------------------- */

/* Completion callbacks for the async SDP operations below. They are invoked on
 * the signaling thread. `user` is the opaque cookie passed to the originating
 * call.
 *
 * String payloads are owned by the callback and stay valid after it returns,
 * so a consumer that has to hand the payload to another thread before reading
 * it can do so; retire each with lw_string_free. Nothing is allocated for a
 * NULL callback. A payload may be NULL if it could not be allocated. */
typedef void (*lw_sdp_success_cb)(char* sdp, char* type, void* user);
typedef void (*lw_set_sdp_success_cb)(void* user);
typedef void (*lw_sdp_failure_cb)(char* error, void* user);

/* Creates an offer/answer. On success `on_success` receives the SDP and its
 * type ("offer"/"answer"). */
LW_C_API void lw_pc_create_offer(lw_pc_t* pc, lw_sdp_success_cb on_success,
                                 lw_sdp_failure_cb on_failure, void* user);
LW_C_API void lw_pc_create_answer(lw_pc_t* pc, lw_sdp_success_cb on_success,
                                  lw_sdp_failure_cb on_failure, void* user);

/* Applies a local/remote session description. `type` is "offer"/"answer". */
LW_C_API void lw_pc_set_local_description(lw_pc_t* pc, const char* sdp,
                                          const char* type,
                                          lw_set_sdp_success_cb on_success,
                                          lw_sdp_failure_cb on_failure,
                                          void* user);
LW_C_API void lw_pc_set_remote_description(lw_pc_t* pc, const char* sdp,
                                           const char* type,
                                           lw_set_sdp_success_cb on_success,
                                           lw_sdp_failure_cb on_failure,
                                           void* user);

/* Adds a remote ICE candidate. */
LW_C_API void lw_pc_add_ice_candidate(lw_pc_t* pc, const char* mid,
                                      int mline_index, const char* candidate);

/* Statistics the library gathers from the transport: RTP, RTCP, ICE and DTLS.
 *
 * Delivered as a JSON array, one object per report, each carrying its own id,
 * type and timestamp along with its members -- the shape the library already
 * produces, rather than a C mirror of its sixteen member types.
 *
 * Asynchronous because that is how the library collects them. A synchronous
 * call would either block one of its threads or hand back something stale.
 *
 * Poll these at human rates, a second or so apart. The per-frame pipeline
 * counters above are the ones to read at frame rate; these allocate and
 * serialize on the signaling thread.
 *
 * The document is owned by the callback, as the SDP payloads are, and is
 * retired with lw_string_free. */
typedef void (*lw_stats_success_cb)(char* json, void* user);

LW_C_API void lw_pc_get_stats(lw_pc_t* pc, lw_stats_success_cb on_success,
                              lw_sdp_failure_cb on_failure, void* user);

/* ---- Data channel ----------------------------------------------------- */

typedef struct lw_data_channel lw_data_channel_t;

typedef enum lw_data_channel_state {
  LW_DATA_CHANNEL_CONNECTING = 0,
  LW_DATA_CHANNEL_OPEN = 1,
  LW_DATA_CHANNEL_CLOSING = 2,
  LW_DATA_CHANNEL_CLOSED = 3,
} lw_data_channel_state;

/* Channel configuration. Pass NULL to lw_pc_create_data_channel for the
 * defaults: ordered and reliable, which is what most callers want.
 *
 * max_retransmit_time_ms and max_retransmits are the two ways to make a
 * channel unreliable and are mutually exclusive; -1 leaves both unset. */
typedef struct LwDataChannelInit {
  uint32_t size;                  /* sizeof(LwDataChannelInit) */
  int32_t ordered;                /* nonzero: deliver in order (default) */
  int32_t max_retransmit_time_ms; /* -1 unset */
  int32_t max_retransmits;        /* -1 unset */
  int32_t negotiated;             /* nonzero: agreed out of band, use `id` */
  int32_t id;                     /* channel id when negotiated */
} LwDataChannelInit;

/* Opens a data channel. `label` must be non-NULL. Returns NULL on failure; the
 * handle owns one reference. */
LW_C_API lw_data_channel_t* lw_pc_create_data_channel(
    lw_pc_t* pc, const char* label, const LwDataChannelInit* init);

/* Sends one message. `binary` distinguishes a binary message from text, which
 * the far side is told. Returns 0 on success, negative on error.
 *
 * Success means the message was accepted for sending, not that it arrived.
 * Sending faster than the transport drains grows the buffered amount without
 * bound, so a caller that can outrun the link should watch
 * lw_data_channel_buffered_amount. */
LW_C_API int lw_data_channel_send(lw_data_channel_t* channel,
                                  const uint8_t* data, uint32_t size,
                                  int binary);

/* Closes the channel. The handle stays valid until lw_release. */
LW_C_API void lw_data_channel_close(lw_data_channel_t* channel);

/* The channel's id, or negative before one is assigned or on error. */
LW_C_API int lw_data_channel_id(lw_data_channel_t* channel);

/* The channel's state as lw_data_channel_state, negative on error. */
LW_C_API int lw_data_channel_get_state(lw_data_channel_t* channel);

/* Bytes accepted for sending but not yet handed to the transport. */
LW_C_API uint64_t lw_data_channel_buffered_amount(lw_data_channel_t* channel);

/* The channel's label, owned by the caller (lw_string_free). NULL on error. */
LW_C_API char* lw_data_channel_label(lw_data_channel_t* channel);

/* Channel events, invoked on the signaling thread. Any field may be NULL. The
 * struct is copied on registration; the function pointers and `user` must
 * remain valid until the observer is removed. */
typedef struct LwDataChannelObserver {
  uint32_t size; /* sizeof(LwDataChannelObserver) */
  void (*on_state)(int state, void* user);
  /* One message. `data` is owned by the callback (lw_string_free) and is
   * `size` bytes, with a NUL appended past them. */
  void (*on_message)(char* data, uint32_t size, int binary, void* user);
} LwDataChannelObserver;

/* Registers `observer` for `channel`, replacing any previous one. Returns 0 on
 * success, negative on error. Remove it before releasing the channel. */
LW_C_API int lw_data_channel_set_observer(lw_data_channel_t* channel,
                                          const LwDataChannelObserver* observer,
                                          void* user);

/* Removes and destroys the channel's observer, if any. */
LW_C_API void lw_data_channel_remove_observer(lw_data_channel_t* channel);

/* ---- Peer-connection events (observer) -------------------------------- */

/* State values delivered to the observer callbacks below. These mirror the
 * library's own RTC*State enums, which the shim static-asserts against, so a
 * consumer needs only this header. */
typedef enum lw_signaling_state {
  LW_SIGNALING_STABLE = 0,
  LW_SIGNALING_HAVE_LOCAL_OFFER = 1,
  LW_SIGNALING_HAVE_REMOTE_OFFER = 2,
  LW_SIGNALING_HAVE_LOCAL_PRANSWER = 3,
  LW_SIGNALING_HAVE_REMOTE_PRANSWER = 4,
  LW_SIGNALING_CLOSED = 5,
} lw_signaling_state;

typedef enum lw_pc_state {
  LW_PC_STATE_NEW = 0,
  LW_PC_STATE_CONNECTING = 1,
  LW_PC_STATE_CONNECTED = 2,
  LW_PC_STATE_DISCONNECTED = 3,
  LW_PC_STATE_FAILED = 4,
  LW_PC_STATE_CLOSED = 5,
} lw_pc_state;

typedef enum lw_ice_gathering_state {
  LW_ICE_GATHERING_NEW = 0,
  LW_ICE_GATHERING_GATHERING = 1,
  LW_ICE_GATHERING_COMPLETE = 2,
} lw_ice_gathering_state;

typedef enum lw_ice_connection_state {
  LW_ICE_CONNECTION_NEW = 0,
  LW_ICE_CONNECTION_CHECKING = 1,
  LW_ICE_CONNECTION_COMPLETED = 2,
  LW_ICE_CONNECTION_CONNECTED = 3,
  LW_ICE_CONNECTION_FAILED = 4,
  LW_ICE_CONNECTION_DISCONNECTED = 5,
  LW_ICE_CONNECTION_CLOSED = 6,
} lw_ice_connection_state;

/* Per-event C callbacks, invoked on the signaling thread. Any field may be
 * NULL. State ints take the values of the enums above. The
 * struct is copied on registration, so it need not outlive the call; the
 * function pointers and `user` must remain valid until the observer is
 * removed. */
typedef struct LwPcObserver {
  uint32_t size; /* sizeof(LwPcObserver) */
  void (*on_signaling_state)(int state, void* user);
  void (*on_connection_state)(int state, void* user);
  void (*on_ice_gathering_state)(int state, void* user);
  void (*on_ice_connection_state)(int state, void* user);
  /* A local ICE candidate was gathered. The strings are owned by the callback
   * (lw_string_free), as for the SDP callbacks above. */
  void (*on_ice_candidate)(char* candidate, char* sdp_mid, int sdp_mline_index,
                           void* user);
  void (*on_renegotiation_needed)(void* user);
  /* A remote track arrived. `transceiver` is an OWNING handle: retire it with
   * lw_release; reach its receiver/video track via the transceiver
   * accessors. */
  void (*on_track)(lw_transceiver_t* transceiver, void* user);
  /* The far side opened a data channel. `channel` is an OWNING handle: retire
   * it with lw_release. Register an observer on it to receive messages. */
  void (*on_data_channel)(lw_data_channel_t* channel, void* user);
} LwPcObserver;

/* Registers `observer` for `pc`, replacing any previous one. Returns 0 on
 * success, negative on error. Remove it (or before releasing the pc) with
 * lw_pc_remove_observer. */
LW_C_API int lw_pc_set_observer(lw_pc_t* pc, const LwPcObserver* observer,
                                void* user);

/* Removes and destroys the pc's observer, if any. */
LW_C_API void lw_pc_remove_observer(lw_pc_t* pc);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LW_C_API_H_ */
