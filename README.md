<!--
SPDX-FileCopyrightText: 2026 Joel Winarske
SPDX-License-Identifier: MIT
-->

# rtc_dart

Pure-Dart WebRTC **control plane** over `libwebrtc.so`, via `dart:ffi`.
Deliberately **not** shaped like `flutter_webrtc` — no method channels, no
texture registrar, no RGBA upload.

## Scope

Dart owns the control plane only: peer-connection lifecycle, SDP/ICE,
transceivers, tracks, datachannels, stats. It brokers the binding `track ->
sink token` and then is **out of the frame path permanently**. Decoded frames
travel decoder -> presenter as dmabuf descriptors over a C ABI,
native-to-native. Dart never touches a frame.

```
Dart isolate (rtc_dart)  ──control only──►  libwebrtc.so (C ABI, dlopen'd asset)
   │  dart:ffi (lw_* flat C API)                 │
   └── track.bindSink(token) ───────────────────►│  frames flow native→native
                                                  ▼  to the presenter
```

## Design commitments

- **No `Pointer` in the public API.** Every native handle is wrapped and gets
  a `NativeFinalizer` paired with `lw_release`.
- **Events delivered by port.** One `RawReceivePort` per factory (or per PC),
  registered with `lw_set_event_port`. Native posts flat little-endian
  typed-data records (`Dart_PostCObject_DL` + `kExternalTypedData`); this
  package decodes them into typed Dart events/streams. Datachannel
  `Uint8List` payloads ARE the external typed data — zero copy end to end,
  freed by the GC finalizer.
- **Hot-path stats by direct view.** `lw_pipeline_stats` fills a C-heap POD
  in place from lock-free atomics; Dart reads a `TypedData` view over it,
  safe at frame rate. RTCStats (RTP/RTCP/ICE/DTLS) are async-only via a JSON
  post on completion.
- **Non-blocking shim surface.** If a blocking call ever emerges it runs on
  `Isolate.run()` (posts land on the main isolate's port).
- **Zero Flutter dependency.** Flutter integration (platform-view glue) lives
  in the separate `ihs_webrtc_view` package.

## ABI binding

`ffigen.yaml` runs over the vendored C ABI headers under `third_party/lw_abi/`
(pinned by `LW_ABI_VERSION`), generating `lib/src/ffi/lw_bindings.dart`.
`hook/build.dart` fetches the matching prebuilt `libwebrtc.so` as a code asset
and asserts `lw_abi_version() == LW_ABI_VERSION` at load.

## Layout

```
lib/rtc_dart.dart          public API barrel
lib/src/ffi/               ffigen output + @Native() bindings (generated)
lib/src/                   idiomatic hand-written layer (handles, events, streams)
hook/build.dart            native-asset fetch/pin
ffigen.yaml                ffigen config over third_party/lw_abi
third_party/lw_abi/        vendored C ABI headers (lw_video_sink.h, lw_c_api.h)
example/                   headless WHEP client (null/plane sink)
```

## example/

The `example/` is a headless WHEP client: pure-Dart CLI (no Flutter), injected
decoder + null/plane sink, exercised in CI against a MediaMTX peer with visl
decode under virtme-ng. Harness scenarios: shutdown ordering under load and
network-flap -> ICE-restart -> decoder-survives (no pool reallocation on
restart).
