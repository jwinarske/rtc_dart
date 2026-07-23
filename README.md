<!--
SPDX-FileCopyrightText: 2026 Joel Winarske
SPDX-License-Identifier: MIT
-->

# rtc_dart

Pure-Dart WebRTC **control plane** over `libwebrtc.so`, via `dart:ffi`.
Deliberately **not** shaped like `flutter_webrtc` — no method channels, no
texture registrar, no RGBA upload.

## Scope

Dart owns the control plane: peer-connection lifecycle, SDP and ICE,
transceivers, tracks, sending video, data channels, and statistics. It brokers
the binding `track -> sink token` and is then **out of the frame path**.
Decoded frames travel decoder -> presenter as dmabuf descriptors over a C ABI,
native to native. Dart never touches a frame.

```
Dart isolate (rtc_dart)  ──control only──►  libwebrtc.so (C ABI, dlopen'd)
   │  dart:ffi (lw_* flat C API)                 │
   └── track.bindSink(token) ───────────────────►│  frames flow native→native
                                                  ▼  to the presenter
```

The one place pixels cross into the library from Dart is
`RtcVideoSource.pushI420`, on the send side, and that is a copy. The receive
side is the one that stays zero-copy.

## Using it

```dart
Rtc.initialize(libraryPath: '/path/to/libwebrtc.so');

final factory = RtcFactory.create();
final pc = factory.createPeerConnection();

pc.onIceCandidate.listen(signalling.send);
final offer = await pc.createOffer();
await pc.setLocalDescription(offer);

final track = (await pc.onTrack.first).receiver?.videoTrack;
track?.bindSink(token);   // frames now flow natively
```

`example/rtc_dart_example.dart` is a self-contained loopback — two peer
connections in one process, video pushed from Dart, a data channel, and both
kinds of statistics — runnable with no signalling server:

```sh
dart run example/rtc_dart_example.dart /path/to/libwebrtc.so
```

## Design commitments

- **No `Pointer` in the public API.** Every native handle is wrapped and gets a
  `NativeFinalizer` paired with `lw_release`, so forgetting `dispose` leaks
  nothing. Handles may be released in any order: each keeps the factory it came
  from alive, which matters because finalizers run in no particular order. The
  one exception is `VideoSinkRegistry.registerNativeSink`, whose caller is
  native code that already holds a pointer.
- **Callbacks are delivered to the isolate, not run on webrtc's threads.**
  Events and completions arrive through `NativeCallable.listener`. Payload
  strings and buffers are owned by the callback rather than borrowed for its
  duration, because a borrowed payload would already be freed by the time an
  asynchronous delivery reached Dart.
- **Two shapes of statistics, deliberately not merged.**
  `RtcVideoTrack.stats` is a synchronous read of lock-free counters, cheap
  enough for frame rate. `RtcPeerConnection.getStats()` is a future over the
  transport's RTP, RTCP, ICE and DTLS reports, which the library gathers
  asynchronously — poll it about a second apart.
- **Zero Flutter dependency.** Flutter integration (platform-view glue) lives
  in the separate `ihs_webrtc_view` package.

## Disposal is not optional if you listen

Listening to any event stream registers a native callback, and a live native
callback keeps the isolate alive. A program that listens must dispose its
handles or it will not exit. Registration is lazy, so a handle nobody listens
to costs nothing and is unaffected.

## ABI binding

`ffigen.yaml` runs over the vendored C ABI headers under `third_party/lw_abi/`,
generating `lib/src/ffi/lw_bindings.dart`. `kExpectedAbiVersion` is checked
against `lw_abi_version()` when the library is opened, so a mismatched pair
fails at load rather than at a later call with a shifted struct.

`third_party/lw_abi/REVISION` pins the upstream commit the headers came from.
To move to a newer ABI:

```sh
tool/vendor_abi.sh /path/to/libwebrtc   # re-copies, re-pins, regenerates
```

then update `kExpectedAbiVersion` to match `LW_ABI_VERSION`.
`tool/vendor_abi.sh --check` verifies the vendored copies are byte-identical
to the pinned revision.

## Layout

```
lib/rtc_dart.dart          public API barrel
lib/src/ffi/               ffigen output (generated)
lib/src/                   idiomatic layer: handles, objects, events, sinks
lib/rtc_dart_ffi.dart      internal FFI surface for sibling plugins
ffigen.yaml                ffigen config over third_party/lw_abi
tool/vendor_abi.sh         re-vendor the ABI headers, or check them
third_party/lw_abi/        vendored C ABI headers, with the revision they pin
example/                   self-contained loopback
test/                      run against a real libwebrtc.so; see LIBWEBRTC_SO
```

## Tests

They need a built `libwebrtc.so`. Point `LIBWEBRTC_SO` at one:

```sh
LIBWEBRTC_SO=/path/to/libwebrtc.so dart test
```

## Not yet

- Native assets. The library is opened by path today
  (`Rtc.initialize(libraryPath:)`); there is no `hook/build.dart` fetching a
  prebuilt `libwebrtc.so` as a code asset.
- Audio. The C ABI covers video and data; audio tracks are not wrapped.
