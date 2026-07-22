// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

/// rtc_dart — pure-Dart WebRTC control plane over libwebrtc.so.
///
/// Frames never touch Dart. This library owns the control plane and brokers
/// the `track -> sink token` binding; decoded frames travel from the decoder
/// to a native sink without crossing the FFI boundary.
///
/// Handles own one native reference each and are reclaimed when collected, so
/// nothing leaks if `dispose` is forgotten; `dispose` only makes the release
/// prompt. Order does not matter either way -- a factory may be released
/// before the peer connections it created. No `Pointer` appears in this API,
/// with one deliberate exception:
/// [VideoSinkRegistry.registerNativeSink], whose caller is native code that
/// already holds one.
///
/// ```dart
/// Rtc.initialize(libraryPath: '/path/to/libwebrtc.so');
/// final factory = RtcFactory.create();
/// final pc = factory.createPeerConnection();
/// final track = pc.addTransceiver(MediaKind.video).receiver?.videoTrack;
/// track?.bindSink(token);   // frames now flow natively
/// ```
library rtc_dart;

export 'src/native_library.dart' show RtcNativeException;
export 'src/handle.dart' show RtcHandle;
export 'src/objects.dart'
    show
        MediaKind,
        Rtc,
        RtcFactory,
        RtcPeerConnection,
        RtcReceiver,
        RtcTransceiver,
        RtcVideoTrack;
export 'src/video_sink.dart' show VideoSinkRegistry, VideoSinkToken;
