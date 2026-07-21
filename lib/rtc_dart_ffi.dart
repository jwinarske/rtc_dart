// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

/// rtc_dart internal FFI surface — for sibling packages in this workspace
/// (e.g. ihs_webrtc_view) that must broker the native `track -> sink token`
/// binding before the idiomatic handle layer (`rtc_dart.dart`) lands.
///
/// NOT part of the stable public API: it exposes raw `Pointer` types and the
/// generated `LwBindings`. It exists only so the platform-view plugin can call
/// the sink registry on the same process-global libwebrtc the control plane
/// loaded. It will be superseded by `VideoTrack.bindSink(token)`.
library rtc_dart.ffi;

import 'dart:ffi' as ffi;

export 'src/ffi/lw_bindings.dart'
    show
        LwBindings,
        LwVideoSinkV1,
        lw_video_track,
        lw_receiver,
        lw_transceiver,
        lw_pc;

import 'src/ffi/lw_bindings.dart' show LwBindings;

/// The default libwebrtc shared-object name. The loader resolves it through the
/// dynamic linker (LD_LIBRARY_PATH / rpath / bundled path); pass an explicit
/// path to override. Once rtc_dart's native-assets hook lands this is replaced
/// by an `@Native`-resolved code asset.
const String kLibwebrtcName = 'libwebrtc.so';

LwBindings? _cached;

/// Opens libwebrtc and returns its [LwBindings]. The library is process-global
/// (the sink registry is a process-wide singleton), so repeated calls return a
/// binding over the same already-loaded object. Cached after the first call.
LwBindings openLibwebrtc([String? path]) {
  final cached = _cached;
  if (cached != null && path == null) {
    return cached;
  }
  final lib = ffi.DynamicLibrary.open(path ?? kLibwebrtcName);
  final bindings = LwBindings(lib);
  _cached ??= bindings;
  return bindings;
}
