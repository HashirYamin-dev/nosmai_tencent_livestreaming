import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_video_view.dart';

import 'credentials.dart';
import 'rtc_session.dart';
import 'stats.dart';

/// Watches a broadcaster in a Tencent room. Viewers do not need Nosmai or a
/// Nosmai license: effects are already part of the received video.
///
/// ```dart
/// final viewer = NosmaiLiveViewer(
///   credentials: NosmaiLiveCredentials(sdkAppId: id, userId: 'viewer_1', userSig: sig),
///   room: const NosmaiLiveRoom(1001),
/// );
/// await viewer.start();
/// // build: NosmaiLiveViewerView(viewer: viewer)
/// ```
class NosmaiLiveViewer extends ChangeNotifier with WidgetsBindingObserver {
  NosmaiLiveViewer({
    required this.credentials,
    required this.room,
    this.hostUserId,
    this.handleAppLifecycle = true,
    @visibleForTesting CloudFactory? cloudFactory,
  }) : _cloudFactory = cloudFactory;

  final NosmaiLiveCredentials credentials;
  final NosmaiLiveRoom room;

  /// The broadcaster to watch. When null, the first broadcaster in the room.
  final String? hostUserId;

  /// Pause playback in the background and resume in the foreground.
  final bool handleAppLifecycle;

  final CloudFactory? _cloudFactory;
  RtcSession? _session;
  Future<void>? _stopFuture;
  int? _pendingViewId;
  NosmaiLiveState _state = NosmaiLiveState.idle;
  String? _error;
  bool _speakerMuted = false;
  bool _disposed = false;

  NosmaiLiveState get state => _state;
  NosmaiLiveStats get stats => _session?.stats ?? NosmaiLiveStats.empty;
  String? get error => _error;
  String? get warning => _session?.warning;
  bool get speakerMuted => _speakerMuted;

  /// True once the broadcaster's video is rendering.
  bool get hasVideo => _session?.firstFrame ?? false;

  /// The broadcaster being watched, once one is found.
  String? get watchingUserId => _session?.hostUserId;

  /// Enters the room. Completes once entered; video follows when the
  /// broadcaster is live. Throws [NosmaiLiveException] on failure.
  Future<void> start() async {
    if (_state != NosmaiLiveState.idle) {
      throw StateError('A viewer can be started once; create a new one.');
    }
    _setState(NosmaiLiveState.connecting);
    final session = RtcSession(
      credentials: credentials,
      room: room,
      isHost: false,
      targetHostUserId: hostUserId,
      cloudFactory: _cloudFactory,
    );
    _session = session;
    session.addListener(_onSessionChanged);
    session.setSpeakerMuted(_speakerMuted);
    final viewId = _pendingViewId;
    if (viewId != null) session.attachVideoView(viewId);
    if (handleAppLifecycle) WidgetsBinding.instance.addObserver(this);
    try {
      await session.start();
      await session.entered;
    } catch (e) {
      final message = session.error ?? (e is StateError ? e.message : '$e');
      await (_stopFuture ??= _shutdown(failure: message));
      throw NosmaiLiveException('start_failed', message);
    }
  }

  /// Leaves the room. Safe to call at any time and more than once.
  Future<void> stop() => _stopFuture ??= _shutdown();

  void setSpeakerMuted(bool muted) {
    _speakerMuted = muted;
    _session?.setSpeakerMuted(muted);
    _notify();
  }

  void _attachView(int viewId) {
    _pendingViewId = viewId;
    _session?.attachVideoView(viewId);
  }

  void _detachView(int viewId) {
    if (_pendingViewId == viewId) _pendingViewId = null;
    _session?.detachVideoView(viewId);
  }

  void _onSessionChanged() {
    final session = _session;
    if (session == null || _stopFuture != null) return;
    if (session.error != null) {
      _error = session.error;
      unawaited(_stopFuture ??= _shutdown(failure: session.error));
      return;
    }
    final NosmaiLiveState next;
    if (!session.joined) {
      next = NosmaiLiveState.connecting;
    } else if (!session.foreground) {
      next = NosmaiLiveState.paused;
    } else if (session.reconnecting) {
      next = NosmaiLiveState.reconnecting;
    } else if (session.firstFrame) {
      next = NosmaiLiveState.live;
    } else {
      next = NosmaiLiveState.waitingForHost;
    }
    _setState(next);
  }

  Future<void> _shutdown({String? failure}) async {
    if (failure != null) _error = failure;
    if (_state != NosmaiLiveState.idle) _setState(NosmaiLiveState.stopping);
    if (handleAppLifecycle) WidgetsBinding.instance.removeObserver(this);
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

/// Renders the video a [NosmaiLiveViewer] receives.
///
/// Shows [placeholder] until the first frame arrives.
class NosmaiLiveViewerView extends StatefulWidget {
  const NosmaiLiveViewerView({super.key, required this.viewer, this.placeholder});

  final NosmaiLiveViewer viewer;
  final Widget? placeholder;

  @override
  State<NosmaiLiveViewerView> createState() => _NosmaiLiveViewerViewState();
}

class _NosmaiLiveViewerViewState extends State<NosmaiLiveViewerView> {
  int? _viewId;

  @override
  void didUpdateWidget(NosmaiLiveViewerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final viewId = _viewId;
    if (oldWidget.viewer != widget.viewer && viewId != null) {
      oldWidget.viewer._detachView(viewId);
      widget.viewer._attachView(viewId);
    }
  }

  @override
  void dispose() {
    final viewId = _viewId;
    if (viewId != null) widget.viewer._detachView(viewId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      TRTCCloudVideoView(onViewCreated: (viewId) {
        _viewId = viewId;
        widget.viewer._attachView(viewId);
      }),
      ListenableBuilder(
        listenable: widget.viewer,
        builder: (context, _) => widget.viewer.hasVideo
            ? const SizedBox.shrink()
            : (widget.placeholder ?? const SizedBox.shrink()),
      ),
    ]);
  }
}
