// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

// FFI smoke test: drives the flat C ABI end to end from Dart against a built
// libwebrtc.so, proving the generated bindings load and call correctly.
//
//   dart run example/ffi_smoke.dart [path/to/libwebrtc.so]
//
// Exercises: lifecycle -> factory -> peer connection -> video transceiver ->
// receiver -> video track -> register a native sink -> bind -> unbind (fires
// on_eos) -> release handles -> terminate. No frames flow (no decoder), so the
// sink's on_frame is never invoked; on_eos confirms the binding path.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:rtc_dart/src/ffi/lw_bindings.dart';

int main(List<String> args) {
  final soPath = args.isNotEmpty
      ? args[0]
      : '/mnt/dev/webrtc-build/src/out-x64-release/libwebrtc.so';
  final lib = LwBindings(DynamicLibrary.open(soPath));

  stdout.writeln('abi=${lib.lw_abi_version()}');
  if (lib.lw_initialize() == 0) {
    stderr.writeln('lw_initialize failed');
    return 1;
  }

  final factory = lib.lw_factory_create();
  if (factory == nullptr || lib.lw_factory_initialize(factory) == 0) {
    stderr.writeln('factory create/init failed');
    return 1;
  }

  final pc = lib.lw_pc_create(factory);
  final transceiver =
      lib.lw_pc_add_transceiver(pc, lw_media_type.LW_MEDIA_VIDEO);
  final receiver = lib.lw_transceiver_receiver(transceiver);
  final track = lib.lw_receiver_video_track(receiver);
  if (pc == nullptr ||
      transceiver == nullptr ||
      receiver == nullptr ||
      track == nullptr) {
    stderr.writeln('control-plane chain produced a null handle');
    return 1;
  }
  stdout.writeln('got video track handle=${track.address.toRadixString(16)}');

  var eosCount = 0;
  final onFrame = NativeCallable<
      Int Function(Pointer<LwDmabufDescriptor>, LwFrameRelease, Pointer<Void>,
          Pointer<Void>)>.isolateLocal(
    (Pointer<LwDmabufDescriptor> d, LwFrameRelease r, Pointer<Void> rc,
            Pointer<Void> u) =>
        0,
    exceptionalReturn: 0,
  );
  final onEos = NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
    (Pointer<Void> u) => eosCount++,
  );

  final sink = calloc<LwVideoSinkV1>();
  sink.ref.size = sizeOf<LwVideoSinkV1>();
  sink.ref.on_frame = onFrame.nativeFunction;
  sink.ref.on_eos = onEos.nativeFunction;

  final token = lib.lw_video_sink_register(sink, nullptr);
  final bindRc = lib.lw_video_track_bind_sink(track, token);
  final unbindRc = lib.lw_video_track_unbind_sink(track); // fires on_eos
  lib.lw_video_sink_unregister(token);
  stdout.writeln(
      'token_nonzero=${token != 0} bind=$bindRc unbind=$unbindRc eos=$eosCount');

  // Teardown.
  onFrame.close();
  onEos.close();
  calloc.free(sink);
  lib.lw_release(track.cast());
  lib.lw_release(receiver.cast());
  lib.lw_release(transceiver.cast());
  lib.lw_pc_close(pc);
  lib.lw_release(pc.cast());
  lib.lw_release(factory.cast());
  lib.lw_terminate();

  final ok = token != 0 && bindRc == 0 && unbindRc == 0 && eosCount == 1;
  stdout.writeln(ok ? 'DART_FFI_SMOKE_OK' : 'DART_FFI_SMOKE_FAIL');
  return ok ? 0 : 2;
}
