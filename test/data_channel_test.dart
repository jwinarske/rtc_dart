// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

// A data channel driven entirely from Dart: the caller opens one, the callee
// learns of it through the peer connection, and each sends the other a message.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:rtc_dart/rtc_dart.dart';
import 'package:test/test.dart';

String get _soPath =>
    Platform.environment['LIBWEBRTC_SO'] ??
    '/mnt/dev/webrtc-build/src/out-x64-release/libwebrtc.so';

/// Starts with a zero byte on purpose: a length that is not honoured somewhere
/// truncates this to nothing, and two empty buffers would compare equal.
final _binaryMessage = Uint8List.fromList([0x00, 0x01, 0x02, 0xfe, 0xff]);
const _textMessage = 'ping from the caller';

void main() {
  setUpAll(() {
    if (!File(_soPath).existsSync()) {
      throw StateError('libwebrtc.so not found at $_soPath');
    }
    Rtc.initialize(libraryPath: _soPath);
  });

  test('carries a message each way', () async {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final caller = factory.createPeerConnection();
    final callee = factory.createPeerConnection();
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    final remoteChannel = callee.onDataChannel.first;

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

    final channel = caller.createDataChannel('e2e-data');
    addTearDown(channel.dispose);
    expect(channel.label, 'e2e-data');

    final binaryArrived = channel.onMessage.first;

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

    final remote = await remoteChannel.timeout(const Duration(seconds: 20));
    addTearDown(remote.dispose);
    expect(remote.label, 'e2e-data');

    final textArrived = remote.onMessage.first;
    // A channel arriving from the far side is usually open already, so this
    // has to tolerate a transition that has been and gone.
    await channel.whenOpen.timeout(const Duration(seconds: 20));
    await remote.whenOpen.timeout(const Duration(seconds: 20));

    channel.sendText(_textMessage);
    final received = await textArrived.timeout(const Duration(seconds: 20));
    expect(received.isBinary, isFalse);
    expect(received.text, _textMessage);

    remote.sendBinary(_binaryMessage);
    final echoed = await binaryArrived.timeout(const Duration(seconds: 20));
    expect(echoed.isBinary, isTrue);
    expect(echoed.data, _binaryMessage);
    expect(echoed.data.first, 0); // the byte a length-blind copy would lose

    expect(channel.state, RtcDataChannelState.open);
    expect(channel.id, isNotNull);
    expect(channel.bufferedAmount, isA<int>());
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('whenOpen settles for a channel that will never open', () async {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final pc = factory.createPeerConnection();
    addTearDown(pc.dispose);

    final channel = pc.createDataChannel('doomed');
    addTearDown(channel.dispose);
    channel.close();
    // Closing without a peer means it never opens; waiting has to fail rather
    // than hang.
    await expectLater(channel.whenOpen.timeout(const Duration(seconds: 10)),
        throwsA(isA<RtcNativeException>()));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('refuses a label or retransmit policy that cannot work', () {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final pc = factory.createPeerConnection();
    addTearDown(pc.dispose);

    expect(() => pc.createDataChannel(''), throwsArgumentError);
    // Both limits set is not "whichever fires first" -- it is ambiguous, so
    // it is refused rather than resolved silently.
    expect(
      () => pc.createDataChannel('x',
          maxRetransmits: 3, maxRetransmitTime: const Duration(seconds: 1)),
      throwsArgumentError,
    );
  });
}
