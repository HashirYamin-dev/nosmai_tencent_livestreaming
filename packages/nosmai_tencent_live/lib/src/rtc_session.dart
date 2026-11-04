import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_listener.dart';
import 'package:tencent_rtc_sdk/tx_device_manager.dart';

import 'credentials.dart';
import 'stats.dart';

typedef CloudFactory = Future<TRTCCloud> Function();

/// One Tencent room session for a broadcaster or a viewer.
///
/// Tencent 13.5 commands are synchronous and their outcomes arrive through
/// listener callbacks, so this class tracks state from those callbacks. The
/// broadcaster never opens a Tencent camera: Nosmai owns the camera and the
/// native bridge feeds Tencent's custom video input.
class RtcSession extends ChangeNotifier {
  RtcSession({
    required this.credentials,
    required this.room,
    required this.isHost,
    this.encoder,
    this.publishAudio = true,
    this.targetHostUserId,
    CloudFactory? cloudFactory,
    this.joinTimeout = const Duration(seconds: 25),
    this.exitTimeout = const Duration(seconds: 5),
    this.firstFrameTimeout = const Duration(seconds: 15),
  }) : cloudFactory = cloudFactory ?? TRTCCloud.sharedInstance;

  final NosmaiLiveCredentials credentials;
  final NosmaiLiveRoom room;
  final bool isHost;
  final TRTCVideoEncParam? encoder;
  final bool publishAudio;

  /// Viewer only: watch this user. When null the first broadcaster is used.
  final String? targetHostUserId;
  final CloudFactory cloudFactory;
  final Duration joinTimeout;
  final Duration exitTimeout;
  final Duration firstFrameTimeout;

  // If Tencent never confirms an exit, the shared engine is in an unknown
  // state; refuse new sessions instead of failing in confusing ways.
  static bool _restartRequired = false;

  TRTCCloud? _cloud;
  TRTCCloudListener? _listener;
  Completer<void>? _exitSignal;
  Future<void>? _closeFuture;
  Timer? _joinTimer;
  Timer? _frameTimer;
  int? _viewId;
  String? _boundRemote;
  final Set<String> _anchors = <String>{};
  final Set<String> _videoUsers = <String>{};
  final Set<String> _blockedRemotes = <String>{};
  bool _enterRequested = false;
  bool _audioStarted = false;
  bool _disposed = false;
  bool _started = false;
  bool _foreground = true;

  bool joined = false;
  bool closing = false;
  bool closed = false;
  bool reconnecting = false;
  bool micMuted = false;
  bool videoMuted = false;
  bool speakerMuted = false;
  bool firstFrame = false;
  bool videoPublished = false;
  String? hostUserId;
  String? error;
  String? warning;
  NosmaiLiveStats stats = NosmaiLiveStats.empty;

  bool get foreground => _foreground;
  bool get controlsEnabled => joined && !closing && error == null;

  /// Viewer: the room has a broadcaster with video.
  bool get hostVideoAvailable => hostUserId != null && _videoUsers.contains(hostUserId);

  /// Completes when the room is entered, or with an error if it fails first.
  Future<void> get entered => _entered.future;
  final Completer<void> _entered = Completer<void>();

