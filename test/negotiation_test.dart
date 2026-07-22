// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

// Negotiates between two peer connections entirely through the Dart API, which
// exercises the callback paths: SDP futures and event streams both come from
// native callbacks that fire on webrtc's signaling thread.

import 'dart:async';
import 'dart:io';

import 'package:rtc_dart/rtc_dart.dart';
import 'package:test/test.dart';

String get _soPath =>
    Platform.environment['LIBWEBRTC_SO'] ??
    '/mnt/dev/webrtc-build/src/out-x64-release/libwebrtc.so';

/// Forwards local candidates to [to], buffering until it has a remote
/// description -- a candidate offered before then is dropped.
class _CandidatePump {
  _CandidatePump(this.from, this.to) {
    _subscription = from.onIceCandidate.listen((candidate) {
      if (_ready) {
        to.addIceCandidate(candidate);
      } else {
        _pending.add(candidate);
      }
    });
  }

  final RtcPeerConnection from;
  final RtcPeerConnection to;
  final List<RtcIceCandidate> _pending = [];
  late final StreamSubscription<RtcIceCandidate> _subscription;
  bool _ready = false;

  void release() {
    _ready = true;
    for (final candidate in _pending) {
      to.addIceCandidate(candidate);
    }
    _pending.clear();
  }

  Future<void> cancel() => _subscription.cancel();
}

void main() {
  setUpAll(() {
    if (!File(_soPath).existsSync()) {
      throw StateError('libwebrtc.so not found at $_soPath');
    }
    Rtc.initialize(libraryPath: _soPath);
  });

  test('completes an offer/answer exchange and connects', () async {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final caller = factory.createPeerConnection();
    final callee = factory.createPeerConnection();
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    // Subscribe before anything can fire.
    final calleeConnected = callee.onConnectionState
        .firstWhere((s) => s == RtcPeerConnectionState.connected);
    final callerConnected = caller.onConnectionState
        .firstWhere((s) => s == RtcPeerConnectionState.connected);
    final remoteTrack = callee.onTrack.first;
    final gathered = caller.onIceGatheringState
        .firstWhere((s) => s == RtcIceGatheringState.complete);

    final toCallee = _CandidatePump(caller, callee);
    final toCaller = _CandidatePump(callee, caller);
    addTearDown(toCallee.cancel);
    addTearDown(toCaller.cancel);

    caller.addTransceiver(MediaKind.video).dispose();

    final offer = await caller.createOffer();
    expect(offer.type, 'offer');
    expect(offer.sdp, contains('m=video'));

    await caller.setLocalDescription(offer);
    await callee.setRemoteDescription(offer);
    toCallee.release();

    final answer = await callee.createAnswer();
    expect(answer.type, 'answer');

    await callee.setLocalDescription(answer);
    await caller.setRemoteDescription(answer);
    toCaller.release();

    final transceiver = await remoteTrack.timeout(const Duration(seconds: 15));
    addTearDown(transceiver.dispose);
    expect(transceiver.receiver, isNotNull);

    await Future.wait([callerConnected, calleeConnected])
        .timeout(const Duration(seconds: 30));
    await gathered.timeout(const Duration(seconds: 30));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('reports signaling state as descriptions are applied', () async {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final pc = factory.createPeerConnection();
    addTearDown(pc.dispose);

    final haveLocalOffer = pc.onSignalingState
        .firstWhere((s) => s == RtcSignalingState.haveLocalOffer);

    pc.addTransceiver(MediaKind.video).dispose();
    await pc.setLocalDescription(await pc.createOffer());
    await haveLocalOffer.timeout(const Duration(seconds: 10));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('surfaces a native failure as a rejected future', () async {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final pc = factory.createPeerConnection();
    addTearDown(pc.dispose);

    // An answer with nothing to answer, and syntactically invalid SDP.
    await expectLater(pc.createAnswer(), throwsA(isA<RtcNativeException>()));
    await expectLater(
      pc.setRemoteDescription(const RtcSessionDescription.offer('not sdp')),
      throwsA(isA<RtcNativeException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a request outstanding at dispose is rejected, not left hanging',
      () async {
    final factory = RtcFactory.create();
    addTearDown(factory.dispose);
    final pc = factory.createPeerConnection();

    pc.addTransceiver(MediaKind.video).dispose();
    final pending = pc.createOffer();
    pc.dispose();
    // Either it completed before dispose or dispose rejected it; both are
    // fine, hanging is not.
    await pending.then((_) {}, onError: (Object e) => expect(e, isNotNull));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
