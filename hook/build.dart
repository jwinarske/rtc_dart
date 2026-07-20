// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

// Native-assets build hook.
//
// Fetches/pins the prebuilt libwebrtc.so for the target triple from the OCI
// artifact store and exposes it as a code asset, so @Native() lookups in
// lib/src/ffi/lw_bindings.dart resolve at runtime. Env-hermetic. Under Yocto
// this hook is bypassed entirely (the source build drives the gclient
// checkout via recipe).
//
// TODO: implement OCI fetch with pinned digests, per triple. This skeleton
// declares the asset shape; wire the fetch before first use.

import 'package:native_assets_cli/native_assets_cli.dart';

const _libName = 'webrtc';
const _assetId = 'package:rtc_dart/rtc_dart.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Resolve the pinned prebuilt for input.config.code.targetOS /
    // targetArchitecture from the artifact store, verify its digest, then:
    //
    //   output.assets.code.add(CodeAsset(
    //     package: input.packageName,
    //     name: 'rtc_dart.dart',
    //     linkMode: DynamicLoadingBundled(),
    //     file: fetchedLibwebrtcSoUri,
    //   ));
    //
    // The load-time lw_abi_version() == LW_ABI_VERSION check lives in the
    // Dart init path, not here.
    _unusedForNow(_libName, _assetId);
  });
}

void _unusedForNow(String a, String b) {}
