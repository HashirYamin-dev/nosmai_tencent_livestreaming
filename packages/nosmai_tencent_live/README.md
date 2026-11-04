# nosmai_tencent_live

Livestream the Nosmai camera through Tencent RTC (TRTC) from Flutter, with
Nosmai's beauty, makeup, AR effects, backgrounds, colour filters and cloud
filters applied. **You write only Dart.** The plugin contains all the Android
and iOS code.

```
NosmaiCameraPreview (Nosmai owns the camera, applies effects)
        │ processed frames
        ▼
nosmai_tencent_live (native, inside the plugin)
        │ Tencent custom video input
        ▼
Tencent RTC room  ──►  NosmaiLiveViewerView on other phones
```

Viewers need neither Nosmai nor a Nosmai license. The effects are already in
the video they receive.

## Requirements

| | |
|---|---|
| Flutter | 3.29 or later |
| Android | minSdk 24 (Flutter's default), physical arm64/armeabi-v7a phone |
| iOS | 15.0 (Flutter's default for new apps), physical iPhone (no simulator) |
| Nosmai | A license key per platform, bound to your applicationId / bundle ID |
| Tencent RTC | An SDKAppID, plus a UserSig per user issued by your server |

The plugin depends on `nosmai_effects_sdk` 2.0.x and `tencent_rtc_sdk`
13.5.x and pulls them in for you.

## Install

```yaml
dependencies:
  nosmai_tencent_live:
    git:
      url: https://github.com/HashirYamin-dev/nosmai_tencent_livestreaming.git
      path: packages/nosmai_tencent_live
```

### Platform setup

**Android:** nothing to do. The plugin merges the camera, microphone and network
permissions, R8 keep rules, and two build fixes for the Tencent SDK.

**iOS:** add the two usage strings every camera app needs to
`ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Your camera is used to broadcast live video.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Your microphone is used to broadcast live audio.</string>
```

If your app is older and its `ios/Podfile` sets `platform :ios` below 15.0,
raise it to `'15.0'`. Nosmai requires iOS 15. Apps created with current
Flutter already target 15.0.

You do not need to edit `MainActivity`, `AppDelegate`, Gradle files, the
bridging header or Podfile hooks.

## Quick start

### 1. Initialize once

```dart
import 'package:nosmai_tencent_live/nosmai_tencent_live.dart';

await NosmaiTencentLive.requestPermissions();          // camera + microphone
await NosmaiTencentLive.initialize(
  androidLicenseKey: 'YOUR_NOSMAI_ANDROID_KEY',
  iosLicenseKey: 'YOUR_NOSMAI_IOS_KEY',
);
```

Call `NosmaiTencentLive.initialize` **instead of** `NosmaiFlutter.initialize`.
On Android it must run first. It connects Nosmai to the stream's GPU
context before Nosmai starts. If Nosmai was already initialized, streaming
still works, but frames go through a slower CPU copy.

### 2. Show the camera and apply effects

The whole Nosmai API is re-exported. `NosmaiTencentLive.effects` is
`NosmaiFlutter.instance`.

```dart
// In your widget tree. Mount exactly one preview.
const NosmaiCameraPreview()

// Anywhere, before or during the broadcast:
final nosmai = NosmaiTencentLive.effects;
await nosmai.applySkinSmoothing(0.5);
await nosmai.applyLipstick(style: NosmaiLipstickStyle.natural, intensity: 0.4);
await nosmai.setBackgroundSegmentation(
    NosmaiBackgroundSegmentationConfig.color(Colors.blue));

// Cloud filters and AR effects
final items = await nosmai.getCloudFilters(
    filterType: NosmaiCloudFilterType.effects, page: 1, limit: 30);
final download = await nosmai.downloadCloudFilter(items.first.cloudIdentifier);
await nosmai.applyEffect(download['path'] as String);
```

Viewers see whatever the preview shows, including changes made while live.

### 3. Go live

```dart
final live = NosmaiLiveBroadcaster(
  credentials: NosmaiLiveCredentials(
    sdkAppId: 1400000000,
    userId: 'host_42',
    userSig: userSigFromYourServer,
  ),
  room: const NosmaiLiveRoom(1001),       // or NosmaiLiveRoom.named('studio-7')
  video: NosmaiLiveVideoConfig.hd,        // low | standard (default) | hd
);

try {
  await live.start();    // completes when the room is joined and video flows
} on NosmaiLiveException catch (e) {
  showError(e.message);
}

live.setMicMuted(true);
live.setVideoMuted(true);
await live.switchCamera();
await live.stop();
live.dispose();
```

`NosmaiLiveBroadcaster` is a `ChangeNotifier`. Rebuild your UI from
`live.state`, `live.stats`, `live.error` and `live.warning`.

### 4. Watch

```dart
final viewer = NosmaiLiveViewer(
  credentials: NosmaiLiveCredentials(
      sdkAppId: 1400000000, userId: 'viewer_7', userSig: viewerSig),
  room: const NosmaiLiveRoom(1001),
  // hostUserId: 'host_42',   // optional; otherwise the first broadcaster
);
await viewer.start();

// In build():
NosmaiLiveViewerView(
  viewer: viewer,
  placeholder: const Center(child: Text('Waiting for host…')),
)

await viewer.stop();
viewer.dispose();
```

## API summary

| Member | Purpose |
|---|---|
| `NosmaiTencentLive.initialize({androidLicenseKey, iosLicenseKey})` | Starts Nosmai with the key for the current platform |
| `NosmaiTencentLive.requestPermissions()` | Camera and microphone prompt; returns `NosmaiLivePermissions` |
| `NosmaiTencentLive.effects` | `NosmaiFlutter.instance`, Nosmai's full effects API |
| `NosmaiLiveBroadcaster` | `start`, `stop`, `setMicMuted`, `setVideoMuted`, `switchCamera`, `setMaxFps` |
| `NosmaiLiveViewer` / `NosmaiLiveViewerView` | `start`, `stop`, `setSpeakerMuted`, `hasVideo`, `watchingUserId` |
| `NosmaiLiveVideoConfig` | `resolution` (360p–1080p), `fps` (≤30), `bitrateKbps`, `minBitrateKbps`, `adaptToThermalState`, `adaptResolutionToNetwork` |
| `NosmaiLiveState` | `idle`, `connecting`, `waitingForHost`, `live`, `reconnecting`, `paused`, `stopping`, `stopped`, `failed` |
| `NosmaiLiveStats` | Resolution, fps, bitrate, RTT, loss, plus Nosmai→Tencent frame counters and `transport` |

### Video presets

| Preset | Resolution | FPS | Target bitrate |
|---|---|---|---|
| `NosmaiLiveVideoConfig.low` | 360×640 | 15 | 550 kbps |
| `NosmaiLiveVideoConfig.standard` | 540×960 | 24 | 1200 kbps |
| `NosmaiLiveVideoConfig.hd` | 720×1280 | 30 | 1800 kbps |

With `adaptToThermalState` (on by default), the frame rate is capped at 15 FPS
while the phone reports *serious*/*severe* heat and at 10 FPS at *critical*.

### Error codes (`NosmaiLiveException.code`)

| Code | Meaning |
|---|---|
| `missing_license_key` | No key was passed for the running platform |
| `license_rejected` | Nosmai refused the key (wrong platform, applicationId or bundle ID) |
| `unsupported_platform` | Not Android or iOS |
| `not_initialized` | `NosmaiTencentLive.initialize` was not called before `start` |
| `invalid_config` | Bad SDKAppID, userId, UserSig or room |
| `permission_denied` | Microphone denied (broadcast with `publishAudio: false` to skip audio) |
| `start_failed` | Tencent refused or timed out. The message says why (often an expired UserSig or a duplicate userId) |
| `stopped` | `stop()` was called while starting |

## Lifecycle behaviour

- The broadcaster arms Tencent custom capture **before** entering the room
  and forwards frames only **after** the room is joined, so Tencent never
  opens a second camera.
- By default, backgrounding the app pauses the video and microphone, and
  returning resumes them (`handleAppLifecycle`).
- Network drops reconnect automatically (`reconnecting` state).
- `stop()` halts frames, drains in-flight frames, then leaves the room. It is
  safe to call repeatedly and from `dispose`.

## Security

- Never put the Tencent **SDKSecretKey** in the app. Generate UserSigs on your
  server for each `userId` and refresh them before they expire.
- Load Nosmai keys from your build configuration (for example
  `--dart-define`) rather than committing them.
- Each participant needs a unique `userId`. A second login with the same ID
  ends the first session.

## How it works

**Android.** At `initialize`, the plugin creates a small EGL context and
registers it with Nosmai as the share context. Nosmai's renderer then joins
that share group. While live, each processed Nosmai texture goes through
Nosmai's documented consumer protocol: `waitStreamFrame`, a GPU copy into a
plugin-owned texture, then `completeStreamFrame`. The copy is fenced and handed
to Tencent as a `Texture_2D` frame, so pixels stay on the GPU. If sharing is
unavailable (Nosmai initialized first, or the driver refuses), the plugin falls
back to Nosmai's I420 frame callback. `stats.transport` reports `texture` or
`i420`.

**iOS.** The plugin subscribes to Nosmai's live-stream output
(`setLiveStreamFrameCallback`) and passes each processed `CVPixelBuffer`
(BGRA or NV12) to Tencent's custom video input, with at most one frame in
flight.

On both platforms frames are paced evenly to the configured FPS, because Tencent's
encoder expects a steady cadence.

## Validation status

- Unit tests cover session orchestration, start/stop ordering, failure
  handling, viewer binding and configuration (`flutter test`).
- A stock `flutter create` app that only adds this plugin builds for Android
  (debug and release with R8) and iOS without native edits.
- The iOS pixel-buffer path matches the bridge that was demonstrated
  iPhone→Android on real devices.
- The Android shared-texture path follows Nosmai's documented protocol, but
  **still needs real-device verification** on a range of phones. Check
  `stats.transport` and the viewer image. Run long-session, thermal and
  network tests on your target devices before release.

## Troubleshooting

| Symptom | Check |
|---|---|
| Viewer stays on "waiting" | Same SDKAppID and room on both sides, broadcaster `state == live`, unique userIds, valid UserSigs |
| `license_rejected` / watermark | Key platform and applicationId / bundle ID match the build |
| `stats.transport == 'i420'` on Android | `NosmaiFlutter.initialize` ran before `NosmaiTencentLive.initialize` |
| `framesFromNosmai` stays 0 | The `NosmaiCameraPreview` must be on screen while live |
| Release build crashes in Tencent FFI on iOS | Do not override `STRIP_STYLE` in the Runner target. The plugin sets it to `non-global` |
