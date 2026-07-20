/// rtc_dart — pure-Dart WebRTC control plane over libwebrtc.so.
///
/// Frames never touch Dart. This library owns the control plane and brokers
/// the `track -> sink token` binding; the data plane is native-to-native.
/// See README.md.
///
/// Public API is handle-based with `NativeFinalizer`; no `Pointer` types
/// escape this boundary.
library rtc_dart;

// Barrel — public surface is re-exported here as the idiomatic layer lands.
// Nothing is exported yet: the hand-written layer over the generated bindings
// (lib/src/ffi/lw_bindings.dart) is not implemented yet.
//
// Planned exports:
//   export 'src/factory.dart'         show RtcFactory, LwFactoryConfig;
//   export 'src/peer_connection.dart' show RtcPeerConnection;
//   export 'src/track.dart'           show VideoTrack, AudioTrack; // bindSink(token)
//   export 'src/data_channel.dart'    show DataChannel;
//   export 'src/events.dart'          show RtcEvent;
//   export 'src/pipeline_stats.dart'  show PipelineStats;

/// Must match `LW_ABI_VERSION` in the vendored C ABI header.
const int lwAbiVersion = 1;