  Future<void> start() async {
    if (_started || closing || _disposed) return;
    _started = true;
    try {
      final problem = credentials.validate() ?? room.validate();
      if (problem != null) throw StateError(problem);
      if (_restartRequired) {
        throw StateError('The previous Tencent session did not finish closing. '
            'Restart the app before starting another session.');
      }
      final cloud = await cloudFactory();
      if (closing || _disposed) return;
      _cloud = cloud;
      _listener = _buildListener();
      cloud.registerListener(_listener!);
      // Auto-receive keeps audio flowing; the viewer still binds video to the
      // selected broadcaster through startRemoteView.
      cloud.setDefaultStreamRecvMode(true, true);
      // The engine is process-wide; reset receive state left by a previous session.
      cloud.muteAllRemoteAudio(false);
      cloud.muteAllRemoteVideoStreams(false);
      if (isHost) {
        final param = encoder;
        if (param != null) cloud.setVideoEncoderParam(param);
        cloud.setVideoEncoderMirror(false);
      }
      if (closing || _disposed) return;
      _enterRequested = true;
      _joinTimer = Timer(joinTimeout, () {
        _fail('Joining the Tencent room timed out. Check the network, SDKAppID, '
            'UserSig and that the TRTC service is enabled for this application.');
      });
      final numericId = room.numericId;
      cloud.enterRoom(
        TRTCParams(
          sdkAppId: credentials.sdkAppId,
          userId: credentials.userId,
          userSig: credentials.userSig,
          roomId: numericId ?? 0,
          strRoomId: numericId == null ? room.name! : '',
          role: isHost ? TRTCRoleType.anchor : TRTCRoleType.audience,
        ),
        TRTCAppScene.live,
      );
    } catch (e) {
      _fail('Could not start Tencent: ${e is StateError ? e.message : e}');
    }
  }

  TRTCCloudListener _buildListener() => TRTCCloudListener(
        onError: (code, message) => _fail('Tencent error $code: $message'),
        onWarning: (code, message) {
          if (closing) return;
          warning = 'Tencent warning $code: $message';
          _notify();
        },
        onEnterRoom: _onEnterRoom,
        onExitRoom: _onExitRoom,
        onStatistics: _onStatistics,
        onRemoteUserEnterRoom: (userId) {
          _blockedRemotes.remove(userId);
          if (closing || isHost) return;
          _anchors.add(userId);
          _selectHost();
        },
        onRemoteUserLeaveRoom: (userId, reason) {
          _blockedRemotes.add(userId);
          if (_boundRemote == userId) _stopRemote();
          if (closing || isHost) return;
          _anchors.remove(userId);
          _videoUsers.remove(userId);
          if (hostUserId == userId) {
            _cloud?.muteRemoteAudio(userId, true);
            hostUserId = null;
            firstFrame = false;
          }
          _selectHost();
        },
        onUserVideoAvailable: (userId, available) {
          if (available) {
            _blockedRemotes.remove(userId);
          } else {
            _blockedRemotes.add(userId);
            if (_boundRemote == userId) _stopRemote();
          }
          if (closing || isHost) return;
          if (available) {
            _anchors.add(userId);
            _videoUsers.add(userId);
          } else {
            _videoUsers.remove(userId);
            if (hostUserId == userId) firstFrame = false;
          }
          _selectHost();
        },
        onUserAudioAvailable: (userId, available) {
          if (closing || isHost) return;
          // A late "unavailable" after an exit must not revive a stale host.
          if (available) _anchors.add(userId);
          _selectHost();
        },
        onFirstVideoFrame: (userId, streamType, width, height) {
          if (closing || !_foreground || isHost) return;
          final watched = userId == _boundRemote &&
              streamType != TRTCVideoStreamType.sub &&
              !_blockedRemotes.contains(userId);
          if (!watched) return;
          hostUserId = userId;
          _anchors.add(userId);
          _videoUsers.add(userId);
          firstFrame = true;
          _frameTimer?.cancel();
          warning = null;
          _notify();
        },
        onSendFirstLocalVideoFrame: (streamType) {
          if (closing || !isHost) return;
          videoPublished = true;
          firstFrame = true;
          _frameTimer?.cancel();
          warning = null;
          _notify();
        },
        onConnectionLost: _onReconnecting,
        onTryToReconnect: _onReconnecting,
        onConnectionRecovery: () {
          if (closing) return;
          reconnecting = false;
          _syncMediaSafely();
          _notify();
        },
      );

