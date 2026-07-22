// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

// A loopback driven entirely from Dart: frames pushed into a local source come
// back out of a remote track on the far side. Nothing here touches the C++
// interface, and no native helper takes part.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:rtc_dart/rtc_dart.dart';
import 'package:test/test.dart';

String get _soPath =>
    Platform.environment['LIBWEBRTC_SO'] ??
    '/mnt/dev/webrtc-build/src/out-x64-release/libwebrtc.so';

const int _width = 320;
const int _height = 240;

/// A frame whose luma varies with [n], so successive frames differ and the
/// encoder cannot collapse them.
Uint8List _frame(int n) {
  final data = Uint8List(_width * _height * 3 ~/ 2);
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      data[y * _width + x] = (x + y + n * 3) & 0xff;
    }
  }
  data.fillRange(_width * _height, data.length, 128);
  return data;
}

void main() {
  setUpAll(() {
    if (!File(_soPath).existsSync()) {
      throw StateError('libwebrtc.so not found at $_soPath');
    }
    Rtc.initialize(libraryPath: _soPath);
  });

  test('pushed frames arrive on the remote track', () async {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final caller = factory.createPeerConnection();
    final callee = factory.createPeerConnection();
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    final remoteTransceiver = callee.onTrack.first;

    // Forward candidates once the far side can accept them.
    var calleeReady = false;
    var callerReady = false;
    final calleeBuffer = <RtcIceCandidate>[];
    final callerBuffer = <RtcIceCandidate>[];
    final subs = <StreamSubscription<RtcIceCandidate>>[
      caller.onIceCandidate.listen(
          (c) => calleeReady ? callee.addIceCandidate(c) : calleeBuffer.add(c)),
      callee.onIceCandidate.listen(
          (c) => callerReady ? caller.addIceCandidate(c) : callerBuffer.add(c)),
    ];
    addTearDown(() => Future.wait(subs.map((s) => s.cancel())));

    final source = factory.createVideoSource(label: 'loopback-source');
    addTearDown(source.dispose);
    final localTrack = factory.createVideoTrack(source, id: 'loopback-video');
    addTearDown(localTrack.dispose);
    expect(localTrack.enabled, isTrue);

    final sender = caller.addTrack(localTrack, streamIds: ['loopback-stream']);
    addTearDown(sender.dispose);

    final offer = await caller.createOffer();
    await caller.setLocalDescription(offer);
    await callee.setRemoteDescription(offer);
    calleeReady = true;
    for (final c in calleeBuffer) {
      callee.addIceCandidate(c);
    }

    final answer = await callee.createAnswer();
    await callee.setLocalDescription(answer);
    await caller.setRemoteDescription(answer);
    callerReady = true;
    for (final c in callerBuffer) {
      caller.addIceCandidate(c);
    }

    final transceiver =
        await remoteTransceiver.timeout(const Duration(seconds: 20));
    addTearDown(transceiver.dispose);
    final remoteTrack = transceiver.receiver!.videoTrack!;
    addTearDown(remoteTrack.dispose);

    // Subscribe before pushing, or the first frames are missed.
    final received = <RtcFrameInfo>[];
    final gotFrames = Completer<void>();
    final frameSub = remoteTrack.onFrame.listen((info) {
      received.add(info);
      if (received.length >= 5 && !gotFrames.isCompleted) {
        gotFrames.complete();
      }
    });
    addTearDown(frameSub.cancel);

    // Feed until the far side has enough, at roughly 30fps.
    var pushed = 0;
    final feeder = Timer.periodic(const Duration(milliseconds: 33), (t) {
      if (gotFrames.isCompleted) {
        t.cancel();
        return;
      }
      source.pushI420(_frame(pushed++), width: _width, height: _height);
    });
    addTearDown(feeder.cancel);

    await gotFrames.future.timeout(const Duration(seconds: 45));
    expect(received.first.width, _width);
    expect(received.first.height, _height);
    expect(pushed, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a frame whose size contradicts its dimensions is refused', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final source = factory.createVideoSource();
    addTearDown(source.dispose);

    expect(
      () => source.pushI420(Uint8List(10), width: _width, height: _height),
      throwsArgumentError,
    );
  });

  test('a local track mutes and unmutes', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final source = factory.createVideoSource();
    addTearDown(source.dispose);
    final track = factory.createVideoTrack(source);
    addTearDown(track.dispose);

    expect(track.enabled, isTrue);
    track.enabled = false;
    expect(track.enabled, isFalse);
    track.enabled = true;
    expect(track.enabled, isTrue);
  });
}
