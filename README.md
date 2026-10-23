# Nosmai × Tencent RTC Livestreaming

Cross-platform Flutter livestreaming demo combining **Nosmai camera effects** with **Tencent RTC (TRTC)**. A broadcaster applies beauty filters, AR masks, backgrounds, or other licensed effects while a second device watches the processed video in a Tencent room.

> **Development / QA status (23 October 2026):** Filtered **iPhone host → Samsung Android viewer** streaming has been demonstrated on real devices with Nosmai's *Void Eyes* effect visible on both. The diagnostic stream was **360 × 640 at 15 FPS**, roughly **500 Kbps**. The iOS thermal-guard change is experimental and its temperature benefit is **not yet benchmarked**. This is **not** a verified 720p/30 FPS production solution. The Android GPU-texture route was separately demonstrated experimentally (previously ~5 FPS); do not conflate its results with the iOS test.

## Features

- **Start Live / Watch Live** in a numeric TRTC room with separate host and viewer identities.
- **Nosmai camera** preview and licensed beauty, makeup, cloud filters, AR effects, backgrounds, and color controls.
- **Filtered video publishing** via native bridges: Android texture path (experimental) and iOS processed `CVPixelBuffer` path.
- **Tencent-only camera** path for testing without Nosmai effects.
- **Streaming diagnostics** for frames submitted/skipped, video resolution, FPS, bitrate, network quality, and playback status.
- **iOS thermal guard (experimental):** limits native bridge frame forwarding based on iOS thermal state, without changing Nosmai SDK processing resolution.

Available effects depend on the Nosmai license, cloud catalog, SDK and device capabilities.

## Architecture

```text
Flutter dashboard / Nosmai feature selection
                   |
         Nosmai camera + effects
                   |
           processed video
          /                  \
Android GPU texture       iOS CVPixelBuffer (BGRA observed)
          |                  |
 Kotlin GPU bridge      Swift native bridge + frame pacing
          \                  /
           Tencent custom video input
                     |
             TRTC encode + network
                     |
           Viewer: Tencent decode/render
```

### Android host

The experimental Android bridge uses Nosmai's processed GPU texture callback, Kotlin/OpenGL ES handling, and Tencent custom video input. It is a GPU-texture handoff/copy path, **not verified zero-copy**. Texture ownership, synchronization and stable high FPS still require validation. Refer to the source in `android/app/src/main/kotlin/` for the current active implementation.

### iOS host

The iOS Swift bridge receives processed Nosmai `CVPixelBuffer` frames and invokes Tencent's native custom-video API. Physical-device testing confirmed a filtered image on the Android viewer. A diagnostic log showed an upstream **720 × 1280 BGRA** pixel buffer while the Tencent stream was configured for **360 × 640 / 15 FPS**. This does **not** prove that all camera effects processing is GPU-only or zero-copy. The SDK's Swift `sendCustomVideoData` interface used in this integration returns `Void`; a native submit-call counter is not an end-to-end delivery acknowledgement.

The optional iOS thermal guard paces frames *before Tencent submission*. It cannot guarantee a cooler device because Nosmai capture, filter rendering, display preview and encoding still use CPU/GPU resources. Check thermal state and verify performance on real hardware.

### Viewer

The viewer uses Tencent RTC video rendering and **does not need to run Nosmai processing**. On successful playback, the viewer should show `Frame: true`, nonzero resolution and FPS, and the selected effect. The host microphone is managed through Tencent RTC separately.

## Dependencies and platform notes

| Component | Observed setup / notes |
| --- | --- |
| Flutter | Use the version compatible with `pubspec.yaml` / `pubspec.lock` |
| Nosmai Flutter | `nosmai_effects_sdk` 2.0.2 observed |
| Nosmai iOS | `NosmaiCameraSDK` 3.0.7 observed via CocoaPods |
| Nosmai Android | 3.0.7 observed in the project |
| Tencent Flutter | Local `tencent_rtc_sdk` 13.5.2 override observed |
| Tencent iOS | `TXLiteAVSDK_Professional` 13.5.21355 observed |
| iOS native bridge | Swift + `CVPixelBuffer` custom video input |
| Android native bridge | Kotlin / OpenGL ES texture handoff (experimental) |

