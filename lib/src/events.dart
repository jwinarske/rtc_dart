// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'ffi/lw_bindings.dart' as lw;

/// Signaling state of a peer connection.
enum RtcSignalingState {
  /// Spec name: `stable`.
  stable,

  /// Spec name: `have-local-offer`.
  haveLocalOffer,

  /// Spec name: `have-remote-offer`.
  haveRemoteOffer,

  /// Spec name: `have-local-pranswer`.
  haveLocalPrAnswer,

  /// Spec name: `have-remote-pranswer`.
  haveRemotePrAnswer,

  /// Spec name: `closed`.
  closed;
}

/// Aggregate connection state of a peer connection.
enum RtcPeerConnectionState {
  /// Spec name: `new`.
  initial,

  /// Spec name: `connecting`.
  connecting,

  /// Spec name: `connected`.
  connected,

  /// Spec name: `disconnected`.
  disconnected,

  /// Spec name: `failed`.
  failed,

  /// Spec name: `closed`.
  closed;
}

/// How far ICE gathering has progressed.
enum RtcIceGatheringState {
  /// Spec name: `new`.
  initial,

  /// Spec name: `gathering`.
  gathering,

  /// Spec name: `complete`.
  complete;
}

/// State of the ICE transport.
enum RtcIceConnectionState {
  /// Spec name: `new`.
  initial,

  /// Spec name: `checking`.
  checking,

  /// Spec name: `completed`.
  completed,

  /// Spec name: `connected`.
  connected,

  /// Spec name: `failed`.
  failed,

  /// Spec name: `disconnected`.
  disconnected,

  /// Spec name: `closed`.
  closed;
}

/// A session description: the SDP text and whether it is an offer or answer.
class RtcSessionDescription {
  const RtcSessionDescription({required this.sdp, required this.type});

  /// Offer of the given [sdp].
  const RtcSessionDescription.offer(this.sdp) : type = 'offer';

  /// Answer of the given [sdp].
  const RtcSessionDescription.answer(this.sdp) : type = 'answer';

  final String sdp;

  /// `offer` or `answer`.
  final String type;

  @override
  String toString() => 'RtcSessionDescription($type, ${sdp.length} bytes)';
}

/// State of a data channel.
enum RtcDataChannelState {
  connecting,
  open,
  closing,
  closed;
}

/// One message received on a data channel.
///
/// Carries the bytes as they arrived. [text] decodes them as UTF-8, which is
/// what the far side sent if it sent text; a binary message may not decode.
class RtcDataChannelMessage {
  const RtcDataChannelMessage({required this.data, required this.isBinary});

  /// The message as it arrived.
  final Uint8List data;

  /// Whether the far side marked this a binary message rather than text.
  final bool isBinary;

  /// The bytes decoded as UTF-8. Throws on a binary message that is not valid
  /// UTF-8, which is why [isBinary] is worth checking first.
  String get text => utf8.decode(data);

  @override
  String toString() => 'RtcDataChannelMessage(${isBinary ? "binary" : "text"}, '
      '${data.length} bytes)';
}

/// A local or remote ICE candidate.
class RtcIceCandidate {
  const RtcIceCandidate({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
  });

  final String candidate;

  /// Media stream identification of the m-section this belongs to.
  final String sdpMid;

  /// Index of that m-section in the SDP.
  final int sdpMLineIndex;

  @override
  String toString() =>
      'RtcIceCandidate($sdpMid#$sdpMLineIndex, ${candidate.length} bytes)';
}

/// The size of one frame a track delivered.
class RtcFrameInfo {
  const RtcFrameInfo({required this.width, required this.height});

  final int width;
  final int height;

  @override
  String toString() => 'RtcFrameInfo(${width}x$height)';
}

/// What a track's local pipeline did with the frames it decoded.
///
/// Describes this side only -- what the decoder produced and where it went.
/// It says nothing about the network.
///
/// No rates: take two samples and divide by the elapsed time to get a rate
/// over whatever window suits, rather than one chosen here.
class RtcVideoStats {
  const RtcVideoStats({
    required this.framesDelivered,
    required this.framesNative,
    required this.framesCpu,
    required this.framesDropped,
    required this.lastWidth,
    required this.lastHeight,
    required this.lastFrameAt,
  });

  /// Every decoded frame the track delivered, whatever path it then took.
  final int framesDelivered;

  /// Delivered as a dmabuf to a bound sink, which the sink took.
  final int framesNative;

  /// Delivered through the software path, so the frame was converted.
  /// Nonzero means the zero-copy path is not in use.
  final int framesCpu;

  /// Native frames that reached no sink: none bound, the sink declined, or
  /// the buffer was some other implementation's native type.
  final int framesDropped;

  /// Geometry of the most recent frame, or 0 before the first.
  final int lastWidth;
  final int lastHeight;

