import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

import 'credentials.dart';
import 'native_bridge.dart';
import 'rtc_session.dart';
import 'stats.dart';
import 'video_config.dart';

/// Publishes the Nosmai camera, with every applied effect, to a Tencent room.
///
/// Show a `NosmaiCameraPreview` on the same screen; Nosmai owns the camera
/// and whatever the preview shows is what viewers receive.
///
/// ```dart
/// final live = NosmaiLiveBroadcaster(
///   credentials: NosmaiLiveCredentials(sdkAppId: id, userId: 'host_1', userSig: sig),
///   room: const NosmaiLiveRoom(1001),
/// );
/// await live.start();
/// // ... apply effects with NosmaiTencentLive.effects ...
/// await live.stop();
/// ```
class NosmaiLiveBroadcaster extends ChangeNotifier with WidgetsBindingObserver {
  NosmaiLiveBroadcaster({
    required this.credentials,
    required this.room,
    this.video = NosmaiLiveVideoConfig.standard,
    this.publishAudio = true,
    this.handleAppLifecycle = true,
    @visibleForTesting CloudFactory? cloudFactory,
    @visibleForTesting NativeBridge bridge = const NativeBridge(),
    @visibleForTesting Duration statsInterval = const Duration(seconds: 1),
    @visibleForTesting bool Function()? nosmaiReady,
  })  : _cloudFactory = cloudFactory,
        _bridge = bridge,
        _statsInterval = statsInterval,
        _nosmaiReady = nosmaiReady ?? (() => NosmaiFlutter.instance.isInitialized);

  final NosmaiLiveCredentials credentials;
  final NosmaiLiveRoom room;
  final NosmaiLiveVideoConfig video;

  /// Publish the microphone along with the video.
  final bool publishAudio;

  /// Pause publishing in the background and resume in the foreground.
  final bool handleAppLifecycle;

  final CloudFactory? _cloudFactory;
  final NativeBridge _bridge;
  final Duration _statsInterval;
  final bool Function() _nosmaiReady;

  RtcSession? _session;
  Timer? _statsTimer;
  Future<void>? _stopFuture;
  NosmaiLiveState _state = NosmaiLiveState.idle;
  NosmaiLiveStats _stats = NosmaiLiveStats.empty;
  NativeFrameStats _native = const NativeFrameStats();
  String? _error;
  bool _micMuted = false;
  bool _videoMuted = false;
  bool _disposed = false;

  NosmaiLiveState get state => _state;
  NosmaiLiveStats get stats => _stats;

  /// Why the broadcast failed, when [state] is [NosmaiLiveState.failed].
  String? get error => _error;

  /// A non-fatal problem worth showing, such as a slow first frame.
  String? get warning => _session?.warning ?? (_native.lastError.isEmpty ? null : _native.lastError);

  bool get isLive => _state == NosmaiLiveState.live;
  bool get micMuted => _micMuted;
  bool get videoMuted => _videoMuted;

  /// Enters the room and starts publishing. Completes once the room is
  /// entered and frames are flowing to Tencent; throws on failure.
  Future<void> start() async {
    if (_state != NosmaiLiveState.idle) {
      throw StateError('A broadcaster can be started once; create a new one.');
    }
    _setState(NosmaiLiveState.connecting);
    try {
      final problem = credentials.validate() ?? room.validate();
      if (problem != null) throw NosmaiLiveException('invalid_config', problem);
      if (!_nosmaiReady()) {
        throw const NosmaiLiveException('not_initialized',
            'Call NosmaiTencentLive.initialize before starting a broadcast.');
      }
      if (publishAudio) {
        final permissions = await _bridge.requestPermissions();
        if (!permissions.microphone) {
          throw const NosmaiLiveException('permission_denied',
              'Microphone access is required to broadcast with audio.');
        }
      }
      _throwIfStopped();
      // Custom capture must be on before entering the room, or Tencent
      // starts its own camera, which Nosmai is already using.
      _native = await _bridge.arm(fps: video.fps, adaptToThermalState: video.adaptToThermalState);
      _throwIfStopped();

      final session = RtcSession(
        credentials: credentials,
        room: room,
        isHost: true,
        encoder: video.toEncoderParam(),
        publishAudio: publishAudio,
        cloudFactory: _cloudFactory,
      );
      _session = session;
      session.addListener(_onSessionChanged);
      session.setMicMuted(_micMuted);
      session.setVideoMuted(_videoMuted);
      if (handleAppLifecycle) WidgetsBinding.instance.addObserver(this);
      await session.start();
      await session.entered;
      _throwIfStopped();

      // Frames only start flowing once the room is entered.
      _native = await _bridge.publish();
      _throwIfStopped();
      _statsTimer = Timer.periodic(_statsInterval, (_) => unawaited(_refreshNativeStats()));
      _onSessionChanged();
    } catch (e) {
      final message = switch (e) {
        NosmaiLiveException(:final message) => message,
        StateError(:final message) => message,
        _ => '$e',
      };
      await (_stopFuture ??= _shutdown(failure: _error ?? message));
      if (e is NosmaiLiveException) rethrow;
      throw NosmaiLiveException('start_failed', _error ?? message);
    }
  }

