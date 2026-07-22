// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;

import 'ffi/lw_bindings.dart' as lw;
import 'handle.dart';
import 'native_library.dart';
import 'video_sink.dart';

/// Media kind for a transceiver.
enum MediaKind {
  audio(lw.lw_media_type.LW_MEDIA_AUDIO),
  video(lw.lw_media_type.LW_MEDIA_VIDEO),
  data(lw.lw_media_type.LW_MEDIA_DATA);

  const MediaKind(this._native);
  final lw.lw_media_type _native;
}

/// Process-wide library lifecycle.
///
/// [initialize] must be called before creating a [RtcFactory], and
/// [terminate] only after every handle has been disposed.
class Rtc {
  Rtc._();

  static NativeLibrary? _library;

  /// Opens libwebrtc, verifies its ABI and starts the library. Repeated calls
  /// are harmless. Pass [libraryPath] to load a specific shared object.
  static void initialize({String? libraryPath}) {
    final library = NativeLibrary.load(path: libraryPath);
    if (_library != null) {
      return;
    }
    if (library.bindings.lw_initialize() == 0) {
      throw RtcNativeException('lw_initialize failed');
    }
    _library = library;
  }

  /// The ABI version reported by the loaded library.
  static int get abiVersion => NativeLibrary.instance.bindings.lw_abi_version();

  /// Shuts the library down. Dispose every handle first.
  static void terminate() {
    final library = _library;
    if (library == null) {
      return;
    }
    library.bindings.lw_terminate();
    _library = null;
  }
}

/// Creates peer connections. One per process is typical: it owns the worker,
/// signaling and network threads.
class RtcFactory extends RtcHandle {
  RtcFactory._(super.pointer, super.library);

  /// Creates and initializes a factory.
  factory RtcFactory.create() {
    final library = NativeLibrary.instance;
    final pointer = library.bindings.lw_factory_create();
    if (pointer == ffi.nullptr) {
      throw RtcNativeException('lw_factory_create failed');
    }
    if (library.bindings.lw_factory_initialize(pointer) == 0) {
      library.bindings.lw_release(pointer.cast());
      throw RtcNativeException('lw_factory_initialize failed');
    }
    return RtcFactory._(pointer.cast(), library);
  }

  /// Creates a peer connection with a default configuration.
  RtcPeerConnection createPeerConnection() {
    final created =
        library.bindings.lw_pc_create(pointer.cast<lw.lw_factory_t>());
    if (created == ffi.nullptr) {
      throw RtcNativeException('lw_pc_create failed');
    }
    return RtcPeerConnection._(created.cast(), library);
  }
}

/// A peer connection.
class RtcPeerConnection extends RtcHandle {
  RtcPeerConnection._(super.pointer, super.library);

  bool _closed = false;

  /// Adds a transceiver of [kind] with the default direction.
  RtcTransceiver addTransceiver(MediaKind kind) {
    final result = library.bindings
        .lw_pc_add_transceiver(pointer.cast<lw.lw_pc_t>(), kind._native);
    if (result == ffi.nullptr) {
      throw RtcNativeException('lw_pc_add_transceiver failed');
    }
    return RtcTransceiver._(result.cast(), library);
  }

  /// Closes the connection. Idempotent; also run by [dispose].
  void close() {
    if (_closed || isDisposed) {
      return;
    }
    _closed = true;
    library.bindings.lw_pc_close(pointer.cast<lw.lw_pc_t>());
  }

  @override
  void beforeRelease() => close();
}

/// One direction pair of a peer connection.
class RtcTransceiver extends RtcHandle {
  RtcTransceiver._(super.pointer, super.library);

  /// The receiving half, or null if there is none.
  RtcReceiver? get receiver {
    final result = library.bindings
        .lw_transceiver_receiver(pointer.cast<lw.lw_transceiver_t>());
    if (result == ffi.nullptr) {
      return null;
    }
    return RtcReceiver._(result.cast(), library);
  }
}

/// The receiving half of a transceiver.
class RtcReceiver extends RtcHandle {
  RtcReceiver._(super.pointer, super.library);

  /// This receiver's video track, or null when it carries no video.
  RtcVideoTrack? get videoTrack {
    final result = library.bindings
        .lw_receiver_video_track(pointer.cast<lw.lw_receiver_t>());
    if (result == ffi.nullptr) {
      return null;
    }
    return RtcVideoTrack._(result.cast(), library);
  }
}

/// A video track.
///
/// Decoded frames never enter Dart: binding a [VideoSinkToken] hands the track
/// to a native consumer, and frames travel from the decoder to that consumer
/// without crossing the FFI boundary. Dart only brokers the binding.
class RtcVideoTrack extends RtcHandle {
  RtcVideoTrack._(super.pointer, super.library);

  VideoSinkToken? _bound;

  /// Routes this track's frames to the sink [token] was registered for.
  ///
  /// Throws if the binding is refused, which happens when the token is unknown
  /// or the handle is not a video track.
  void bindSink(VideoSinkToken token) {
    final rc = library.bindings.lw_video_track_bind_sink(
      pointer.cast<lw.lw_video_track_t>(),
      token.value,
    );
    if (rc != 0) {
      throw RtcNativeException('lw_video_track_bind_sink failed ($rc)');
    }
    _bound = token;
  }

  /// Stops delivery to the bound sink. Blocks until any in-flight frame
  /// callback has returned, and reaches the sink as an end-of-stream.
  /// Idempotent.
  void unbindSink() {
    if (_bound == null || isDisposed) {
      return;
    }
    library.bindings
        .lw_video_track_unbind_sink(pointer.cast<lw.lw_video_track_t>());
    _bound = null;
  }

  /// Whether a sink is currently bound.
  bool get hasSink => _bound != null;

  @override
  void beforeRelease() => unbindSink();
}
