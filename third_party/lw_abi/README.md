# vendored lw_abi

C ABI headers vendored verbatim from `jwinarske/libwebrtc` `include/c/`.
ffigen (`ffigen.yaml`) generates `lib/src/ffi/lw_bindings.dart` from these.

`REVISION` pins the upstream commit they came from. CI runs
`tool/vendor_abi.sh --check`, which fetches that commit and asserts the
vendored copies are byte-identical to it.

To take a newer ABI:

```sh
tool/vendor_abi.sh /path/to/libwebrtc   # re-copies, re-pins, regenerates
```

then update `kExpectedAbiVersion` in `lib/src/native_library.dart` to match
`LW_ABI_VERSION`.

- `lw_video_sink.h` — data-plane descriptor + sink callback table.
- `lw_c_api.h` — flat C control-plane surface (lifecycle, factory, peer
  connection, transceiver/receiver/track, SDP negotiation, observer, sink
  registry).
