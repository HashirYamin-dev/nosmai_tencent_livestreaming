import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_listener.dart';
import 'package:tencent_rtc_sdk/tx_device_manager.dart';

import 'app_credentials.dart';

/// One foreground-only livestream session. Tencent 13.5.2 uses typed listeners
/// and synchronous commands; room entry/exit complete through callbacks.
class LiveSession extends ChangeNotifier {
  LiveSession({
    required this.credentials,
    required this.roomId,
    required this.isHost,
    this.customVideoInput = false,
    this.expectedHostUserId,
    this.expectedSdkAppId,
    this.cloudFactory = TRTCCloud.sharedInstance,
    this.joinTimeout = const Duration(seconds: 25),
    this.exitTimeout = const Duration(seconds: 5),
  });

  final AppCredentials credentials;
  final int roomId;
  final bool isHost;
  /// Nosmai already owns the camera; TRTC must never open a second one.
  final bool customVideoInput;
  // VIEWER_RECEIVE_FIX_V1: known target is not proof of a received stream.
  final String? expectedHostUserId;
  final int? expectedSdkAppId;
  final Set<String> _blockedRemotes = <String>{};
  String lastRtcEvent = 'Initializing';
  String transportInfo = 'No RTC stats yet';

  void _trace(String event) {
    lastRtcEvent = event;
    debugPrint('[TRTC-QA] ${credentials.userId} room=$roomId $event');
  }

  String get diagnostics =>
      'SDK ${credentials.sdkAppId} | Room $roomId (numeric)\n'
      '${isHost ? "Anchor" : "Audience"}: ${credentials.userId} '
      '| Joined: $joined\n'
      '${isHost ? "Video sent: $videoPublished" : "Target: ${hostUserId ?? expectedHostUserId ?? '-'} | Requested: ${_boundRemote != null} | Frame: $firstFrame"}\n'
      '$lastRtcEvent\n$transportInfo';
  final Future<TRTCCloud> Function() cloudFactory;
  final Duration joinTimeout;
  final Duration exitTimeout;

  // If an SDK fails to confirm exit, do not reuse an indeterminate room state.
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
  bool _enterRequested = false;
  bool _previewStarted = false;
  bool _audioStarted = false;
  bool _disposed = false;
  bool _started = false;
  bool _foreground = true;

  bool engineReady = false;
  bool joined = false;
  bool closing = false;
  bool closed = false;
  bool reconnecting = false;
  bool micMuted = false;
  bool cameraOff = false;
  bool speakerMuted = false;
  bool frontCamera = true;
  bool firstFrame = false;
  bool videoPublished = false;
  String? hostUserId;
  String? error;
  String? warning;

  bool get controlsEnabled => joined && !closing && error == null;
  bool get showVideo =>
      firstFrame &&
      _foreground &&
      error == null &&
      (isHost ? !cameraOff : hostUserId != null);

  String get status {
    if (error != null) return 'Session stopped';
    if (closing) return closed ? 'Session ended' : 'Leaving room…';
    if (!joined) return 'Connecting to Tencent…';
    if (!_foreground) return 'Paused while app is in the background';
    if (reconnecting) return 'Connection lost · Reconnecting…';
    if (isHost) {
      if (cameraOff) return 'Live · Camera off';
      return videoPublished ? 'LIVE' : 'Starting camera stream…';
    }
    if (hostUserId == null) {
      return _boundRemote == null ? 'Waiting for host…' : 'Requesting host stream…';
    }
    if (!_videoUsers.contains(hostUserId)) return 'Host video is unavailable';
    return firstFrame ? 'Watching live' : 'Loading host video…';
  }

