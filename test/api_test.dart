// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

// Exercises the idiomatic layer against the real library. Needs a built
// libwebrtc.so; point LIBWEBRTC_SO at it, or rely on the default path.

import 'dart:io';

import 'package:rtc_dart/rtc_dart.dart';
import 'package:test/test.dart';

String get _soPath =>
    Platform.environment['LIBWEBRTC_SO'] ??
    '/mnt/dev/webrtc-build/src/out-x64-release/libwebrtc.so';

void main() {
  setUpAll(() {
    if (!File(_soPath).existsSync()) {
      throw StateError('libwebrtc.so not found at $_soPath');
    }
    Rtc.initialize(libraryPath: _soPath);
  });

  test('reports the ABI the bindings were generated against', () {
    expect(Rtc.abiVersion, 6);
  });

  test('walks factory -> peer connection -> transceiver -> track', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);

    final pc = factory.createPeerConnection();
    addTearDown(pc.dispose);

    final transceiver = pc.addTransceiver(MediaKind.video);
    addTearDown(transceiver.dispose);

    final receiver = transceiver.receiver;
    expect(receiver, isNotNull);
    addTearDown(receiver!.dispose);

    final track = receiver.videoTrack;
    expect(track, isNotNull);
    addTearDown(track!.dispose);
    expect(track.hasSink, isFalse);
  });

  test(
      'a disposed handle refuses further use rather than reaching into '
      'freed memory', () {
    final factory = RtcFactory.create();
    factory.dispose();
    expect(factory.dispose, returnsNormally); // idempotent
    expect(factory.isDisposed, isTrue);
    expect(factory.createPeerConnection, throwsStateError);
  });

  test('closing a peer connection is idempotent and implied by dispose', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final pc = factory.createPeerConnection();
    pc.close();
    expect(pc.close, returnsNormally);
    expect(pc.dispose, returnsNormally);
  });

  test('binding refuses an unknown sink token', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final pc = factory.createPeerConnection();
    addTearDown(pc.dispose);
    final track = pc.addTransceiver(MediaKind.video).receiver!.videoTrack!;
    addTearDown(track.dispose);

    // Unguessable tokens mean a fabricated one must not bind.
    expect(() => track.bindSink(const VideoSinkToken(0xdeadbeef)),
        throwsA(isA<RtcNativeException>()));
    expect(track.hasSink, isFalse);
    expect(track.unbindSink, returnsNormally); // no-op when nothing is bound
  });

  test('handles are reclaimed without dispose', () async {
    // Create and drop a batch, then give the collector a chance. This is a
    // smoke check that the finalizer path does not crash; it cannot assert
    // collection happened, since that is not deterministic.
    for (var i = 0; i < 20; i++) {
      final factory = RtcFactory.create();
      factory.createPeerConnection();
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(Rtc.abiVersion, 6); // library still healthy
  });
}
