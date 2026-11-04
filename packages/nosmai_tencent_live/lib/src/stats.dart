/// Where a broadcaster or viewer is in its lifecycle.
enum NosmaiLiveState {
  /// Created, [start] not called yet.
  idle,

  /// Entering the Tencent room.
  connecting,

  /// Viewer only: in the room, no broadcaster video yet.
  waitingForHost,

  /// Broadcaster: video is being published. Viewer: host video is playing.
  live,

  /// The network dropped; Tencent is reconnecting automatically.
  reconnecting,

  /// Paused because the app is in the background.
  paused,

  /// Leaving the room.
  stopping,

  /// Left the room normally.
  stopped,

  /// Stopped because of an error; see `error`.
  failed;

  bool get isActive =>
      this == connecting ||
      this == waitingForHost ||
      this == live ||
      this == reconnecting ||
      this == paused;
}

/// Live quality numbers, refreshed about once per second while active.
class NosmaiLiveStats {
  const NosmaiLiveStats({
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.videoBitrateKbps = 0,
    this.audioBitrateKbps = 0,
    this.rttMs = 0,
    this.upLossPercent = 0,
    this.downLossPercent = 0,
    this.framesFromNosmai = 0,
    this.framesSent = 0,
    this.framesDropped = 0,
    this.transport = '',
  });

  static const empty = NosmaiLiveStats();

  /// Encoded (broadcaster) or decoded (viewer) video size.
  final int width;
  final int height;
  final int fps;
  final int videoBitrateKbps;
  final int audioBitrateKbps;
  final int rttMs;
  final int upLossPercent;
  final int downLossPercent;

  /// Broadcaster only: processed frames Nosmai produced.
  final int framesFromNosmai;

  /// Broadcaster only: frames handed to Tencent.
  final int framesSent;

  /// Broadcaster only: frames skipped because the pipeline was busy.
  final int framesDropped;

  /// Broadcaster only: `texture` (Android GPU), `i420` (Android CPU) or
  /// `pixelBuffer` (iOS).
  final String transport;

  NosmaiLiveStats copyWith({
    int? width,
    int? height,
    int? fps,
    int? videoBitrateKbps,
    int? audioBitrateKbps,
    int? rttMs,
    int? upLossPercent,
    int? downLossPercent,
    int? framesFromNosmai,
    int? framesSent,
    int? framesDropped,
    String? transport,
  }) =>
      NosmaiLiveStats(
        width: width ?? this.width,
        height: height ?? this.height,
        fps: fps ?? this.fps,
        videoBitrateKbps: videoBitrateKbps ?? this.videoBitrateKbps,
        audioBitrateKbps: audioBitrateKbps ?? this.audioBitrateKbps,
        rttMs: rttMs ?? this.rttMs,
        upLossPercent: upLossPercent ?? this.upLossPercent,
        downLossPercent: downLossPercent ?? this.downLossPercent,
        framesFromNosmai: framesFromNosmai ?? this.framesFromNosmai,
        framesSent: framesSent ?? this.framesSent,
        framesDropped: framesDropped ?? this.framesDropped,
        transport: transport ?? this.transport,
      );

  @override
  String toString() => '${width}x$height@${fps}fps ${videoBitrateKbps}kbps '
      'rtt=${rttMs}ms loss=$upLossPercent%/$downLossPercent% '
      'nosmai=$framesFromNosmai sent=$framesSent dropped=$framesDropped $transport';
}

/// Thrown for configuration and setup problems the app can fix.
class NosmaiLiveException implements Exception {
  const NosmaiLiveException(this.code, this.message);

  /// Stable identifier, e.g. `license_rejected` or `permission_denied`.
  final String code;
  final String message;

  @override
  String toString() => 'NosmaiLiveException($code): $message';
}