The Flutter Tencent SDK is maintained locally under `third_party/tencent_rtc_sdk/`, selected via `pubspec_overrides.yaml`. **Preserve both** when publishing/cloning. Consult `pubspec.lock`, `Podfile.lock`, and Gradle configuration for exact build versions. iOS Nosmai simulator support can be limited by the SDK's arm64 simulator architecture; **use a physical iPhone**.

## Project layout

```text
lib/
  main.dart                     Flutter entry point
  nosmai_dashboard.dart         Feature navigation
  nosmai_studio.dart            Nosmai preview, effects, host UI
  nosmai_tencent_bridge.dart    Dart/native integration
  live_session.dart             TRTC host / viewer flow
  app_credentials.dart          Local RTC identity handling

ios/Runner/
  AppDelegate.swift             iOS bridge/channel registration
  NosmaiTencentBridge.swift     iOS processed-frame forwarding

android/app/src/main/kotlin/  Android native bridge / channel code
third_party/tencent_rtc_sdk/   Local Tencent Flutter SDK
configure.sh                   Local Tencent test credentials generator
run.sh                         Device launch helper
REPO_SETUP.md                  Additional setup notes
```

File layout may evolve; the local checkout is the source of truth.

## Local setup

### 1. Requirements

Install Flutter/Dart, Android SDK and Xcode/CocoaPods for iOS. Use real phones, enable USB debugging on Android, and trust the Mac for iOS development.

```bash
flutter doctor -v
flutter devices
```

### 2. Clone and install

```bash
git clone https://github.com/HashirYamin-dev/nosmai_tencent_livestreaming.git
cd nosmai_tencent_livestreaming
flutter pub get
(cd ios && pod install)
```

Do not publish `config/*.json`, license keys, signing files, SDK secrets or UserSig values.

### 3. Configure Tencent QA credentials

```bash
bash configure.sh
```

Enter the authorized **SDKAppID** and **SDKSecretKey** locally when prompted. The script generates private `config/host.json` and `config/viewer.json` with distinct `host_001` and `viewer_001` UserSigs. Both clients must use the **same SDKAppID** and room (`1001` for the demonstrated QA flow), but **different user IDs**. Expired UserSigs must be regenerated. Never include the SDKSecretKey in a mobile build; production UserSigs should be created by a secured backend.

### 4. Configure Nosmai

Create any locally required Nosmai license file from its checked-in example (where available), and provide a **vendor-issued, platform-specific license for the exact app ID**. For this iOS QA project, the confirmed bundle ID was `com.vativeApps.NosmaiAR`; the key itself must be supplied privately and **must not be committed**. The iOS build supports a local `NOSMAI_IOS_LICENSE_KEY` dart define in the configured host build. Ensure the license also grants access to the desired cloud catalog and assets.

For example, create the optional Android local license placeholder if it exists:

```bash
cp lib/nosmai_license_local.example.dart lib/nosmai_license_local.dart
```

### 5. Run iPhone host (Xcode or Flutter)

**Use your private, ignored `config/ios_host.local.json` file** containing the current host credentials and iOS Nosmai license (as generated by local setup). The following flag keeps the verified diagnostic bitrate/resolution profile; remove it only when ready to retest performance.

```bash
flutter run -d IOS_DEVICE_ID \
  --dart-define-from-file=config/ios_host.local.json \
  --dart-define=IOS_TRTC_LOW_BW_TEST=true
```

For an Xcode device run, first generate the matching Flutter configuration:

```bash
flutter build ios --debug --no-codesign --config-only \
  --dart-define-from-file=config/ios_host.local.json \
  --dart-define=IOS_TRTC_LOW_BW_TEST=true
open ios/Runner.xcworkspace
```

Then select the physical iPhone in Xcode and **Product → Run**. If your local license setup uses a different filename, use that private file instead. Do **not** commit private dart-define JSON files.

