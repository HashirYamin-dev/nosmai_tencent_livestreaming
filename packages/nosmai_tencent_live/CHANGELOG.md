## 1.0.0

- First release as a Flutter plugin: host apps no longer contain Android or iOS
  bridge code.
- `NosmaiTencentLive.initialize` selects the per-platform Nosmai key and, on
  Android, registers the shared GL context before Nosmai starts.
- `NosmaiLiveBroadcaster` and `NosmaiLiveViewer` / `NosmaiLiveViewerView` run
  the Tencent room flow (arm, enter, publish, stop) with states, stats and
  typed errors.
- Android: shared-texture forwarding using Nosmai's wait/complete protocol,
  with automatic I420 fallback. iOS: CVPixelBuffer forwarding through Nosmai's
  live-stream callback.
- Configurable resolution, FPS and bitrate presets; thermal FPS cap on both
  platforms.
- Built-in fixes for `tencent_rtc_sdk` 13.5 on current Android tooling
  (compileSdk, vectordrawable namespaces) and for iOS release builds
  (`STRIP_STYLE`), so apps need no forked SDK or Podfile hooks.
