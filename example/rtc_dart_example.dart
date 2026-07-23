// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

// A loopback between two peer connections in one process: video pushed from
// Dart, a data channel alongside it, and both kinds of statistics.
//
// Self-contained on purpose -- no signalling server, no second machine -- so
// it can be run as-is to see the whole API work:
//
//   dart run example/rtc_dart_example.dart [path/to/libwebrtc.so]
//
// Note what is NOT here: nothing reads a decoded frame. Frames go from the
// decoder to a native sink without entering Dart, and binding that sink is
// something a native consumer does. What Dart sees is that frames arrived and
// how big they were.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:rtc_dart/rtc_dart.dart';

const int _width = 320;
const int _height = 240;

/// A frame whose luma shifts with [n], so successive frames actually differ.
Uint8List _frame(int n) {
  final data = Uint8List(_width * _height * 3 ~/ 2);
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      data[y * _width + x] = (x + y + n * 3) & 0xff;
    }
  }
  data.fillRange(_width * _height, data.length, 128); // flat chroma
  return data;
}

Future<void> main(List<String> args) async {
  final soPath = args.isNotEmpty
      ? args.first
      : Platform.environment['LIBWEBRTC_SO'] ?? 'libwebrtc.so';

  Rtc.initialize(libraryPath: soPath);
  stdout.writeln('libwebrtc ABI ${Rtc.abiVersion}');

  final factory = RtcFactory.create();
  final caller = factory.createPeerConnection();
  final callee = factory.createPeerConnection();

  // Candidates are dropped unless the far side already has a remote
  // description, so hold them until it does.
  var calleeReady = false;
  var callerReady = false;
  final forCallee = <RtcIceCandidate>[];
  final forCaller = <RtcIceCandidate>[];
  caller.onIceCandidate.listen(
      (c) => calleeReady ? callee.addIceCandidate(c) : forCallee.add(c));
  callee.onIceCandidate.listen(
      (c) => callerReady ? caller.addIceCandidate(c) : forCaller.add(c));

  caller.onConnectionState.listen((s) => stdout.writeln('caller: $s'));

  // Subscribe before negotiating: these fire during it.
  final remoteTransceiver = callee.onTrack.first;
  final remoteChannel = callee.onDataChannel.first;

  final source = factory.createVideoSource(label: 'example-source');
  final localTrack = factory.createVideoTrack(source, id: 'example-video');
  final sender = caller.addTrack(localTrack, streamIds: ['example-stream']);
  final channel = caller.createDataChannel('example-data');

  final offer = await caller.createOffer();
  await caller.setLocalDescription(offer);
  await callee.setRemoteDescription(offer);
  calleeReady = true;
  forCallee.forEach(callee.addIceCandidate);

  final answer = await callee.createAnswer();
  await callee.setLocalDescription(answer);
  await caller.setRemoteDescription(answer);
  callerReady = true;
  forCaller.forEach(caller.addIceCandidate);

  final transceiver = await remoteTransceiver;
  final remoteTrack = transceiver.receiver!.videoTrack!;
  stdout.writeln('remote track: ${remoteTrack.enabled ? "enabled" : "muted"}');

  var received = 0;
  remoteTrack.onFrame.listen((_) => received++);

  final remote = await remoteChannel;
  remote.onMessage.listen(
      (m) => stdout.writeln('callee got ${m.isBinary ? "binary" : "text"}: '
          '${m.isBinary ? m.data : m.text}'));
  await channel.whenOpen;
  channel.sendText('hello over the data channel');

  // Feed at roughly 30fps.
  var pushed = 0;
  final feeder = Timer.periodic(const Duration(milliseconds: 33),
      (_) => source.pushI420(_frame(pushed++), width: _width, height: _height));

  for (var second = 0; second < 3; second++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final pipeline = remoteTrack.stats;
    stdout.writeln('pushed=$pushed received=$received  $pipeline  '
        'zeroCopy=${pipeline.isZeroCopy}');
  }
  feeder.cancel();

  final reports = await callee.getStats();
  final inbound = reports.firstWhere((r) => r['type'] == 'inbound-rtp',
      orElse: () => const {});
  stdout.writeln('inbound-rtp: framesDecoded=${inbound["framesDecoded"]} '
      'bytesReceived=${inbound["bytesReceived"]} '
      'fps=${inbound["framesPerSecond"]}');

  // Listening to a stream registers a native callback, and a live one keeps
  // the isolate alive -- so this is not optional if the process is to exit.
  for (final handle in [
    remote,
    channel,
    remoteTrack,
    transceiver,
    sender,
    localTrack,
    source,
    caller,
    callee,
    factory,
  ]) {
    handle.dispose();
  }
  Rtc.terminate();
}