  /// When the most recent frame arrived, on the system's monotonic clock, or
  /// null before the first. Comparable only with other values from this
  /// clock -- it is not wall time.
  final Duration? lastFrameAt;

  /// Whether every frame so far reached a sink as a dmabuf.
  bool get isZeroCopy =>
      framesDelivered > 0 && framesCpu == 0 && framesDropped == 0;

  @override
  String toString() => 'RtcVideoStats(delivered: $framesDelivered, '
      'native: $framesNative, cpu: $framesCpu, dropped: $framesDropped, '
      'last: ${lastWidth}x$lastHeight)';
}

// The observer delivers plain ints. These map them; they live in lib/src and
// are not exported, so they stay internal to the package.

RtcDataChannelState dataChannelStateFromNative(int value) =>
    switch (lw.lw_data_channel_state.fromValue(value)) {
      lw.lw_data_channel_state.LW_DATA_CHANNEL_CONNECTING =>
        RtcDataChannelState.connecting,
      lw.lw_data_channel_state.LW_DATA_CHANNEL_OPEN => RtcDataChannelState.open,
      lw.lw_data_channel_state.LW_DATA_CHANNEL_CLOSING =>
        RtcDataChannelState.closing,
      lw.lw_data_channel_state.LW_DATA_CHANNEL_CLOSED =>
        RtcDataChannelState.closed,
    };

RtcSignalingState signalingStateFromNative(int value) =>
    switch (lw.lw_signaling_state.fromValue(value)) {
      lw.lw_signaling_state.LW_SIGNALING_STABLE => RtcSignalingState.stable,
      lw.lw_signaling_state.LW_SIGNALING_HAVE_LOCAL_OFFER =>
        RtcSignalingState.haveLocalOffer,
      lw.lw_signaling_state.LW_SIGNALING_HAVE_REMOTE_OFFER =>
        RtcSignalingState.haveRemoteOffer,
      lw.lw_signaling_state.LW_SIGNALING_HAVE_LOCAL_PRANSWER =>
        RtcSignalingState.haveLocalPrAnswer,
      lw.lw_signaling_state.LW_SIGNALING_HAVE_REMOTE_PRANSWER =>
        RtcSignalingState.haveRemotePrAnswer,
      lw.lw_signaling_state.LW_SIGNALING_CLOSED => RtcSignalingState.closed,
    };

RtcPeerConnectionState connectionStateFromNative(int value) =>
    switch (lw.lw_pc_state.fromValue(value)) {
      lw.lw_pc_state.LW_PC_STATE_NEW => RtcPeerConnectionState.initial,
      lw.lw_pc_state.LW_PC_STATE_CONNECTING =>
        RtcPeerConnectionState.connecting,
      lw.lw_pc_state.LW_PC_STATE_CONNECTED => RtcPeerConnectionState.connected,
      lw.lw_pc_state.LW_PC_STATE_DISCONNECTED =>
        RtcPeerConnectionState.disconnected,
      lw.lw_pc_state.LW_PC_STATE_FAILED => RtcPeerConnectionState.failed,
      lw.lw_pc_state.LW_PC_STATE_CLOSED => RtcPeerConnectionState.closed,
    };

RtcIceGatheringState iceGatheringStateFromNative(int value) =>
    switch (lw.lw_ice_gathering_state.fromValue(value)) {
      lw.lw_ice_gathering_state.LW_ICE_GATHERING_NEW =>
        RtcIceGatheringState.initial,
      lw.lw_ice_gathering_state.LW_ICE_GATHERING_GATHERING =>
        RtcIceGatheringState.gathering,
      lw.lw_ice_gathering_state.LW_ICE_GATHERING_COMPLETE =>
        RtcIceGatheringState.complete,
    };

RtcIceConnectionState iceConnectionStateFromNative(int value) =>
    switch (lw.lw_ice_connection_state.fromValue(value)) {
      lw.lw_ice_connection_state.LW_ICE_CONNECTION_NEW =>
        RtcIceConnectionState.initial,
      lw.lw_ice_connection_state.LW_ICE_CONNECTION_CHECKING =>
        RtcIceConnectionState.checking,
      lw.lw_ice_connection_state.LW_ICE_CONNECTION_COMPLETED =>
        RtcIceConnectionState.completed,
      lw.lw_ice_connection_state.LW_ICE_CONNECTION_CONNECTED =>
        RtcIceConnectionState.connected,
      lw.lw_ice_connection_state.LW_ICE_CONNECTION_FAILED =>
        RtcIceConnectionState.failed,
      lw.lw_ice_connection_state.LW_ICE_CONNECTION_DISCONNECTED =>
        RtcIceConnectionState.disconnected,
      lw.lw_ice_connection_state.LW_ICE_CONNECTION_CLOSED =>
        RtcIceConnectionState.closed,
    };