  /// Leaves the room. Safe to call at any time and more than once.
  Future<void> stop() => _stopFuture ??= _shutdown();

  void setMicMuted(bool muted) {
    _micMuted = muted;
    _session?.setMicMuted(muted);
    _notify();
  }

  /// Stops sending video while muted; audio and the room connection stay.
  void setVideoMuted(bool muted) {
    _videoMuted = muted;
    _session?.setVideoMuted(muted);
    _notify();
  }

  /// Switches between front and back cameras. The stream continues.
  Future<void> switchCamera() => NosmaiFlutter.instance.switchCamera();

  /// Changes the published frame rate without restarting.
  Future<void> setMaxFps(int fps) async {
    _native = await _bridge.setMaxFps(fps.clamp(1, 30));
    _notify();
  }

  void _throwIfStopped() {
    if (_stopFuture != null || _disposed) {
      throw const NosmaiLiveException('stopped', 'The broadcast was stopped while starting.');
    }
    final failure = _session?.error;
    if (failure != null) throw NosmaiLiveException('start_failed', failure);
  }

  void _onSessionChanged() {
    final session = _session;
    if (session == null || _stopFuture != null) return;
    if (session.error != null) {
      _error = session.error;
      unawaited(_stopFuture ??= _shutdown(failure: session.error));
      return;
    }
    _stats = session.stats.copyWith(
      framesFromNosmai: _native.frames,
      framesSent: _native.sent,
      framesDropped: _native.dropped,
      transport: _native.transport,
    );
    final NosmaiLiveState next;
    if (!session.joined || !_native.publishing) {
      next = NosmaiLiveState.connecting;
    } else if (!session.foreground) {
      next = NosmaiLiveState.paused;
    } else if (session.reconnecting) {
      next = NosmaiLiveState.reconnecting;
    } else {
      next = NosmaiLiveState.live;
    }
    _setState(next);
  }

  Future<void> _refreshNativeStats() async {
    if (_stopFuture != null) return;
    try {
      _native = await _bridge.stats();
      _onSessionChanged();
    } catch (_) {/* Stats must never break the broadcast. */}
  }

  Future<void> _shutdown({String? failure}) async {
    if (failure != null) _error = failure;
    _statsTimer?.cancel();
    _statsTimer = null;
    if (_state != NosmaiLiveState.idle) _setState(NosmaiLiveState.stopping);
    if (handleAppLifecycle) WidgetsBinding.instance.removeObserver(this);
    // Stop the frame producer before leaving the room.
    try {
      await _bridge.stop();
    } catch (_) {/* Continue leaving the room. */}
    final session = _session;
    if (session != null) {
      session.removeListener(_onSessionChanged);
      try {
        await session.close();
      } catch (_) {/* Best effort. */}
      _error ??= session.error;
      session.dispose();
    }
    _setState(_error != null ? NosmaiLiveState.failed : NosmaiLiveState.stopped);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = _session;
    if (session == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        session.setForeground(true);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        session.setForeground(false);
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _setState(NosmaiLiveState next) {
    if (_state == next) {
      _notify();
      return;
    }
    _state = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    _disposed = true;
    super.dispose();
  }
}
