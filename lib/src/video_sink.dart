// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;

import 'ffi/lw_bindings.dart' as lw;
import 'native_library.dart';

/// Identifies a video sink registered with the library.
///
/// A sink is a native consumer of decoded frames -- a presenter, a recorder, a
/// test harness. It is registered by whatever native code implements it; Dart
/// only carries the resulting token and binds it to a track, which is why this
/// type holds an integer rather than any pointer.
///
/// Tokens are unguessable and nonzero, so one cannot be forged to redirect
/// another track's frames.
class VideoSinkToken {
  const VideoSinkToken(this.value);

  /// The registry handle. Nonzero for a valid token.
  final int value;

  /// Whether this token could have come from a successful registration.
  bool get isValid => value != 0;

  @override
  bool operator ==(Object other) =>
      other is VideoSinkToken && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'VideoSinkToken(0x${value.toRadixString(16)})';
}

/// Registration of sinks that live in native code.
///
/// The sink callback table itself is native: frames must never travel through
/// Dart, so there is deliberately no way to implement one here. A sibling
/// plugin registers its own table and passes the token across, or
/// [registerNativeSink] does it on behalf of code that already holds one.
class VideoSinkRegistry {
  VideoSinkRegistry._();

  /// Registers a sink table that native code owns, returning its token.
  ///
  /// [sinkTable] must point to a `LwVideoSinkV1` that stays alive, unchanged,
  /// until [unregister]; [user] is passed back to its callbacks. This is the
  /// one place the package takes a pointer, because the caller is native code
  /// that already has one.
  static VideoSinkToken registerNativeSink(
    ffi.Pointer<lw.LwVideoSinkV1> sinkTable, {
    ffi.Pointer<ffi.Void>? user,
  }) {
    final library = NativeLibrary.instance;
    final token =
        library.bindings.lw_video_sink_register(sinkTable, user ?? ffi.nullptr);
    if (token == 0) {
      throw RtcNativeException('lw_video_sink_register failed');
    }
    return VideoSinkToken(token);
  }

  /// Retires a token. Unbind any track using it first.
  static void unregister(VideoSinkToken token) {
    final library = NativeLibrary.instance;
    library.bindings.lw_video_sink_unregister(token.value);
  }
}
