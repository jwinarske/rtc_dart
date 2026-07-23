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

    // The counters must agree with what the frame stream independently saw.
    final stats = remoteTrack.stats;
    expect(stats.framesDelivered, greaterThanOrEqualTo(received.length));
    expect(stats.lastWidth, _width);
    expect(stats.lastHeight, _height);
    expect(stats.lastFrameAt, isNotNull);
    // No sink is bound -- frames never enter Dart -- so on this build they
    // took the software path rather than reaching a native consumer.
    expect(stats.framesNative, 0);
    expect(stats.framesCpu + stats.framesDropped,
        greaterThanOrEqualTo(received.length));
    expect(stats.isZeroCopy, isFalse);

    // Transport statistics, from the side with an inbound stream to report on.
    final reports =
        await callee.getStats().timeout(const Duration(seconds: 20));
    expect(reports, isNotEmpty);
    for (final report in reports) {
      expect(report['id'], isA<String>());
      expect(report['type'], isA<String>());
      expect(report['timestamp'], isNotNull);
    }
    final byType = reports.map((r) => r['type']).toSet();
    expect(byType, contains('inbound-rtp'));
    expect(byType, contains('candidate-pair'));

    // The transport's own frame count should agree with what the frame stream
    // saw -- two independent views of the same run.
    final inbound = reports.firstWhere((r) => r['type'] == 'inbound-rtp');
    expect(inbound['framesDecoded'], greaterThanOrEqualTo(received.length));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('counters start at zero on a track that has decoded nothing', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final source = factory.createVideoSource();
    addTearDown(source.dispose);
    final track = factory.createVideoTrack(source);
    addTearDown(track.dispose);

    final stats = track.stats;
    expect(stats.framesDelivered, 0);
    expect(stats.lastFrameAt, isNull);
    expect(stats.isZeroCopy, isFalse); // nothing delivered yet
  });

  test('a track with no id still negotiates', () async {
    // An empty track id yields an "a=msid:<stream> " line the far side cannot
    // parse, so a generated id has to stand in rather than an empty string.
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final caller = factory.createPeerConnection();
    addTearDown(caller.dispose);

    final source = factory.createVideoSource();
    addTearDown(source.dispose);
    final track = factory.createVideoTrack(source);
    addTearDown(track.dispose);
    addTearDown(caller.addTrack(track, streamIds: ['s']).dispose);

    final offer = await caller.createOffer();
    expect(offer.sdp, contains('a=msid:'));
    // This is what rejects an empty id, so it is the assertion that matters.
    await caller.setLocalDescription(offer);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('an explicitly empty track id is refused', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final source = factory.createVideoSource();
    addTearDown(source.dispose);
    expect(() => factory.createVideoTrack(source, id: ''), throwsArgumentError);
  });

  test('a track is reachable by the id webrtc gave it', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final source = factory.createVideoSource();
    addTearDown(source.dispose);
    final track = factory.createVideoTrack(source, id: 'find-me');
    addTearDown(track.dispose);

    expect(track.id, 'find-me');

    // Reached without ever holding the original: what another plugin owning
    // the peer connection does with an id it surfaced.
    final found = RtcVideoTrack.findById('find-me');
    expect(found, isNotNull);
    addTearDown(found!.dispose);
    expect(found.id, 'find-me');
    // A distinct handle, not the same object.
    expect(identical(found, track), isFalse);

    expect(RtcVideoTrack.findById('nothing-has-this-id'), isNull);
    expect(RtcVideoTrack.findById(''), isNull);
  });

  test('an id stays findable while any handle to it lives', () {
    final factory = RtcFactory.create();
    final source = factory.createVideoSource();
    final track = factory.createVideoTrack(source, id: 'transient');

    // A lookup hands back its own handle to the same track, so the id is now
    // carried by two.
    final found = RtcVideoTrack.findById('transient');
    expect(found, isNotNull);

    found!.dispose();
    // Disposing the looked-up handle must not unpublish an id the original
    // still holds.
    final again = RtcVideoTrack.findById('transient');
    expect(again, isNotNull);
    again!.dispose();

    track.dispose();
    // Gone once the last handle to it does.
    expect(RtcVideoTrack.findById('transient'), isNull);

    // Disposed in order: nothing may outlive the factory that made it.
    source.dispose();
    factory.dispose();
  });

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
