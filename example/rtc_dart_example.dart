// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

// Headless Dart WHEP client (skeleton).
//
// Pure Dart, no Flutter. Injected hardware decoder + null/plane sink; Dart
// stays out of the frame path. Exercised in CI against a MediaMTX peer with
// visl decode under virtme-ng.
//
// TODO: implement once the rtc_dart idiomatic layer lands. Flow:
//   1. RtcFactory(config: LwFactoryConfig(allowSoftwareCodecs: false))
//   2. Register a null/plane sink -> token.
//   3. Create PC, WHEP GET/POST offer/answer exchange over https.
//   4. On track: track.bindSink(token). Frames flow native->native.
//   5. Print PipelineStats at ~1Hz for the HUD.
//   6. Shutdown ordering: unbind -> close PC -> unregister port -> dispose.
void main(List<String> args) {
  // ignore: avoid_print
  print('rtc_dart headless WHEP client — not yet implemented.');
}