  Future<void> start() async {
    if (_started || closing || _disposed) return;
    _started = true;
    try {
      final problem = credentials.validate();
      if (problem != null) throw StateError(problem);
      if (expectedSdkAppId != null && credentials.sdkAppId != expectedSdkAppId) {
        throw StateError('SDKAppID mismatch. Rebuild both phones from this project.');
      }
      if (expectedHostUserId != null &&
          (isHost ? credentials.userId != expectedHostUserId
                  : credentials.userId == expectedHostUserId)) {
        throw StateError('Wrong User ID for this role. Stop this build and use '
            'plain flutter run; Start Live and Watch Live need different users.');
      }
      if (_restartRequired) {
        throw StateError('The previous SDK session did not finish releasing. '
            'Fully close this app and open it again.');
      }
      final cloud = await cloudFactory();
      if (closing || _disposed) return;
      _cloud = cloud;
      _listener = TRTCCloudListener(
        onError: (code, message) => _fail('Tencent error $code: $message'),
        onWarning: (code, message) {
          if (closing) return;
          warning = 'Tencent warning $code: $message';
          _notify();
        },
        onEnterRoom: _onEnterRoom,
        onCameraDidReady: () => _trace('camera ready'),
        onStatistics: (statistics) {
          // Real transport metrics every ~2s. The first-frame event alone is not
          // proof of a continuing video stream.
          try {
            final local = (statistics.localStatisticsArray ?? [])
                .map((e) => e.toJson()).toList();
            final remote = (statistics.remoteStatisticsArray ?? [])
                .map((e) => e.toJson()).toList();
            transportInfo = 'RTT ${statistics.rtt}ms '
                'loss↑${statistics.upLoss}% ↓${statistics.downLoss}% '
                'local=$local remote=$remote';
            debugPrint('[TRTC-STATS] ${credentials.userId} $transportInfo');
            _notify();
          } catch (e) {
            debugPrint('[TRTC-STATS] Failed to format stats: $e');
          }
        },
        onRemoteVideoStatusUpdated: (userId, type, status, reason) {
          _trace('remote video $userId status=$status reason=$reason');
        },
        onExitRoom: _onExitRoom,
        onRemoteUserEnterRoom: (userId) {
          _trace('anchor entered: $userId');
          _blockedRemotes.remove(userId);
          if (closing || isHost) return;
          _anchors.add(userId);
          _selectHost();
        },
        onRemoteUserLeaveRoom: (userId, reason) {
          _trace('anchor left: $userId reason=$reason');
          _blockedRemotes.add(userId);
          if (_boundRemote == userId) _stopRemote();
          if (closing || isHost) return;
          _anchors.remove(userId);
          _videoUsers.remove(userId);
          if (hostUserId == userId) {
            _stopRemote();
            _cloud?.muteRemoteAudio(userId, true);
            hostUserId = null;
            firstFrame = false;
          }
          _selectHost();
        },
        onUserVideoAvailable: (userId, available) {
          _trace('video available: $userId=$available');
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
            if (hostUserId == userId) {
              _stopRemote();
              firstFrame = false;
            }
          }
          _selectHost();
        },
        onUserAudioAvailable: (userId, available) {
          if (closing || isHost) return;
          // A late unavailable event after an exit must not revive a stale host.
          if (available) _anchors.add(userId);
          _selectHost();
        },
        onFirstVideoFrame: (userId, streamType, width, height) {
          if (closing || !_foreground) return;
          final ours = isHost && userId.isEmpty && !cameraOff;
          final watched = !isHost && userId == _boundRemote &&
              streamType != TRTCVideoStreamType.sub &&
              !_blockedRemotes.contains(userId);
          if (watched) {
            hostUserId = userId;
            _anchors.add(userId);
            _videoUsers.add(userId);
          }
          if (ours || watched) {
            _trace('first video: ${userId.isEmpty ? "local" : userId} ${width}x$height');
            firstFrame = true;
            _frameTimer?.cancel();
            warning = null;
            _notify();
          }
        },
        onSendFirstLocalVideoFrame: (streamType) {
          if (!closing && isHost) {
            videoPublished = true;
            _trace('first local video sent');
            _notify();
          }
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
      cloud.registerListener(_listener!);
      // Manual subscription: a viewer subscribes only to the selected anchor;
      // a host does not accidentally play a second broadcaster's microphone.
      // TRTC_STABILITY_DIAGNOSTICS_2026_V1
      // Diagnostic A/B test: let SDK auto-subscribe. The viewer still binds
      // the actual selected host to TRTCCloudVideoView via startRemoteView.
      cloud.setDefaultStreamRecvMode(true, true);
      // Explicitly reset receive state when reusing the process-wide engine.
      cloud.muteAllRemoteAudio(false);
      cloud.muteAllRemoteVideoStreams(false);
      if (isHost) {
        // Optional iPhone-only 360p/15fps bandwidth isolation. Off by default.
        // Pass --dart-define=IOS_TRTC_LOW_BW_TEST=true to enable on iPhone.
        const iosLowBwRequested = bool.fromEnvironment(
          'IOS_TRTC_LOW_BW_TEST', defaultValue: false);
        final iosLowBw = customVideoInput && !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.iOS && iosLowBwRequested;
        if (iosLowBw) {
          _trace('iOS LOW-BW test: 360x640, 15 FPS, 500 Kbps');
        }
        cloud.setVideoEncoderParam(TRTCVideoEncParam(
          videoResolution: iosLowBw
              ? TRTCVideoResolution.res_640_360
              : TRTCVideoResolution.res_960_540,
          videoResolutionMode: TRTCVideoResolutionMode.portrait,
          videoFps: iosLowBw ? 15 : 20,
          videoBitrate: iosLowBw ? 500 : 1200,
          minVideoBitrate: iosLowBw ? 180 : 300,
          enableAdjustRes: true,
        ));
        cloud.setVideoEncoderMirror(false);
        cloud.setLocalRenderParams(TRTCRenderParams(
          fillMode: TRTCVideoFillMode.fit,
          mirrorType: TRTCVideoMirrorType.auto,
        ));
      }
      engineReady = true;
      _notify();
      if (closing || _disposed) return;
      _enterRequested = true;
      _joinTimer = Timer(joinTimeout, () {
        _fail('Room entry timed out. Check the internet connection, SDKAppID, '
            'UserSig and your application RTC Engine service status.');
      });
      cloud.enterRoom(
        TRTCParams(
          sdkAppId: credentials.sdkAppId,
          userId: credentials.userId,
          userSig: credentials.userSig,
          roomId: roomId,
          role: isHost ? TRTCRoleType.anchor : TRTCRoleType.audience,
        ),
        TRTCAppScene.live,
      );
    } catch (e) {
      _fail('Could not start Tencent: $e');
    }
  }

  void _onEnterRoom(int result) {
    _trace('onEnterRoom=$result');
    if (closing) return;
    _joinTimer?.cancel();
    if (result < 0) {
      _fail('Could not enter room (code $result). Check SDKAppID, UserSig '
          'expiry, service activation and that each phone has a different User ID.');
      return;
    }
    joined = true;
    try {
      _cloud?.getDeviceManager().setAudioRoute(TXAudioRoute.speakerPhone);
    } catch (_) {/* Preserve the platform default audio route. */}
    _syncMediaSafely();
    _notify();
  }

  void _onExitRoom(int reason) {
    _enterRequested = false;
    joined = false;
    final signal = _exitSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
    if (!closing) {
      _fail('The session ended (reason $reason). Another login with the same '
          'User ID or a server-side room closure can interrupt a session.');
    }
  }

  void _onReconnecting() {
    if (closing) return;
    reconnecting = true;
    _notify();
  }

  void _selectHost() {
    if (hostUserId == null && _anchors.isNotEmpty) {
      hostUserId = _anchors.first;
      firstFrame = false;
      warning = null;
    }
    _syncMediaSafely();
    _notify();
  }

  /// Called by the native view, independent of the room/network callbacks.
  /// Binding only when both are ready avoids a common black-screen race.
  void attachVideoView(int viewId) {
    if (closing || _disposed) return;
    final changed = _viewId != null && _viewId != viewId;
    _viewId = viewId;
    if (changed) {
      if (isHost && _previewStarted) {
        _cloud?.updateLocalView(viewId);
      } else {
        _stopRemote();
      }
    }
    _syncMediaSafely(); _notify(); } void _syncMediaSafely() {
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
    if (!_foreground) {
      _stopHostCapture();
      return;
    }
    if (!_audioStarted && !micMuted) {
      cloud.startLocalAudio(TRTCAudioQuality.defaultMode);
      _audioStarted = true;
    } else if (_audioStarted && micMuted) {
      cloud.stopLocalAudio();
      _audioStarted = false;
    }
    if (cameraOff) {
      if (_previewStarted && !customVideoInput) cloud.stopLocalPreview();
      _previewStarted = false;
      firstFrame = false;
      videoPublished = false;
    } else if (customVideoInput) {
      // The Android MethodChannel bridge owns TRTC custom video capture.
      // It was enabled before entering the room. Never startLocalPreview.
      if (!_previewStarted) {
        _previewStarted = true;
        _watchFirstFrame();
      }
    } else if (_viewId != null && !_previewStarted) {
      cloud.startLocalPreview(frontCamera, _viewId!);
      _previewStarted = true;
      _watchFirstFrame();
    }
  }

  void _syncViewer() {
    final cloud = _cloud!;
    final host = hostUserId ?? expectedHostUserId;
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
    _trace('startRemoteView: $host view=$_viewId');
    cloud.startRemoteView(host, TRTCVideoStreamType.big, _viewId!);
    _watchFirstFrame();
  }

  void _watchFirstFrame() {
    _frameTimer?.cancel();
    _frameTimer = Timer(const Duration(seconds: 15), () {
      if (!closing && _foreground && !firstFrame) {
        warning = isHost
            ? 'No camera frame yet. Check camera permission and close other camera apps.'
            : 'No video frame yet. Keep the host live and check both network connections.';
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

  void _stopHostCapture() {
    if (_previewStarted && !customVideoInput) _cloud?.stopLocalPreview();
    if (_audioStarted) _cloud?.stopLocalAudio();
    _previewStarted = false;
    _audioStarted = false;
    firstFrame = false;
    videoPublished = false;
    _frameTimer?.cancel();
  }

  void toggleMic() {
    if (!controlsEnabled || !isHost) return;
    micMuted = !micMuted;
    _syncMediaSafely();
    _notify();
  }

  void toggleCamera() {
    if (!controlsEnabled || !isHost) return;
    cameraOff = !cameraOff;
    _syncMediaSafely();
    _notify();
  }

  void switchCamera() {
    if (!controlsEnabled || !isHost || cameraOff || !_foreground) return;
    try {
      final result = _cloud!.getDeviceManager().switchCamera(!frontCamera);
      if (result < 0) {
        warning = 'Camera switch failed (code $result).';
      } else {
        frontCamera = !frontCamera;
      }
      _notify();
    } catch (e) {
      warning = 'Camera switch failed: $e';
      _notify();
    }
  }

  void toggleSpeaker() {
    if (!controlsEnabled || isHost) return;
    speakerMuted = !speakerMuted;
    _syncMediaSafely();
    _notify();
  }

  void setForeground(bool foreground) {
    if (closing || _foreground == foreground) return;
    _foreground = foreground;
    _syncMediaSafely();
    _notify();
  }

  void _fail(String message) {
    debugPrint('[TRTC-QA] Session failure; see the error displayed in the app.');
    if (closing || _disposed) return;
    // Never log SDK credentials or UserSig values.
    error = message.replaceAll(
        credentials.userSig.isEmpty ? '\u0000' : credentials.userSig,
        '[redacted]');
    _notify();
    unawaited(close());
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    closing = true;
    engineReady = false;
    _joinTimer?.cancel();
    _frameTimer?.cancel();
    _notify();
    final cloud = _cloud;
    if (cloud != null) {
      // Run every cleanup operation even if another native call fails.
      for (final stop in <void Function()>[
        if (!customVideoInput) cloud.stopLocalPreview,
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
          warning = 'Room exit was not confirmed. Fully close and reopen the '
              'app before starting another session.';
        }
      }
      final listener = _listener;
      if (listener != null) {
        try {
          cloud.unRegisterListener(listener);
        } catch (_) {/* Best effort. */}
      }
    }
    // Keep the process-wide singleton alive. exitRoom releases media resources;
    // destroying it while a native video view is disposing can race on iOS.
    _cloud = null;
    _listener = null;
    _previewStarted = false;
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
}
