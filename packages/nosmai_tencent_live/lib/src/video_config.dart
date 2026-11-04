import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';

/// Portrait encoding resolutions for the broadcast.
enum NosmaiLiveResolution {
  p360(TRTCVideoResolution.res_640_360, 550, 200),
  p540(TRTCVideoResolution.res_960_540, 1200, 400),
  p720(TRTCVideoResolution.res_1280_720, 1800, 600),
  p1080(TRTCVideoResolution.res_1920_1080, 3000, 1000);

  const NosmaiLiveResolution(this.trtc, this.defaultBitrateKbps, this.defaultMinBitrateKbps);

  final TRTCVideoResolution trtc;
  final int defaultBitrateKbps;
  final int defaultMinBitrateKbps;
}

/// How the broadcaster encodes Nosmai's processed video.
///
/// Nosmai renders at 720x1280; Tencent scales that to [resolution].
class NosmaiLiveVideoConfig {
  const NosmaiLiveVideoConfig({
    this.resolution = NosmaiLiveResolution.p540,
    this.fps = 24,
    this.bitrateKbps,
    this.minBitrateKbps,
    this.adaptToThermalState = true,
    this.adaptResolutionToNetwork = true,
  }) : assert(fps >= 1 && fps <= 30, 'fps must be between 1 and 30');

  /// 360p at 15 FPS: weak networks and older phones.
  static const low = NosmaiLiveVideoConfig(
      resolution: NosmaiLiveResolution.p360, fps: 15);

  /// 540p at 24 FPS: the default balance of quality, heat and bandwidth.
  static const standard = NosmaiLiveVideoConfig();

  /// 720p at 30 FPS.
  static const hd = NosmaiLiveVideoConfig(
      resolution: NosmaiLiveResolution.p720, fps: 30);

  final NosmaiLiveResolution resolution;
  final int fps;

  /// Target bitrate; defaults to the recommendation for [resolution].
  final int? bitrateKbps;

  /// Lowest bitrate Tencent may drop to on a poor network.
  final int? minBitrateKbps;

  /// Lowers the frame rate while the phone reports serious or critical
  /// thermal state, so a long broadcast does not overheat the device.
  final bool adaptToThermalState;

  /// Lets Tencent lower the resolution when bandwidth is short.
  final bool adaptResolutionToNetwork;

  TRTCVideoEncParam toEncoderParam() => TRTCVideoEncParam(
        videoResolution: resolution.trtc,
        videoResolutionMode: TRTCVideoResolutionMode.portrait,
        videoFps: fps,
        videoBitrate: bitrateKbps ?? resolution.defaultBitrateKbps,
        minVideoBitrate: minBitrateKbps ?? resolution.defaultMinBitrateKbps,
        enableAdjustRes: adaptResolutionToNetwork,
      );
}
