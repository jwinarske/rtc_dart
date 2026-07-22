// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

import 'events.dart';
import 'ffi/lw_bindings.dart' as lw;
import 'handle.dart';
import 'native_library.dart';
import 'video_sink.dart';

/// Reads a string a callback took ownership of, and retires it.
String _takeString(ffi.Pointer<ffi.Char> s) {
  if (s == ffi.nullptr) {
    return '';
  }
  final value = s.cast<pkg_ffi.Utf8>().toDartString();
  NativeLibrary.instance.bindings.lw_string_free(s);
  return value;
}

/// An SDP request whose native callbacks are still registered.
///
/// The callbacks must outlive the call that started them and be closed once
/// one of them fires -- or, if the peer connection goes away with neither
/// having fired, when it is disposed.
class _SdpRequest {
  _SdpRequest(this._close, this._fail);

  final void Function() _close;
  final void Function(Object error) _fail;
  bool _settled = false;

  /// Closes the callbacks. False if the request already settled.
  bool settle() {
    if (_settled) {
      return false;
    }
    _settled = true;
    _close();
    return true;
  }

  void abandon() {
    if (settle()) {
      _fail(RtcNativeException(
          'the peer connection was disposed before the request completed'));
    }
  }
}

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

  /// Creates a video source that frames are pushed into.
  ///
  /// This is the send side's entry point: a source is fed by
  /// [RtcVideoSource.pushI420] rather than by a capture device.
  RtcVideoSource createVideoSource({String? label}) {
    final name = (label ?? '').toNativeUtf8();
    try {
      final created = library.bindings.lw_factory_create_video_source(
          pointer.cast<lw.lw_factory_t>(), name.cast());
      if (created == ffi.nullptr) {
        throw RtcNativeException('lw_factory_create_video_source failed');
      }
      return RtcVideoSource._(created.cast(), library);
    } finally {
      pkg_ffi.malloc.free(name);
    }
  }

  /// Creates a local video track fed by [source].
  RtcVideoTrack createVideoTrack(RtcVideoSource source, {String? id}) {
    final trackId = (id ?? '').toNativeUtf8();
    try {
      final created = library.bindings.lw_factory_create_video_track(
        pointer.cast<lw.lw_factory_t>(),
        source.pointer.cast<lw.lw_video_source_t>(),
        trackId.cast(),
      );
      if (created == ffi.nullptr) {
        throw RtcNativeException('lw_factory_create_video_track failed');
      }
      return RtcVideoTrack._(created.cast(), library);
    } finally {
      pkg_ffi.malloc.free(trackId);
    }
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
///
/// Events arrive as streams, and the SDP operations return futures. Both are
/// fed by native callbacks that fire on webrtc's signaling thread and are
/// delivered to this isolate, so nothing here runs on that thread.
///
/// The observer behind the streams is registered on first use, so a connection
/// nobody listens to costs nothing. Once registered it keeps the isolate
/// alive, so a program that listens must dispose the connection to exit.
class RtcPeerConnection extends RtcHandle {
  RtcPeerConnection._(super.pointer, super.library);

  bool _closed = false;
  _PcEvents? _events;
  final Set<_SdpRequest> _requests = {};

  _PcEvents get _observer => _events ??= _PcEvents(this);

  /// Signaling state changes.
  Stream<RtcSignalingState> get onSignalingState => _observer.signaling.stream;

  /// Aggregate connection state changes.
  Stream<RtcPeerConnectionState> get onConnectionState =>
      _observer.connection.stream;

  /// ICE gathering progress.
  Stream<RtcIceGatheringState> get onIceGatheringState =>
      _observer.iceGathering.stream;

  /// ICE transport state changes.
  Stream<RtcIceConnectionState> get onIceConnectionState =>
      _observer.iceConnection.stream;

  /// Local candidates as they are gathered. Send these to the far side.
  Stream<RtcIceCandidate> get onIceCandidate => _observer.iceCandidate.stream;

  /// Fires when the session needs to be renegotiated.
  Stream<void> get onRenegotiationNeeded =>
      _observer.renegotiationNeeded.stream;

  /// Remote tracks as they arrive. Each event owns its transceiver: dispose it
  /// when done, or let it be collected.
  Stream<RtcTransceiver> get onTrack => _observer.track.stream;

  /// Creates an offer.
  Future<RtcSessionDescription> createOffer() =>
      _createSdp(library.bindings.lw_pc_create_offer);

  /// Creates an answer to the applied remote offer.
  Future<RtcSessionDescription> createAnswer() =>
      _createSdp(library.bindings.lw_pc_create_answer);

  /// Applies [description] as the local session description.
  Future<void> setLocalDescription(RtcSessionDescription description) =>
      _setSdp(library.bindings.lw_pc_set_local_description, description);

  /// Applies [description] as the remote session description.
  Future<void> setRemoteDescription(RtcSessionDescription description) =>
      _setSdp(library.bindings.lw_pc_set_remote_description, description);

  /// Adds a candidate received from the far side.
  ///
  /// A candidate is only accepted once a remote description has been applied;
  /// buffer them until then or they are dropped.
  void addIceCandidate(RtcIceCandidate candidate) {
    final mid = candidate.sdpMid.toNativeUtf8();
    final value = candidate.candidate.toNativeUtf8();
    try {
      library.bindings.lw_pc_add_ice_candidate(pointer.cast<lw.lw_pc_t>(),
          mid.cast(), candidate.sdpMLineIndex, value.cast());
    } finally {
      pkg_ffi.malloc.free(mid);
      pkg_ffi.malloc.free(value);
    }
  }

  Future<RtcSessionDescription> _createSdp(
    void Function(ffi.Pointer<lw.lw_pc_t>, lw.lw_sdp_success_cb,
            lw.lw_sdp_failure_cb, ffi.Pointer<ffi.Void>)
        invoke,
  ) {
    final completer = Completer<RtcSessionDescription>();
    late final _SdpRequest request;

    final success = ffi.NativeCallable<lw.lw_sdp_success_cbFunction>.listener(
      (ffi.Pointer<ffi.Char> sdp, ffi.Pointer<ffi.Char> type,
          ffi.Pointer<ffi.Void> _) {
        final description = RtcSessionDescription(
            sdp: _takeString(sdp), type: _takeString(type));
        if (request.settle()) {
          completer.complete(description);
        }
      },
    );
    final failure = ffi.NativeCallable<lw.lw_sdp_failure_cbFunction>.listener(
      (ffi.Pointer<ffi.Char> error, ffi.Pointer<ffi.Void> _) {
        final message = _takeString(error);
        if (request.settle()) {
          completer.completeError(RtcNativeException(message));
        }
      },
    );
    request = _SdpRequest(() {
      _requests.remove(request);
      success.close();
      failure.close();
    }, completer.completeError);
    _requests.add(request);

    invoke(pointer.cast<lw.lw_pc_t>(), success.nativeFunction,
        failure.nativeFunction, ffi.nullptr);
    return completer.future;
  }

  Future<void> _setSdp(
    void Function(
            ffi.Pointer<lw.lw_pc_t>,
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Char>,
            lw.lw_set_sdp_success_cb,
            lw.lw_sdp_failure_cb,
            ffi.Pointer<ffi.Void>)
        invoke,
    RtcSessionDescription description,
  ) {
    final completer = Completer<void>();
    late final _SdpRequest request;

    final success =
        ffi.NativeCallable<lw.lw_set_sdp_success_cbFunction>.listener(
      (ffi.Pointer<ffi.Void> _) {
        if (request.settle()) {
          completer.complete();
        }
      },
    );
    final failure = ffi.NativeCallable<lw.lw_sdp_failure_cbFunction>.listener(
      (ffi.Pointer<ffi.Char> error, ffi.Pointer<ffi.Void> _) {
        final message = _takeString(error);
        if (request.settle()) {
          completer.completeError(RtcNativeException(message));
        }
      },
    );
    request = _SdpRequest(() {
      _requests.remove(request);
      success.close();
      failure.close();
    }, completer.completeError);
    _requests.add(request);

    // The library copies both strings before returning.
    final sdp = description.sdp.toNativeUtf8();
    final type = description.type.toNativeUtf8();
    try {
      invoke(pointer.cast<lw.lw_pc_t>(), sdp.cast(), type.cast(),
          success.nativeFunction, failure.nativeFunction, ffi.nullptr);
    } finally {
      pkg_ffi.malloc.free(sdp);
      pkg_ffi.malloc.free(type);
    }
    return completer.future;
  }

  /// Adds a transceiver of [kind] with the default direction.
  RtcTransceiver addTransceiver(MediaKind kind) {
    final result = library.bindings
        .lw_pc_add_transceiver(pointer.cast<lw.lw_pc_t>(), kind._native);
    if (result == ffi.nullptr) {
      throw RtcNativeException('lw_pc_add_transceiver failed');
    }
    return RtcTransceiver._(result.cast(), library);
  }

  /// Attaches a local [track], in the streams named by [streamIds].
  RtcRtpSender addTrack(RtcVideoTrack track,
      {List<String> streamIds = const []}) {
    final ids = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>(
        streamIds.isEmpty ? 1 : streamIds.length);
    final allocated = <ffi.Pointer<pkg_ffi.Utf8>>[];
    try {
      for (var i = 0; i < streamIds.length; i++) {
        final id = streamIds[i].toNativeUtf8();
        allocated.add(id);
        ids[i] = id.cast();
      }
      final sender = library.bindings.lw_pc_add_track(
        pointer.cast<lw.lw_pc_t>(),
        track.pointer.cast<lw.lw_video_track_t>(),
        ids,
        streamIds.length,
      );
      if (sender == ffi.nullptr) {
        throw RtcNativeException('lw_pc_add_track failed');
      }
      return RtcRtpSender._(sender.cast(), library);
    } finally {
      for (final id in allocated) {
        pkg_ffi.malloc.free(id);
      }
      pkg_ffi.calloc.free(ids);
    }
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
  void beforeRelease() {
    close();
    _events?.dispose();
    _events = null;
    for (final request in _requests.toList()) {
      request.abandon();
    }
    _requests.clear();
  }
}

/// The native observer behind a peer connection's streams.
///
/// Registered on first use and removed when the peer connection is disposed.
/// Each callback is a listener callable, so webrtc's signaling thread hands
/// the event over rather than running Dart on itself.
class _PcEvents {
  _PcEvents(this._pc) {
    _signalingCb = ffi.NativeCallable<_StateCb>.listener(
        (int state, ffi.Pointer<ffi.Void> _) =>
            _add(signaling, () => signalingStateFromNative(state)));
    _connectionCb = ffi.NativeCallable<_StateCb>.listener(
        (int state, ffi.Pointer<ffi.Void> _) =>
            _add(connection, () => connectionStateFromNative(state)));
    _iceGatheringCb = ffi.NativeCallable<_StateCb>.listener(
        (int state, ffi.Pointer<ffi.Void> _) =>
            _add(iceGathering, () => iceGatheringStateFromNative(state)));
    _iceConnectionCb = ffi.NativeCallable<_StateCb>.listener(
        (int state, ffi.Pointer<ffi.Void> _) =>
            _add(iceConnection, () => iceConnectionStateFromNative(state)));
    _renegotiationCb = ffi.NativeCallable<_VoidCb>.listener(
        (ffi.Pointer<ffi.Void> _) => _add(renegotiationNeeded, () {}));
    _iceCandidateCb = ffi.NativeCallable<_CandidateCb>.listener(
      (ffi.Pointer<ffi.Char> candidate, ffi.Pointer<ffi.Char> mid, int index,
          ffi.Pointer<ffi.Void> _) {
        final value = RtcIceCandidate(
          candidate: _takeString(candidate),
          sdpMid: _takeString(mid),
          sdpMLineIndex: index,
        );
        _add(iceCandidate, () => value);
      },
    );
    _trackCb = ffi.NativeCallable<_TrackCb>.listener(
      (ffi.Pointer<lw.lw_transceiver_t> transceiver, ffi.Pointer<ffi.Void> _) {
        // The event owns the handle, so it is released even if nobody is
        // listening any more.
        if (track.isClosed || _pc.isDisposed) {
          _pc.library.bindings.lw_release(transceiver.cast());
          return;
        }
        track.add(RtcTransceiver._(transceiver.cast(), _pc.library));
      },
    );

    final observer = pkg_ffi.calloc<lw.LwPcObserver>();
    try {
      observer.ref
        ..size = ffi.sizeOf<lw.LwPcObserver>()
        ..on_signaling_state = _signalingCb.nativeFunction
        ..on_connection_state = _connectionCb.nativeFunction
        ..on_ice_gathering_state = _iceGatheringCb.nativeFunction
        ..on_ice_connection_state = _iceConnectionCb.nativeFunction
        ..on_ice_candidate = _iceCandidateCb.nativeFunction
        ..on_renegotiation_needed = _renegotiationCb.nativeFunction
        ..on_track = _trackCb.nativeFunction;
      // The struct is copied on registration, so it need not outlive this.
      final rc = _pc.library.bindings.lw_pc_set_observer(
          _pc.pointer.cast<lw.lw_pc_t>(), observer, ffi.nullptr);
      if (rc != 0) {
        _closeCallables();
        throw RtcNativeException('lw_pc_set_observer failed ($rc)');
      }
    } finally {
      pkg_ffi.calloc.free(observer);
    }
  }

  final RtcPeerConnection _pc;

  final signaling = StreamController<RtcSignalingState>.broadcast();
  final connection = StreamController<RtcPeerConnectionState>.broadcast();
  final iceGathering = StreamController<RtcIceGatheringState>.broadcast();
  final iceConnection = StreamController<RtcIceConnectionState>.broadcast();
  final iceCandidate = StreamController<RtcIceCandidate>.broadcast();
  final renegotiationNeeded = StreamController<void>.broadcast();
  final track = StreamController<RtcTransceiver>.broadcast();

  late final ffi.NativeCallable<_StateCb> _signalingCb;
  late final ffi.NativeCallable<_StateCb> _connectionCb;
  late final ffi.NativeCallable<_StateCb> _iceGatheringCb;
  late final ffi.NativeCallable<_StateCb> _iceConnectionCb;
  late final ffi.NativeCallable<_CandidateCb> _iceCandidateCb;
  late final ffi.NativeCallable<_VoidCb> _renegotiationCb;
  late final ffi.NativeCallable<_TrackCb> _trackCb;

  /// An event can still be in flight when the controller is being torn down;
  /// dropping it is correct, throwing into the isolate is not.
  static void _add<T>(StreamController<T> to, T Function() event) {
    if (!to.isClosed) {
      to.add(event());
    }
  }

  void _closeCallables() {
    _signalingCb.close();
    _connectionCb.close();
    _iceGatheringCb.close();
    _iceConnectionCb.close();
    _iceCandidateCb.close();
    _renegotiationCb.close();
    _trackCb.close();
  }

  void dispose() {
    // Deregister before the callbacks go away, so none can fire afterwards.
    if (!_pc.isDisposed) {
      _pc.library.bindings
          .lw_pc_remove_observer(_pc.pointer.cast<lw.lw_pc_t>());
    }
    _closeCallables();
    signaling.close();
    connection.close();
    iceGathering.close();
    iceConnection.close();
    iceCandidate.close();
    renegotiationNeeded.close();
    track.close();
  }
}

typedef _StateCb = ffi.Void Function(ffi.Int, ffi.Pointer<ffi.Void>);
typedef _VoidCb = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _CandidateCb = ffi.Void Function(ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>, ffi.Int, ffi.Pointer<ffi.Void>);
typedef _TrackCb = ffi.Void Function(
    ffi.Pointer<lw.lw_transceiver_t>, ffi.Pointer<ffi.Void>);

/// A video source that frames are pushed into.
///
/// This is the one place pixels cross into the library from Dart, and it is a
/// copy: the receive side stays zero-copy, where frames go from the decoder to
/// a native sink without passing through here.
class RtcVideoSource extends RtcHandle {
  RtcVideoSource._(super.pointer, super.library);

  /// Pushes one I420 frame of [width] x [height].
  ///
  /// [data] holds the Y plane, then U, then V, each tightly packed --
  /// `width * height * 3 ~/ 2` bytes in total. It is copied, so the caller may
  /// reuse the buffer immediately.
  ///
  /// Frames are consumed at whatever rate they are pushed: the caller sets the
  /// pace.
  void pushI420(Uint8List data, {required int width, required int height}) {
    final expected = width * height * 3 ~/ 2;
    if (data.length != expected) {
      throw ArgumentError.value(data.length, 'data.length',
          'an I420 frame of $width x $height is $expected bytes');
    }
    final buffer = pkg_ffi.malloc<ffi.Uint8>(data.length);
    try {
      buffer.asTypedList(data.length).setAll(0, data);
      final rc = library.bindings.lw_video_source_push_i420(
        pointer.cast<lw.lw_video_source_t>(),
        width,
        height,
        buffer,
        data.length,
      );
      if (rc != 0) {
        throw RtcNativeException('lw_video_source_push_i420 failed ($rc)');
      }
    } finally {
      pkg_ffi.malloc.free(buffer);
    }
  }
}

/// The sending half of a peer connection, for one attached track.
class RtcRtpSender extends RtcHandle {
  RtcRtpSender._(super.pointer, super.library);
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
  StreamController<RtcFrameInfo>? _frames;
  ffi.NativeCallable<lw.lw_frame_cbFunction>? _frameCb;

  /// Whether the track is enabled. A disabled track still flows, but carries
  /// black frames -- this is mute, not removal.
  bool get enabled {
    final rc = library.bindings
        .lw_video_track_enabled(pointer.cast<lw.lw_video_track_t>());
    if (rc < 0) {
      throw RtcNativeException('lw_video_track_enabled failed ($rc)');
    }
    return rc != 0;
  }

  set enabled(bool value) {
    final rc = library.bindings.lw_video_track_set_enabled(
        pointer.cast<lw.lw_video_track_t>(), value ? 1 : 0);
    if (rc != 0) {
      throw RtcNativeException('lw_video_track_set_enabled failed ($rc)');
    }
  }

  /// The size of each frame the track delivers, for counting and telemetry.
  ///
  /// Deliberately carries no pixels: on the zero-copy path the frame never
  /// enters Dart at all, so this reports that a frame arrived and how big it
  /// was, nothing more. Bind a native sink to do anything with the contents.
  Stream<RtcFrameInfo> get onFrame {
    final existing = _frames;
    if (existing != null) {
      return existing.stream;
    }
    final controller = StreamController<RtcFrameInfo>.broadcast();
    final callback = ffi.NativeCallable<lw.lw_frame_cbFunction>.listener(
      (int width, int height, ffi.Pointer<ffi.Void> _) {
        if (!controller.isClosed) {
          controller.add(RtcFrameInfo(width: width, height: height));
        }
      },
    );
    final rc = library.bindings.lw_video_track_set_frame_callback(
        pointer.cast<lw.lw_video_track_t>(),
        callback.nativeFunction,
        ffi.nullptr);
    if (rc != 0) {
      callback.close();
      controller.close();
      throw RtcNativeException(
          'lw_video_track_set_frame_callback failed ($rc)');
    }
    _frames = controller;
    _frameCb = callback;
    return controller.stream;
  }

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
  void beforeRelease() {
    unbindSink();
    // Clear the callback before the callable behind it goes away.
    if (_frameCb != null) {
      library.bindings.lw_video_track_set_frame_callback(
          pointer.cast<lw.lw_video_track_t>(), ffi.nullptr, ffi.nullptr);
      _frameCb!.close();
      _frameCb = null;
      _frames?.close();
      _frames = null;
    }
  }
}