  void _onEnterRoom(int result) {
    if (closing) return;
    _joinTimer?.cancel();
    if (result < 0) {
      _fail('Could not enter the Tencent room (code $result). Check SDKAppID, '
          'UserSig expiry, and that each device uses a different userId.');
      return;
    }
    joined = true;
    if (!_entered.isCompleted) _entered.complete();
    try {
      _cloud?.getDeviceManager().setAudioRoute(TXAudioRoute.speakerPhone);
    } catch (_) {/* Keep the platform's default audio route. */}
    _syncMediaSafely();
    if (isHost) _watchFirstFrame();
    _notify();
  }

  void _onExitRoom(int reason) {
    _enterRequested = false;
    joined = false;
    final signal = _exitSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
    if (!closing) {
      _fail('The Tencent session ended (reason $reason). Another login with the '
          'same userId or a server-side room closure can end a session.');
    }
  }

  void _onReconnecting() {
    if (closing) return;
    reconnecting = true;
    _notify();
  }

  void _onStatistics(TRTCStatistics statistics) {
    if (closing) return;
    var next = stats.copyWith(
      rttMs: statistics.rtt,
      upLossPercent: statistics.upLoss,
      downLossPercent: statistics.downLoss,
    );
    if (isHost) {
      for (final local in statistics.localStatisticsArray ?? const <TRTCLocalStatistics>[]) {
        if (local.streamType != TRTCVideoStreamType.big) continue;
        next = next.copyWith(
          width: local.width,
          height: local.height,
          fps: local.frameRate,
          videoBitrateKbps: local.videoBitrate,
          audioBitrateKbps: local.audioBitrate,
        );
      }
    } else {
      for (final remote in statistics.remoteStatisticsArray ?? const <TRTCRemoteStatistics>[]) {
        if (remote.userId != hostUserId || remote.streamType != TRTCVideoStreamType.big) continue;
        next = next.copyWith(
          width: remote.width,
          height: remote.height,
          fps: remote.frameRate,
          videoBitrateKbps: remote.videoBitrate,
          audioBitrateKbps: remote.audioBitrate,
        );
      }
    }
    stats = next;
    _notify();
  }

  void _selectHost() {
    final target = targetHostUserId;
    if (hostUserId == null) {
      if (target != null) {
        if (_anchors.contains(target)) hostUserId = target;
      } else if (_anchors.isNotEmpty) {
        hostUserId = _anchors.first;
      }
      if (hostUserId != null) {
        firstFrame = false;
        warning = null;
      }
    }
    _syncMediaSafely();
    _notify();
  }

  /// Viewer: called when the platform video view exists. Binding only once
  /// both the view and the room are ready avoids a black-screen race.
  void attachVideoView(int viewId) {
    if (closing || _disposed) return;
    if (_viewId != null && _viewId != viewId) _stopRemote();
    _viewId = viewId;
    _syncMediaSafely();
    _notify();
  }

  /// Viewer: the platform view is going away.
  void detachVideoView(int viewId) {
    if (_viewId != viewId) return;
    _stopRemote();
    _viewId = null;
    _notify();
  }

  void _syncMediaSafely() {
    if (closing || !joined || _cloud == null) return;
    try {
      if (isHost) {
        _syncHost();
      } else {
        _syncViewer();
      }
    } catch (e) {
      _fail('Could not update livestream media: $e');
    }
  }

  void _syncHost() {
    final cloud = _cloud!;
    final wantAudio = publishAudio && _foreground && !micMuted;
    if (wantAudio && !_audioStarted) {
      cloud.startLocalAudio(TRTCAudioQuality.defaultMode);
      _audioStarted = true;
    } else if (!wantAudio && _audioStarted) {
      cloud.stopLocalAudio();
      _audioStarted = false;
    }
    cloud.muteLocalVideo(TRTCVideoStreamType.big, videoMuted || !_foreground);
  }

