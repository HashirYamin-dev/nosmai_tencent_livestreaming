/// Livestream Nosmai effects through Tencent RTC without native code.
///
/// 1. `NosmaiTencentLive.initialize(...)` with your Nosmai license keys.
/// 2. Show `NosmaiCameraPreview` and apply effects with
///    `NosmaiTencentLive.effects` (all of Nosmai's API is re-exported here).
/// 3. Broadcast with [NosmaiLiveBroadcaster]; watch with [NosmaiLiveViewer]
///    and [NosmaiLiveViewerView].
library;

export 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

export 'src/broadcaster.dart' show NosmaiLiveBroadcaster;
export 'src/credentials.dart';
export 'src/nosmai_tencent_live.dart';
export 'src/stats.dart';
export 'src/video_config.dart';
export 'src/viewer.dart';
