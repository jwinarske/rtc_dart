# vendored lw_abi

C ABI headers vendored verbatim from `jwinarske/libwebrtc` `include/c/`, pinned
by `LW_ABI_VERSION`. ffigen (`ffigen.yaml`) generates
`lib/src/ffi/lw_bindings.dart` from these; CI asserts they stay byte-identical
to the pinned upstream revision.

- `lw_video_sink.h` — data-plane descriptor + sink callback table.
- `lw_c_api.h` — flat C control-plane surface (lifecycle, factory, peer
  connection, transceiver/receiver/track, SDP negotiation, observer, sink
  registry).