  void _syncViewer() {
    final cloud = _cloud!;
    final host = hostUserId;
    if (host == null || host.isEmpty) return;
    if (!_foreground || _blockedRemotes.contains(host)) {
      cloud.muteRemoteAudio(host, true);
      _stopRemote();
      return;
    }
    cloud.muteRemoteAudio(host, speakerMuted);
    if (_viewId == null || _boundRemote == host) return;
    _stopRemote();
    cloud.setRemoteRenderParams(host, TRTCVideoStreamType.big,
        TRTCRenderParams(fillMode: TRTCVideoFillMode.fit));
    _boundRemote = host;
    cloud.startRemoteView(host, TRTCVideoStreamType.big, _viewId!);
    _watchFirstFrame();
  }

  void _watchFirstFrame() {
    _frameTimer?.cancel();
    _frameTimer = Timer(firstFrameTimeout, () {
      if (!closing && _foreground && !firstFrame) {
        warning = isHost
            ? 'No video sent yet. Keep the Nosmai camera preview on screen.'
            : 'No video yet. Check that the broadcaster is live and both networks.';
        _notify();
      }
    });
  }

  void _stopRemote() {
    final previous = _boundRemote;
    _boundRemote = null;
    if (previous != null) {
      _cloud?.stopRemoteView(previous, TRTCVideoStreamType.big);
    }
    firstFrame = false;
    _frameTimer?.cancel();
  }

  void setMicMuted(bool muted) {
    if (!isHost || micMuted == muted) return;
    micMuted = muted;
    _syncMediaSafely();
    _notify();
  }

  void setVideoMuted(bool muted) {
    if (!isHost || videoMuted == muted) return;
    videoMuted = muted;
    _syncMediaSafely();
    _notify();
  }

  void setSpeakerMuted(bool muted) {
    if (isHost || speakerMuted == muted) return;
    speakerMuted = muted;
    _syncMediaSafely();
    _notify();
  }

  void setForeground(bool foreground) {
    if (closing || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground && !isHost) firstFrame = false;
    _syncMediaSafely();
    _notify();
  }

  void _fail(String message) {
    if (closing || _disposed) return;
    // Never surface or log the UserSig. Real UserSigs are long; redacting a
    // short placeholder would mangle the message instead.
    final sig = credentials.userSig.trim();
    error = sig.length < 8 ? message : message.replaceAll(sig, '[redacted]');
    if (!_entered.isCompleted) _entered.completeError(StateError(error!));
    _notify();
    unawaited(close());
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    closing = true;
    _joinTimer?.cancel();
    _frameTimer?.cancel();
    if (!_entered.isCompleted) {
      _entered.completeError(StateError(error ?? 'The session was closed'));
    }
    // Callers that never awaited [entered] must not see an unhandled error.
    unawaited(_entered.future.catchError((_) {}));
    _notify();
    final cloud = _cloud;
    if (cloud != null) {
      // Run every cleanup step even if one native call fails.
      for (final stop in <void Function()>[
        cloud.stopLocalAudio,
        cloud.stopAllRemoteView,
        () => cloud.muteAllRemoteAudio(true),
      ]) {
        try {
          stop();
        } catch (_) {/* Continue releasing other resources. */}
      }
      if (_enterRequested) {
        _exitSignal = Completer<void>();
        try {
          cloud.exitRoom();
          await _exitSignal!.future.timeout(exitTimeout);
        } catch (_) {
          _restartRequired = true;
          warning = 'Tencent did not confirm leaving the room. Restart the app '
              'before starting another session.';
        }
      }
      final listener = _listener;
      if (listener != null) {
        try {
          cloud.unRegisterListener(listener);
        } catch (_) {/* Best effort. */}
      }
    }
    // Keep the process-wide engine alive: destroying it while a native video
    // view is disposing races on iOS. exitRoom releases the media resources.
    _cloud = null;
    _listener = null;
    _audioStarted = false;
    _boundRemote = null;
    joined = false;
    firstFrame = false;
    closed = true;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }

  @visibleForTesting
  static void resetRestartGuardForTesting() => _restartRequired = false;
}