### 6. Run Samsung / Android viewer

Connect Android by USB and verify its device ID:

```bash
adb devices
bash run.sh viewer ANDROID_DEVICE_ID
```

Alternatively use `flutter run` with a private viewer credentials file and the existing project-specific launch options. Avoid overlapping Flutter builds from the same checkout.

On iPhone: open **AR Effects → choose an effect → Start Live**. On Samsung: **Watch Live → Room 1001**. Confirm the processed effect appears on both sides.

## Validated QA observations

| Test / metric | Observation |
| --- | --- |
| iPhone → Samsung filtered video | **Working in a real-device demonstration** |
| Nosmai effect | *Void Eyes* shown on host and viewer |
| Viewer | `Frame: true` |
| Stream resolution | 360 × 640 |
| Viewer frame rate | 15 FPS |
| Approx. video bitrate | ~500 Kbps |
| Approx. viewer RTT | 100 ms in one screenshot |
| Loss / buffering | A snapshot showed 12% downlink loss and ~837 ms point-to-point delay; investigate network quality |
| iOS bridge source format | BGRA, 720 × 1280 observed at input |
| iOS frame submissions | 834 submit calls / 0 locally dropped in one screenshot; **not** proof of remote acceptance |
| iOS thermal guard | Implemented locally as a follow-up; **not benchmarked** |
| 720p / 30 FPS | **Not validated** |

One successful screenshot is not a long-running stability test. Revalidate reconnects, different networks, device heat, audio, and timestamp/synchronization behavior before deployment.

## Troubleshooting

- **Black viewer:** Check host `LIVE`, SDKAppID/room/user IDs, valid UserSigs, `Frame: true`, viewer's remote width/height/FPS, packet loss and buffering. A `submitCalled` counter only proves the native method was invoked; it does not prove decoding on the viewer.
- **Expired UserSig:** Rerun `bash configure.sh`, then rebuild **both** host and viewer with their newly generated private configs.
- **Nosmai blur/watermark or no cloud items:** Verify the license platform, app/bundle ID, validity, and cloud entitlement; rebuild with the intended private iOS key.
- **iOS heat:** Test a **profile/release-like** build, disconnect charging during measurements, monitor iOS thermal state, and reduce upstream capture/rendering cost if necessary. Frame pacing at the Tencent bridge alone does not guarantee temperature reduction.
- **No space left on device (Mac):** Free space and remove stale generated build caches before Xcode deployment.
- **iOS build:** Open `ios/Runner.xcworkspace`, not just `.xcodeproj`.

## Security and publishing

Never commit `.env` files, `config/*.json` private profiles, `lib/nosmai_license_local.dart`, credentials, provisioning profiles, signing keys, generated builds, or device logs containing UserSigs. Verify with `git status`, `git check-ignore`, and `git diff --cached` before pushing. Public demo credentials should be considered compromised if exposed, and promptly rotated. For production, move UserSig generation and access control to a trusted backend.

## Known limitations / next steps

- Measure iOS thermal/power behavior using Xcode Instruments on a physical device; evaluate upstream Nosmai capture resolution, format conversions and preview workload.
- Validate 20–30 FPS and progressively higher resolutions only after thermal and connectivity tests pass.
- Confirm reliable GPU texture synchronization/lifetime on Android and extended-run stability on both platforms.
- Review network packet loss and end-to-end latency under varied real conditions.
- Secure production authentication and reconnection/token refresh.

## References

- [Tencent RTC Flutter package](https://pub.dev/packages/tencent_rtc_sdk)
- [Tencent RTC Flutter SDK repository](https://github.com/Tencent-RTC/TRTC_Flutter)
- [Tencent RTC documentation](https://trtc.io/document/64203?platform=flutter&product=rtcengine)
- [Nosmai Flutter SDK](https://pub.dev/packages/nosmai_effects_sdk)

## License

This project integrates third-party SDKs. Tencent and Nosmai are governed by their respective licenses and service terms. Check the repository's own LICENSE file (if present) for the terms covering project-authored code.
