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

/* Frees a string delivered to a callback below. Every `char*` a callback
 * receives is owned by the callback, which passes it here once done. NULL is
 * ignored. */
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
