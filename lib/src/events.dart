// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

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

// The observer delivers plain ints. These map them; they live in lib/src and
// are not exported, so they stay internal to the package.

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
