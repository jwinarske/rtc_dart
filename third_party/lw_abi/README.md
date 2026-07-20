# vendored lw_abi

C ABI headers vendored from `jwinarske/libwebrtc` `include/c/`, pinned by
`LW_ABI_VERSION`. ffigen (`ffigen.yaml`) generates the raw bindings from
these. `lw_video_sink.h` is byte-identical to upstream (CI asserts).
`lw_c_api.h` is currently a placeholder until the flat C control API lands
upstream.
